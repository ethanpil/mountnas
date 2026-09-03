"""Category M -- the homelab failure modes nothing else covers.

Category F injects faults at the disk layer. This tier is about the messy
real-world states a NAS actually ends up in: a stick that is rotting, a disk
that flaps, a filesystem that filled up months ago, a box that boots before
its router, a power cut during the one operation that rewrites parity.

The shared property under test is HONESTY. A NAS is allowed to degrade. It
is not allowed to degrade silently, wedge the boot, or report health it does
not have.
"""

from __future__ import annotations

import time
from pathlib import Path

import pytest

from lib import images
from lib.guest import DiskSpec, push_nas_tree

FILES_DIR = Path(__file__).resolve().parent.parent.parent / "mountnas-tools" / "files"


def _push_tools(g):
    """Run the REPO's tools, not the released ones."""
    push_nas_tree(g, FILES_DIR)
    for name, dst in (("mountnas", "/etc/init.d/mountnas"),
                      ("snapraid-maint", "/usr/libexec/mountnas/snapraid-maint")):
        g.push(FILES_DIR / name, f"{dst}.new")
        g.run(f"mv {dst}.new {dst} && chmod 755 {dst}", check=True)


# ------------------------------------------------------- power cut mid sync

@pytest.mark.faults
@pytest.mark.slow
def test_powercut_mid_parity_sync_array_recovers(guest_factory, overlay_disks,
                                                 golden, tmp_path):
    """Power cut DURING a parity sync -- the one operation that rewrites
    parity. The box must boot, and the array must still be usable: a fresh
    sync completes and the data verifies against parity. A torn parity that
    silently verified would be the worst possible outcome, because the owner
    would believe they are protected."""
    sysd, datad = overlay_disks(prefix="psync")
    d1 = images.create_blank_qcow2(tmp_path / "psync-d1.qcow2", "4G")
    par = images.create_blank_qcow2(tmp_path / "psync-par.qcow2", "4G")
    disks = [DiskSpec(str(sysd)), DiskSpec(str(datad), serial="NASDATA0"),
             DiskSpec(str(d1), serial="PSD1"), DiskSpec(str(par), serial="PSPAR")]
    g1 = guest_factory(disks, name="psync-a", ssh_key=golden.ssh_key)
    g1.wait_ssh()
    g1.run("mkfs.ext4 -Fq -L d1 /dev/vdc", timeout=180, check=True)
    g1.run("mkfs.ext4 -Fq -L par1 /dev/vdd", timeout=180, check=True)
    g1.run("printf '%s\\n' 'LABEL=d1 /mnt/disk1 ext4 rw,noatime,nofail 0 2'"
           " 'LABEL=par1 /mnt/parity1 ext4 rw,noatime,nofail 0 2' >> /etc/fstab",
           check=True)
    g1.run("rc-service mountnas restart", timeout=240, check=True)
    g1.poll_until("mountpoint -q /mnt/parity1", timeout=120, desc="parity mounted")
    g1.run("cat > /etc/snapraid.conf <<'EOF'\n"
           "parity /mnt/parity1/snapraid.parity\n"
           "content /mnt/disk1/snapraid.content\n"
           "content /mnt/parity1/snapraid.content\n"
           "data d1 /mnt/disk1/\n"
           "EOF", check=True)
    # enough data that the sync is still running when the power goes
    g1.run("mkdir -p /mnt/disk1/docs && for i in $(seq 1 200); do"
           " head -c 1048576 /dev/urandom > /mnt/disk1/docs/f$i.bin; done",
           timeout=600, check=True)
    g1.run("nas commit -m 'psync fstab'", timeout=180, check=True)
    g1.run("( snapraid sync >/tmp/sync.log 2>&1 & ) ; echo started", check=True)
    # wait until parity is actually being written, then cut
    g1.poll_until("test -s /mnt/parity1/snapraid.parity", timeout=180,
                  desc="parity file growing")
    time.sleep(2.0)
    g1.quit_hard()

    g2 = guest_factory(disks, name="psync-b", ssh_key=golden.ssh_key,
                       throwaway=[sysd, datad, d1, par])
    g2.wait_ssh(timeout=420)                      # the invariant: it BOOTS
    _push_tools(g2)
    g2.poll_until("mountpoint -q /mnt/parity1", timeout=240, desc="parity back")
    st = g2.run("nas status", timeout=240)
    assert st.rc in (0, 1), f"status wedged after a power cut: rc={st.rc}"

    # the array must be repairable, not merely present
    r = g2.run("NO_COLOR=1 nas snapraid run", timeout=1800)
    assert r.rc == 0, f"array did not recover with a fresh sync:\n{r.out[-3000:]}"
    r = g2.run("snapraid check", timeout=1800)
    assert r.rc == 0, f"data does not verify against parity after recovery:\n{r.out[-3000:]}"
    g2.screenshot("post-powercut-parity-sync")


