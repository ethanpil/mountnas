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
    g.run("printf '%s\\n' '/mnt/disk1:/mnt/disk2 /mnt/storage fuse.mergerfs "
          "allow_other,use_ino,nofail 0 0' >> /etc/fstab", check=True)
    g.run("rc-service mountnas restart", timeout=240, check=True)
    g.poll_until("mountpoint -q /mnt/storage", timeout=120, desc="pool mounted")
    g.run("echo pooled > /mnt/storage/pool-probe", check=True)
    g.run("nas commit -m 'mergerfs pool'", timeout=120, check=True)
    g.reboot()
    g.poll_until("mountpoint -q /mnt/storage", timeout=240,
                 desc="pool re-mounted after reboot")
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
