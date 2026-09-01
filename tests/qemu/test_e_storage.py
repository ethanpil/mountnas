"""Category E -- storage lifecycle.

Add-a-disk flow, mergerfs pooling, snapraid parity, early-boot mountpoint
creation (mountnas-mkdirs), the boot-USB fstab guard, and reboot persistence.
"""

from __future__ import annotations

import pytest

from lib import config as C
from lib import images
from lib.guest import DiskSpec


@pytest.fixture
def golden_with_extras(guest_factory, overlay_disks, golden, tmp_path):
    """Golden guest factory with N extra blank disks (vdc, vdd, ...)."""
    def make(n_extra: int = 1, size: str = "4G"):
        sysd, datad = overlay_disks()
        extras = [images.create_blank_qcow2(tmp_path / f"extra{i}.qcow2", size)
                  for i in range(n_extra)]
        disks = [DiskSpec(str(sysd)), DiskSpec(str(datad), serial="NASDATA0")]
        disks += [DiskSpec(str(p), serial=f"EXTRA{i}")
                  for i, p in enumerate(extras)]
        guest = guest_factory(disks, name="stor", ssh_key=golden.ssh_key,
                              throwaway=[sysd, datad, *extras])
        guest.wait_ssh()
        return guest
    return make


def test_add_second_disk_flow(golden_with_extras):
    """The documented add-a-disk story: mkfs, fstab, `nas restart` -> mounted
    and status-clean (ci-supervisor-test.exp storage leg, second disk)."""
    g = golden_with_extras(1)
    g.run("mkfs.ext4 -Fq -L disk1 /dev/vdc", timeout=180, check=True)
    g.run("printf '%s\\n' 'LABEL=disk1 /mnt/disk1 ext4 rw,noatime,nofail 0 2'"
          " >> /etc/fstab", check=True)
    g.run("rc-service mountnas restart", timeout=180, check=True)
    g.poll_until("mountpoint -q /mnt/disk1", timeout=120, desc="disk1 mounted")
    assert g.run("nas status", timeout=180).rc == 0
    g.run("echo hello > /mnt/disk1/probe && cat /mnt/disk1/probe", check=True)


def test_mergerfs_pool_two_disks_reboot(golden_with_extras):
    """Two data disks pooled with mergerfs via fstab; the pool and a file
    written into it must survive a reboot."""
    g = golden_with_extras(2)
    g.run("mkfs.ext4 -Fq -L disk1 /dev/vdc", timeout=180, check=True)
    g.run("mkfs.ext4 -Fq -L disk2 /dev/vdd", timeout=180, check=True)
    g.run("printf '%s\\n' 'LABEL=disk1 /mnt/disk1 ext4 rw,noatime,nofail 0 2'"
          " >> /etc/fstab", check=True)
    g.run("printf '%s\\n' 'LABEL=disk2 /mnt/disk2 ext4 rw,noatime,nofail 0 2'"
          " >> /etc/fstab", check=True)
    # minfreespace=1M: mergerfs defaults to 4G and refuses to create files on
    # a branch with less free space -- the 4 GB test disks have <4 GB free
    # after ext4 overhead, so without this every write ENOSPCs.
    g.run("printf '%s\\n' '/mnt/disk1:/mnt/disk2 /mnt/storage fuse.mergerfs "
          "allow_other,use_ino,minfreespace=1M,nofail 0 0' >> /etc/fstab",
          check=True)
    # The fuse.mergerfs pool is mounted by boot-time localmount (after its
    # branch disks), not by the mountnas supervisor -- so commit + reboot,
    # then verify the pool comes up from the committed fstab.
    g.run("nas commit -m 'mergerfs pool'", timeout=120, check=True)
    g.reboot()
    g.poll_until("mountpoint -q /mnt/storage", timeout=240,
                 desc="pool mounted at boot")
    g.run("echo pooled > /mnt/storage/pool-probe", check=True)
    r = g.run("cat /mnt/storage/pool-probe", check=True)
    assert r.out.strip() == "pooled"
    # the file physically lives on exactly one branch
    branch = g.run("ls /mnt/disk1/pool-probe /mnt/disk2/pool-probe 2>/dev/null")
    assert branch.out.strip(), "pool file not found on any branch"