# --------------------------------------------------------- corrupt the stick

@pytest.mark.faults
@pytest.mark.slow
def test_corrupt_modloop_fails_visibly(guest_factory, overlay_disks, golden):
    """USB flash is the most failure-prone part of this whole design, and the
    modloop carries every kernel module. Corrupting it must stop the boot
    visibly rather than bring up a box with no modules that silently mounts
    nothing -- a NAS that looks healthy and serves nothing is worse than one
    that plainly refuses."""
    sysd, datad = overlay_disks(prefix="rot")
    disks = [DiskSpec(str(sysd)), DiskSpec(str(datad), serial="NASDATA0")]
    g1 = guest_factory(disks, name="rot-a", ssh_key=golden.ssh_key)
    g1.wait_ssh()
    g1.run("mount -o remount,rw /media/mnasboot", check=True)
    # offset 0: the squashfs superblock. An interior page can land in a
    # region nothing reads during this boot, which is exactly what happened
    # the first time -- the box came up perfectly healthy and proved nothing.
    g1.run("dd if=/dev/urandom of=/media/mnasboot/boot/modloop-lts bs=4096"
           " count=4 conv=notrunc status=none", check=True)
    g1.run("sync", check=True)
    g1.poweroff()

    g2 = guest_factory(disks, name="rot-b", ssh_key=golden.ssh_key,
                       throwaway=[sysd, datad])
    booted = True
    try:
        g2.wait_ssh(timeout=240)
    except Exception:
        booted = False
    g2.screenshot("corrupt-modloop-boot")
    if booted:
        # If it does come up, it must NOT claim to be healthy: no modules
        # means no data disk, and status has to say so.
        st = g2.run("nas status", timeout=180)
        assert st.rc != 0, \
            "booted with a corrupt modloop and still reported a clean status"
    # If it did NOT boot, that is the expected fail-safe path: the screenshot
    # above is the evidence, and refusing to come up beats coming up broken.


# ------------------------------------------------------------ disk full

@pytest.mark.slow
def test_data_disk_full_is_reported_before_it_is_an_outage(golden_guest):
    """A NAS that fills up stops accepting writes, stops Docker and stops
    logging. `nas status` must say so out loud -- silence here is how a
    homelab discovers the problem only when something breaks."""
    g = golden_guest
    _push_tools(g)
    # Fill to ENOSPC. ext4 keeps a 5% root reserve, so stopping short of it
    # lands at ~94% used and never crosses the threshold under test. Nothing
    # else writes to this disk during the check (status renders into /run),
    # so a genuinely full data disk is safe to hold for a few seconds.
    g.run("dd if=/dev/zero of=/mnt/nasdata/BALLAST bs=1M status=none || true",
          timeout=900)
    used = int(g.run("df -Pk /mnt/nasdata | awk 'NR==2{print int($3*100/$2)}'",
                     check=True).out.strip())
    assert used >= 95, f"could not fill the disk far enough (used={used}%)"

    st = g.run("NO_COLOR=1 nas status", timeout=240)
    assert "full" in st.out.lower(), \
        f"a {used}%-full data disk was never mentioned:\n{st.out}"
    assert st.rc == 1, f"a nearly-full data disk must FAIL status, rc={st.rc}"
    g.screenshot("data-disk-full-status")
    g.run("rm -f /mnt/nasdata/BALLAST", timeout=120)
    # and it must clear once the space is back
    st = g.run("NO_COLOR=1 nas status", timeout=240)
    assert "full" not in st.out.lower(), f"still reporting full after cleanup:\n{st.out}"