@pytest.mark.slow
def test_snapraid_sync_with_parity(golden_with_extras):
    """Minimal snapraid config: one content disk + one parity disk; `snapraid
    sync` must produce parity and a clean `snapraid status`."""
    g = golden_with_extras(2)
    g.run("mkfs.ext4 -Fq -L disk1 /dev/vdc", timeout=180, check=True)
    g.run("mkfs.ext4 -Fq -L parity1 /dev/vdd", timeout=180, check=True)
    g.run("printf '%s\\n' 'LABEL=disk1 /mnt/disk1 ext4 rw,noatime,nofail 0 2'"
          " >> /etc/fstab", check=True)
    g.run("printf '%s\\n' 'LABEL=parity1 /mnt/parity1 ext4 rw,noatime,nofail 0 2'"
          " >> /etc/fstab", check=True)
    g.run("rc-service mountnas restart", timeout=240, check=True)
    g.poll_until("mountpoint -q /mnt/parity1", timeout=120, desc="parity mounted")
    g.run("dd if=/dev/urandom of=/mnt/disk1/blob bs=1M count=32", timeout=120,
          check=True)
    g.run("cat > /etc/snapraid.conf <<'EOF'\n"
          "parity /mnt/parity1/snapraid.parity\n"
          "content /mnt/disk1/snapraid.content\n"
          "content /mnt/parity1/snapraid.content\n"
          "data d1 /mnt/disk1/\n"
          "EOF", check=True)
    r = g.run("snapraid sync", timeout=900)
    assert r.rc == 0, f"snapraid sync rc={r.rc}:\n{r.out[-3000:]}"
    g.run("test -s /mnt/parity1/snapraid.parity", check=True)
    assert g.run("snapraid status", timeout=300).rc == 0


@pytest.mark.slow
def test_snapraid_maint_gate_blocks_and_fix_restores(golden_with_extras):
    """The snapraid-maint protection, end to end on a real array: a clean
    `nas snapraid run` syncs and scrubs; a mass delete beyond DEL_THRESHOLD
    is BLOCKED with parity untouched -- proven by `snapraid fix` restoring a
    deleted file -- and `--force-sync` then syncs the deletion.  Also:
    schedule writes/removes the marker cron line, and the status disk table
    reports roles and mounts without invoking snapraid (SPEC-snapraid-maint,
    D9/D10)."""
    import re
    from pathlib import Path
    from lib.guest import push_nas_tree
    files_dir = Path(__file__).resolve().parent.parent.parent \
        / "mountnas-tools" / "files"
    g = golden_with_extras(2)
    push_nas_tree(g, files_dir)
    g.push(files_dir / "snapraid-maint",
           "/usr/libexec/mountnas/snapraid-maint")
    g.run("chmod 755 /usr/libexec/mountnas/snapraid-maint", check=True)
    # the array: same recipe as test_snapraid_sync_with_parity, plus many
    # small files so a mass delete crosses DEL_THRESHOLD (100)
    g.run("mkfs.ext4 -Fq -L disk1 /dev/vdc", timeout=180, check=True)
    g.run("mkfs.ext4 -Fq -L parity1 /dev/vdd", timeout=180, check=True)
    g.run("printf '%s\\n' 'LABEL=disk1 /mnt/disk1 ext4 rw,noatime,nofail 0 2'"
          " >> /etc/fstab", check=True)
    g.run("printf '%s\\n' 'LABEL=parity1 /mnt/parity1 ext4 rw,noatime,nofail 0 2'"
          " >> /etc/fstab", check=True)
    g.run("rc-service mountnas restart", timeout=240, check=True)
    g.poll_until("mountpoint -q /mnt/parity1", timeout=120, desc="parity mounted")
    g.run("cat > /etc/snapraid.conf <<'EOF'\n"
          "parity /mnt/parity1/snapraid.parity\n"
          "content /mnt/disk1/snapraid.content\n"
          "content /mnt/parity1/snapraid.content\n"
          "data d1 /mnt/disk1/\n"
          "EOF", check=True)
    # 150 deletable files + one KEEPER: snapraid refuses to sync a fully
    # emptied disk without --force-empty (its own guard, deliberately NOT
    # bridged by --force-sync), so the disk must never go empty here
    g.run("mkdir -p /mnt/disk1/docs && for i in $(seq 1 150); do"
          " head -c 4096 /dev/urandom > /mnt/disk1/docs/f$i.bin; done"
          " && head -c 4096 /dev/urandom > /mnt/disk1/keep.bin",
          timeout=120, check=True)

    # status BEFORE any run: disk table + chain (cheap path)
    r = g.run("NO_COLOR=1 nas snapraid status", timeout=60, check=True)
    assert re.search(r"d1\s+data\s+/mnt/disk1/\s+mounted", r.out), r.out
    assert re.search(r"parity\s+parity\s+/mnt/parity1/", r.out), r.out
    assert "disks mounted      (2/2)" in r.out, r.out
    assert "no maintenance run recorded yet" in r.out, r.out

    # clean run: sync + scrub, SYNCED state on the data disk
    r = g.run("NO_COLOR=1 nas snapraid run", timeout=900)
    assert r.rc == 0, f"first run rc={r.rc}:\n{r.out[-3000:]}"
    g.run("test -s /mnt/parity1/snapraid.parity", check=True)
    st = g.run("cat /mnt/nasdata/snapraid/state/last-run", check=True).out
    assert "verdict=SYNCED" in st, st
    assert "scrubbed=7%" in st, st

    # THE protection: delete 150 files (> DEL_THRESHOLD) -> BLOCKED, parity
    # untouched -- proven by snapraid fix restoring a deleted file
    g.run("rm -rf /mnt/disk1/docs", check=True)
    r = g.run("NO_COLOR=1 nas snapraid run", timeout=300)
    assert r.rc == 1, f"mass delete must block, rc={r.rc}:\n{r.out[-2000:]}"
    st = g.run("cat /mnt/nasdata/snapraid/state/last-run", check=True).out
    assert "verdict=BLOCKED" in st, st
    r = g.run("NO_COLOR=1 nas snapraid status", timeout=60)
    assert "BLOCKED by the threshold gate" in r.out, r.out
    g.run("snapraid fix -f docs/f1.bin", timeout=300, check=True)
    g.run("test -s /mnt/disk1/docs/f1.bin", check=True)   # the payoff

    # intentional after all: --force-sync goes through
    g.run("rm -rf /mnt/disk1/docs", check=True)
    r = g.run("NO_COLOR=1 nas snapraid run --force-sync", timeout=900)
    assert r.rc == 0, f"force-sync rc={r.rc}:\n{r.out[-2000:]}"
    assert "gate DISABLED" in r.out, r.out
    st = g.run("cat /mnt/nasdata/snapraid/state/last-run", check=True).out
    assert "verdict=SYNCED" in st, st

    # schedule surface: marker line in, status shows it, off removes it
    g.run("NO_COLOR=1 nas snapraid schedule 03:30", timeout=60, check=True)
    cron = g.run("crontab -l", check=True).out
    assert re.search(r"^30 3 \* \* \* /usr/libexec/mountnas/snapraid-maint"
                     r" # mountnas-snapraid$", cron, re.M), cron
    r = g.run("NO_COLOR=1 nas snapraid status", timeout=60)
    assert "scheduled" in r.out and "03:30" in r.out, r.out
    g.run("NO_COLOR=1 nas snapraid schedule off", timeout=60, check=True)
    cron = g.run("crontab -l 2>/dev/null || true").out
    assert "mountnas-snapraid" not in cron, cron