# ------------------------------------------------------ boot without network

@pytest.mark.slow
def test_boot_with_blackholed_repos_is_bounded(guest_factory, overlay_disks, golden):
    """A NAS routinely boots before its router. The supervisor's world re-sync
    falls back to the network when a package is not on the media, and busybox
    init starts the gettys only after the runlevel finishes -- so an unbounded
    apk there costs the console, not just time. Point the repos at an
    unroutable address and require the box to come up anyway."""
    sysd, datad = overlay_disks(prefix="noname")
    disks = [DiskSpec(str(sysd)), DiskSpec(str(datad), serial="NASDATA0")]
    g1 = guest_factory(disks, name="noname-a", ssh_key=golden.ssh_key)
    g1.wait_ssh()
    _push_tools(g1)
    # a world entry that is NOT on the media forces the networked fallback,
    # and TEST-NET-1 (RFC 5737) is guaranteed unroutable
    g1.run("printf '%s\\n' '/run/mountnas/apks'"
           " 'https://192.0.2.1/alpine/v3.24/main'"
           " 'https://192.0.2.1/alpine/v3.24/community' > /etc/apk/repositories",
           check=True)
    g1.run("printf 'figlet\\n' >> /etc/apk/world", check=True)
    g1.run("nas commit -m 'blackholed repos'", timeout=180, check=True)
    g1.poweroff()

    g2 = guest_factory(disks, name="noname-b", ssh_key=golden.ssh_key,
                       throwaway=[sysd, datad])
    t0 = time.time()
    g2.wait_ssh(timeout=g2.cfg.scaled(420))
    boot_s = time.time() - t0
    g2.screenshot("boot-blackholed-repos")
    # the console must not be held hostage by an unreachable CDN
    assert boot_s < g2.cfg.scaled(360), f"boot took {boot_s:.0f}s with dead repos"
    assert g2.data_state() == "ok", f"data disk not up: {g2.data_state()}"


# ------------------------------------------------- very late / flaky disks

@pytest.mark.faults
@pytest.mark.slow
def test_disk_arriving_after_the_spinup_window_recovers(guest_factory,
                                                        overlay_disks, golden,
                                                        tmp_path):
    """The supervisor waits ~15 s for slow disks and then placeholders what is
    missing. A disk that shows up LATER (a dock that powers up late, a drive
    that spins slowly on a cold morning) must still be recoverable with the
    documented `nas restart`, and the placeholder must be gone afterwards."""
    sysd, datad = overlay_disks(prefix="late")
    extra = images.create_blank_qcow2(tmp_path / "late-extra.qcow2", "2G")
    base = [DiskSpec(str(sysd)), DiskSpec(str(datad), serial="NASDATA0")]
    g1 = guest_factory(base + [DiskSpec(str(extra), serial="LATE0")],
                       name="late-a", ssh_key=golden.ssh_key)
    g1.wait_ssh()
    g1.run("mkfs.ext4 -Fq -L late1 /dev/vdc", timeout=180, check=True)
    g1.run("printf '%s\\n' 'LABEL=late1 /mnt/late1 ext4 rw,noatime,nofail 0 2'"
           " >> /etc/fstab", check=True)
    g1.run("echo payload > /mnt/late1/probe || true")
    g1.run("nas commit -m 'late disk fstab'", timeout=180, check=True)
    g1.poweroff()

    # boot WITHOUT the disk: it must be placeholdered, not fatal
    g2 = guest_factory(base, name="late-b", ssh_key=golden.ssh_key)
    g2.wait_ssh(timeout=420)
    _push_tools(g2)
    placeheld = False
    for _ in range(18):
        if g2.run("grep -q '^mountnas-blocked /mnt/late1 ' /proc/mounts").rc == 0:
            placeheld = True
            break
        time.sleep(10)
    if not placeheld:
        mounts = g2.run("grep /mnt /proc/mounts || true").out
        fstab = g2.run("awk '$1!~/^#/ && NF' /etc/fstab || true").out
        slog = g2.run("tail -25 /var/log/mountnas.log || true").out
        raise AssertionError(
            "a declared disk that is absent was never placeholdered\n"
            f"--- /proc/mounts (/mnt) ---\n{mounts}\n"
            f"--- active fstab ---\n{fstab}\n"
            f"--- supervisor log ---\n{slog}")
    g2.poweroff()

    # now it arrives: the documented recovery must bring it back cleanly
    g3 = guest_factory(base + [DiskSpec(str(extra), serial="LATE0")],
                       name="late-c", ssh_key=golden.ssh_key,
                       throwaway=[sysd, datad, extra])
    g3.wait_ssh(timeout=420)
    _push_tools(g3)
    g3.run("rc-service mountnas restart", timeout=240, check=True)
    g3.poll_until("mountpoint -q /mnt/late1", timeout=180, desc="late disk mounted")
    left = g3.run("awk '$1==\"mountnas-blocked\"{print $2}' /proc/mounts").out.strip()
    assert left == "", f"placeholder left behind after recovery: {left}"