def test_mkdirs_before_localmount_new_mountpoint(golden_with_extras):
    """A brand-new fstab mountpoint must exist by the time busybox localmount
    runs (mountnas-mkdirs runs `before localmount`) -- fstab has no
    x-mount.mkdir, which busybox mount would reject (CONTEXT.md section 3)."""
    g = golden_with_extras(1)
    g.run("mkfs.ext4 -Fq -L freshmp /dev/vdc", timeout=180, check=True)
    g.run("printf '%s\\n' 'LABEL=freshmp /mnt/freshmp ext4 rw,noatime,nofail 0 2'"
          " >> /etc/fstab", check=True)
    # deliberately NOT creating /mnt/freshmp and NOT restarting mountnas:
    # the reboot path itself must handle it
    g.run("nas commit -m 'freshmp fstab'", timeout=120, check=True)
    g.reboot()
    g.poll_until("mountpoint -q /mnt/freshmp", timeout=240,
                 desc="new mountpoint mounted at boot")
    # and no unknown-option noise poisoned dmesg
    r = g.run("dmesg | grep -i \"Unknown parameter 'x-mount\" || true")
    assert not r.out.strip(), f"x-mount.mkdir leaked into fstab handling: {r.out}"


def test_boot_usb_never_treated_as_data_disk(golden_guest):
    """A /mnt/* fstab entry resolving to the boot USB is the one unrecoverable
    user error -- `nas status` must FAIL loudly on it."""
    g = golden_guest
    g.run("printf '%s\\n' '/dev/vda2 /mnt/evil ext4 rw,noatime,nofail 0 2'"
          " >> /etc/fstab", check=True)
    try:
        r = g.run("nas status", timeout=180)
        assert r.rc == 1, f"status did not flag the boot-USB entry (rc={r.rc})"
        assert "BOOT USB" in r.out or "boot" in r.out.lower(), r.out
        g.screenshot("boot-usb-guard-fail")
    finally:
        g.run("sed -i '\\#/mnt/evil#d' /etc/fstab", check=True)
    assert g.run("nas status", timeout=180).rc == 0