@pytest.mark.faults
@pytest.mark.slow
def test_flapping_disk_converges_without_leaking_mounts(golden_guest, golden,
                                                        tmp_path):
    """A failing cable or a marginal USB dock does not fail once, it flaps.
    Three detach/reattach cycles must converge on a healthy mount and leave
    NO stacked placeholders and no duplicate entries for the same target --
    mount stacking is precisely the failure this guards, and it accumulates
    silently until a mountpoint can never be cleared again."""
    g = golden_guest
    _push_tools(g)
    dev = "dev1"
    for i in range(3):
        g.detach_disk(dev)
        g.run("/usr/libexec/mountnas/data-watch", timeout=120)
        g.run("rc-service mountnas restart", timeout=240)
        newdisk = images.create_overlay(golden.data_golden, "qcow2",
                                        tmp_path / f"flap{i}.qcow2")
        dev = f"flap{i}"
        g.attach_data_disk(DiskSpec(str(newdisk), serial=f"NASFLAP{i}"),
                           dev_id=dev)
        g.poll_until("blkid | grep -q nasdata", timeout=90,
                     desc=f"cycle {i}: disk visible again")
        g.run("rc-service mountnas restart", timeout=240)
        g.poll_until("test \"$(cat /run/mountnas/data)\" = ok", timeout=240,
                     desc=f"cycle {i}: recovered")

    # placeholders must never stack
    n = g.run("awk '$1==\"mountnas-blocked\"{n++} END{print n+0}'"
              " /proc/mounts", check=True).out.strip()
    assert int(n) == 0, f"{n} placeholder(s) left after the disk came back"
    # and no target may carry two mounts
    dup = g.run(r"awk '$2 ~ /^\/mnt\//{c[$2]++} END{for(m in c) if (c[m]>1)"
                " print m, c[m]}' /proc/mounts", check=True).out.strip()
    assert dup == "", f"duplicate mounts stacked on the same target: {dup}"
    assert g.run("mountpoint -q /mnt/nasdata").rc == 0


# ------------------------------------------------------ failing config media

@pytest.mark.slow
def test_readonly_cfg_fails_the_commit_loudly(golden_guest):
    """Failing flash usually goes READ-ONLY rather than dying outright. The
    commit must fail loudly and non-zero -- a silent failure here is how a box
    reverts every setting at its next reboot with nobody the wiser (exactly
    the shape of the 1.0 wizard bug)."""
    g = golden_guest
    _push_tools(g)
    g.run("echo probe > /etc/mountnas-rocheck", check=True)
    g.run("mount -o remount,ro /cfg", check=True)
    try:
        r = g.run("NO_COLOR=1 nas commit -m rotest", timeout=240)
        assert r.rc != 0, f"commit reported success onto a read-only /cfg:\n{r.out}"
        assert "fail" in r.out.lower() or "error" in r.out.lower() \
            or "read-only" in r.out.lower(), \
            f"commit failed but said nothing useful:\n{r.out}"
        g.screenshot("readonly-cfg-commit")
        # the box must stay usable: this is a degraded state, not a crash
        assert g.run("nas status", timeout=240).rc in (0, 1)
    finally:
        g.run("mount -o remount,rw /cfg")
        g.run("rm -f /etc/mountnas-rocheck")


@pytest.mark.slow
def test_full_ram_root_fails_the_commit_clearly(golden_guest):
    """The whole OS lives in a tmpfs sized at half of RAM. A runaway container
    log or a big file in a tracked path fills it, and lbu then cannot build
    its tarball. The failure must be legible rather than a bare tar error."""
    g = golden_guest
    _push_tools(g)
    avail = int(g.run("df -Pk / | awk 'NR==2{print $4}'", check=True).out.strip())
    fill_mb = max(1, (avail - 20480) // 1024)
    g.run(f"dd if=/dev/zero of=/root/BALLAST bs=1M count={fill_mb} status=none"
          " || true", timeout=600)
    try:
        used = int(g.run("df -Pk / | awk 'NR==2{print int($3*100/$2)}'",
                         check=True).out.strip())
        assert used >= 90, f"could not fill the RAM root (used={used}%)"
        r = g.run("NO_COLOR=1 nas commit -m ramfull", timeout=300)
        assert r.rc != 0, f"commit claimed success with a full RAM root:\n{r.out}"
        g.screenshot("full-ram-root-commit")
    finally:
        g.run("rm -f /root/BALLAST", timeout=120)


# ------------------------------------------------------------- odd hardware

@pytest.mark.slow
def test_duplicate_filesystem_label_is_not_silently_ambiguous(guest_factory,
                                                              overlay_disks,
                                                              golden, tmp_path):
    """Cloning a disk is a normal homelab move, and it leaves two filesystems
    with the SAME label. `LABEL=` in fstab then resolves to whichever the
    kernel enumerated first. The box must not present that as healthy without
    a word -- silently mounting the wrong disk is a data-loss shape."""
    sysd, datad = overlay_disks(prefix="dup")
    a = images.create_blank_qcow2(tmp_path / "dup-a.qcow2", "2G")
    b = images.create_blank_qcow2(tmp_path / "dup-b.qcow2", "2G")
    disks = [DiskSpec(str(sysd)), DiskSpec(str(datad), serial="NASDATA0"),
             DiskSpec(str(a), serial="DUPA"), DiskSpec(str(b), serial="DUPB")]
    g = guest_factory(disks, name="dup", ssh_key=golden.ssh_key,
                      throwaway=[sysd, datad, a, b])
    g.wait_ssh()
    _push_tools(g)
    g.run("mkfs.ext4 -Fq -L twin /dev/vdc", timeout=180, check=True)
    g.run("mkfs.ext4 -Fq -L twin /dev/vdd", timeout=180, check=True)
    g.run("printf '%s\\n' 'LABEL=twin /mnt/twin ext4 rw,noatime,nofail 0 2'"
          " >> /etc/fstab", check=True)
    g.run("rc-service mountnas restart", timeout=240)
    st = g.run("NO_COLOR=1 nas status", timeout=240)
    g.screenshot("duplicate-label-status")
    low = st.out.lower()
    assert "twin" in low and ("duplicate" in low or "ambiguous" in low
                             or st.rc != 0), \
        f"two filesystems share a label and status said nothing:\n{st.out}"


@pytest.mark.slow
def test_wrong_clock_does_not_destroy_the_newest_mirror(golden_guest):
    """Repurposed hardware has dead CMOS batteries, so a box can boot years in
    the past. The config mirror prunes by the stamp embedded in the NAME for
    exactly this reason -- an mtime-ordered prune would delete the mirror it
    just wrote. Prove it survives a backwards clock."""
    g = golden_guest
    _push_tools(g)
    g.run("nas commit -m 'before the clock moves'", timeout=240, check=True)
    before = g.run("ls -1 /mnt/nasdata/config-backups/ | wc -l",
                   check=True).out.strip()
    g.run("date -s '2019-01-01 00:00:00'", check=True)
    try:
        r = g.run("NO_COLOR=1 nas commit -m 'from the past'", timeout=240)
        assert r.rc == 0, f"commit failed with a backwards clock:\n{r.out}"
        newest = g.run("ls -1t /mnt/nasdata/config-backups/*.apkovl.tar.gz"
                       " | head -n1", check=True).out.strip()
        assert newest, "the mirror directory is empty after a past-dated commit"
        after = g.run("ls -1 /mnt/nasdata/config-backups/ | wc -l",
                      check=True).out.strip()
        assert int(after) >= int(before), \
            f"mirror count went backwards ({before} -> {after})"
        assert g.run("nas rollback --list", timeout=180).rc == 0
    finally:
        g.run("rc-service ntpd restart >/dev/null 2>&1 || true")
        g.run("chronyc makestep >/dev/null 2>&1 || true")


# ------------------------------------------------- the OTHER two filesystems

@pytest.mark.slow
def test_full_cfg_partition_is_reported(golden_guest):
    """The config partition filling up is the QUIETEST serious failure this
    box has: 'nas commit' stops saving and settings simply stop persisting,
    so the next reboot reverts them with nobody told. It is also the one that
    creeps up on its own -- the apk cache lives there and grows with every
    package the user installs, and nothing prunes it."""
    g = golden_guest
    _push_tools(g)
    avail = int(g.run("df -Pk /cfg | awk 'NR==2{print $4}'", check=True).out.strip())
    total = int(g.run("df -Pk /cfg | awk 'NR==2{print $2}'", check=True).out.strip())
    used = int(g.run("df -Pk /cfg | awk 'NR==2{print $3}'", check=True).out.strip())
    # land above the 80% warn line without filling it completely: the box has
    # to stay usable while we read the verdict
    want_kb = int(total * 0.86) - used
    assert want_kb < avail, "not enough room on /cfg to stage this test"
    g.run(f"dd if=/dev/zero of=/cfg/BALLAST bs=1024 count={want_kb} status=none"
          " || true", timeout=600)
    try:
        pct = int(g.run("df -Pk /cfg | awk 'NR==2{print int($3*100/$2)}'",
                        check=True).out.strip())
        assert pct >= 80, f"could not cross the warn threshold (used={pct}%)"
        st = g.run("NO_COLOR=1 nas status", timeout=240)
        assert "config partition" in st.out and "full" in st.out.lower(), \
            f"a {pct}%-full /cfg was never reported:\n{st.out}"
        g.screenshot("cfg-partition-full")
    finally:
        g.run("rm -f /cfg/BALLAST", timeout=120)


@pytest.mark.slow
def test_full_boot_media_is_reported(golden_guest):
    """The boot partition needs free room for 'nas upgrade' to stage the new
    system beside the old one before the rename. A stick with no headroom
    fails the upgrade partway, which is the worst moment to discover it."""
    g = golden_guest
    _push_tools(g)
    g.run("mount -o remount,rw /media/mnasboot", check=True)
    total = int(g.run("df -Pk /media/mnasboot | awk 'NR==2{print $2}'",
                      check=True).out.strip())
    used = int(g.run("df -Pk /media/mnasboot | awk 'NR==2{print $3}'",
                     check=True).out.strip())
    want_kb = int(total * 0.86) - used
    assert want_kb > 0, "boot media is already past the threshold"
    g.run(f"dd if=/dev/zero of=/media/mnasboot/BALLAST bs=1024 count={want_kb}"
          " status=none || true", timeout=900)
    try:
        pct = int(g.run("df -Pk /media/mnasboot | awk 'NR==2{print int($3*100/$2)}'",
                        check=True).out.strip())
        assert pct >= 80, f"could not cross the warn threshold (used={pct}%)"
        st = g.run("NO_COLOR=1 nas status", timeout=240)
        assert "boot media" in st.out.lower() and "full" in st.out.lower(), \
            f"a {pct}%-full boot partition was never reported:\n{st.out}"
        g.screenshot("boot-media-full")
    finally:
        g.run("rm -f /media/mnasboot/BALLAST", timeout=300)
        g.run("mount -o remount,ro /media/mnasboot")