def test_all_mounts_return_after_reboot(golden_with_extras):
    """Reboot persistence for the whole storage stack: every fstab mount and
    both data services come back with no manual help (supervisor smoke test
    persistence leg)."""
    g = golden_with_extras(1)
    g.run("mkfs.ext4 -Fq -L disk1 /dev/vdc", timeout=180, check=True)
    g.run("printf '%s\\n' 'LABEL=disk1 /mnt/disk1 ext4 rw,noatime,nofail 0 2'"
          " >> /etc/fstab", check=True)
    g.run("rc-service mountnas restart", timeout=180, check=True)
    g.poll_until("mountpoint -q /mnt/disk1", timeout=120, desc="disk1 mounted")
    g.run("nas commit -m 'reboot persistence'", timeout=120, check=True)
    g.reboot()
    g.poll_until(f"mountpoint -q {C.DATA_MOUNT}", timeout=240,
                 desc="nasdata after reboot")
    g.poll_until("mountpoint -q /mnt/disk1", timeout=120,
                 desc="disk1 after reboot")
    g.poll_until("rc-service docker status", timeout=300,
                 desc="docker after reboot")
    g.poll_until("rc-service samba status", timeout=120,
                 desc="samba after reboot")
    assert g.data_state() == "ok"


@pytest.mark.slow
def test_disk_init_mount_snapraid_chain(golden_with_extras):
    """The guided storage chain on real disks: 'nas disk init' formats a
    BLANK extra disk end to end (GPT, ext4 with the media inode density,
    fstab, supervisor mount, the SnapRAID offer), a second run refuses the
    now-used disk and points at 'nas mount', and the resulting array
    passes a real 'nas snapraid run'."""
    import re
    from pathlib import Path
    from lib.guest import push_nas_tree
    files_dir = Path(__file__).resolve().parent.parent.parent \
        / "mountnas-tools" / "files"
    g = golden_with_extras(2)
    push_nas_tree(g, files_dir)
    g.push(files_dir / "snapraid-maint",
           "/usr/libexec/mountnas/snapraid-maint")
    g.run("chmod 755 /usr/libexec/mountnas/snapraid-maint", check=True)

    # the extra disks carry serials EXTRA0/EXTRA1 (DiskSpec) — the confirm
    # token is the last 4 characters
    # init vdc as a DATA disk: role=2, fs=default, contents=1 (large),
    # serial suffix, then the chained mount flow: role=1, snapraid=y,
    # second-content offer=y (nasdata is mounted on the golden guest)
    r = g.run("printf '2\n\n1\nTRA0\n1\ny\ny\n' | nas disk init /dev/vdc",
              timeout=600)
    assert r.rc == 0, f"disk init rc={r.rc}:\n{r.out[-3000:]}"
    g.poll_until("mountpoint -q /mnt/disk1", timeout=180, desc="disk1 mounted")
    # the media inode density and zero root reserve actually applied
    r = g.run("tune2fs -l /dev/vdc1", check=True)
    ic = int(re.search(r"Inode count:\s+(\d+)", r.out).group(1))
    bc = int(re.search(r"Block count:\s+(\d+)", r.out).group(1))
    bs = int(re.search(r"Block size:\s+(\d+)", r.out).group(1))
    assert (bc * bs) / ic > 500_000, f"inode density not applied ({ic} inodes)"
    assert re.search(r"Reserved block count:\s+0\b", r.out), "-m 0 not applied"
    g.run("grep -q '/mnt/disk1' /etc/fstab", check=True)
    g.run("grep -q 'data d1 /mnt/disk1/' /etc/snapraid.conf", check=True)
    g.run("grep -c '^content ' /etc/snapraid.conf | grep -qx 2", check=True)

    # a second init on the SAME disk must refuse and point at nas mount
    r = g.run("nas disk init /dev/vdc", timeout=60)
    assert r.rc != 0 and "NOT blank" in r.out, r.out
    assert "nas mount" in r.out, r.out

    # parity disk via init role=3 (no contents question), chained mount
    # role=2(parity), snapraid=y
    r = g.run("printf '3\n\nTRA1\n2\ny\n' | nas disk init /dev/vdd",
              timeout=600)
    assert r.rc == 0, f"parity init rc={r.rc}:\n{r.out[-3000:]}"
    g.poll_until("mountpoint -q /mnt/parity1", timeout=180,
                 desc="parity1 mounted")
    g.run("grep -q '^parity /mnt/parity1/snapraid.parity' /etc/snapraid.conf",
          check=True)

    # the chain produced a REAL runnable array
    g.run("head -c 4096 /dev/urandom > /mnt/disk1/probe.bin", check=True)
    r = g.run("NO_COLOR=1 nas snapraid run", timeout=900)
    assert r.rc == 0, f"chain array failed its first sync:\n{r.out[-2000:]}"
    g.run("test -s /mnt/parity1/snapraid.parity", check=True)
