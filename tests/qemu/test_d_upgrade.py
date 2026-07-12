"""Category D -- `nas upgrade` (single-slot, in-place, staged-then-renamed).

Disk layout for every upgrade guest mirrors ci-upgrade-test.exp:
  vda = system (overlay on the pristine current or previous base.img)
  vdb = payload disk (overlay on the session ext4 image carrying new.img.gz;
        also doubles as TMPDIR scratch -- the guest unpacks ~3.5 GB into it)

-m 8192 default (the OLD release's code may still tmpfs-copy generously);
the dedicated _free_modloop regression test runs at -m 4096 on purpose.

Power-cut tests assert the staged-writes invariant: a cut before/while
committing must leave a bootable system (old or new, never a mixed
kernel/modloop pair, never a missing /apks).
"""

from __future__ import annotations

import os
import time
from pathlib import Path

import pytest

from lib import config as C
from lib import images
from lib.guest import DiskSpec

pytestmark = pytest.mark.upgrade

PAYLOAD_MOUNT = "/media/upgrade"
UPGRADE_CMD = (f"mkdir -p {PAYLOAD_MOUNT} && mount /dev/vdb {PAYLOAD_MOUNT} && "
               f"TMPDIR={PAYLOAD_MOUNT} nas upgrade --yes "
               f"{PAYLOAD_MOUNT}/new.img.gz")


@pytest.fixture(scope="session")
def prev_base(suite_config, prev_image_bundle, golden):
    """Pristine previous-release raw image with the suite SSH key injected
    (same key as the current image -> one keypair everywhere), or None."""
    if prev_image_bundle is None:
        return None
    dest = suite_config.cache_dir / f"prev-base-{prev_image_bundle.sha256[:16]}.img"
    if not dest.exists():
        images.sparse_gunzip(prev_image_bundle.img_gz, dest)
        images.inject_ssh_key(dest, golden.ssh_pub)
    return dest


# When set, the current `nas` CLI source is injected into each upgrade guest,
# so the suite tests the repo's nas (with local fixes) rather than only the
# nas baked into the released image.  Unset -> tests the shipped nas as-is.
NAS_SRC = os.environ.get("MOUNTNAS_NAS_SRC", "")


@pytest.fixture
def upgrade_guest(guest_factory, golden, payload_dir, tmp_path):
    """Factory: boot a pristine system + payload disk, ready to upgrade."""
    def make(base_img, *, name="upg", mem_mb=8192):
        sysd = images.create_overlay(base_img, "raw", tmp_path / f"{name}-sys.qcow2")
        payd = images.create_overlay(payload_dir, "raw", tmp_path / f"{name}-pay.qcow2")
        disks = [DiskSpec(str(sysd)), DiskSpec(str(payd), serial="PAYLOAD")]
        guest = guest_factory(disks, name=name, mem_mb=mem_mb,
                              ssh_key=golden.ssh_key,
                              throwaway=[sysd, payd])
        if NAS_SRC and Path(NAS_SRC).is_file():
            guest.wait_ssh(timeout=420)
            guest.push(Path(NAS_SRC), "/usr/sbin/nas.new")
            guest.run("cat /usr/sbin/nas.new > /usr/sbin/nas && rm /usr/sbin/nas.new "
                      "&& chmod +x /usr/sbin/nas", check=True)
        return guest, disks, (sysd, payd)
    return make


def _guest_version(guest) -> str:
    return guest.run(f"cat {C.VERSION_FILE}", check=True).out.strip()


def _run_upgrade(guest, timeout: float = 2400.0):
    r = guest.run(UPGRADE_CMD, timeout=timeout)
    assert r.rc == 0, f"nas upgrade rc={r.rc}:\n{r.out[-4000:]}"
    assert "Upgrade written successfully" in r.out, r.out[-2000:]
    assert "RESTORE YOUR BACKUP" not in r.out, r.out[-2000:]
    return r


def _reboot_pristine(guest):
    """Reboot a wizard-less guest and get back to SSH."""
    guest.reboot(timeout=420)


@pytest.mark.needs_prev
def test_upgrade_from_previous_release(upgrade_guest, prev_base, golden):
    """The real thing (port of ci-upgrade-test.exp): previous published
    release -> this image, reboot, expected version, clean world."""
    if prev_base is None:
        pytest.skip("no previous release available (--previous or GitHub)")
    guest, _, _ = upgrade_guest(prev_base, name="prevup")
    guest.wait_ssh(timeout=420)
    old_ver = _guest_version(guest)
    _run_upgrade(guest)
    _reboot_pristine(guest)
    new_ver = _guest_version(guest)
    assert new_ver == golden.meta["nas_version"], \
        f"expected {golden.meta['nas_version']}, got {new_ver} (was {old_ver})"
    # world reconciliation: the bare-linux-firmware landmine must stay dead
    r = guest.run("grep -qx linux-firmware /etc/apk/world")
    assert r.rc != 0, "bare linux-firmware leaked into /etc/apk/world"
    guest.screenshot("upgraded-from-previous")


def test_upgrade_self_current_to_current(upgrade_guest, golden):
    """Current image upgrading to itself: exercises this build's full
    upgrade path even when no previous release exists."""
    guest, _, _ = upgrade_guest(golden.base_img, name="selfup")
    guest.wait_ssh(timeout=420)
    ver_before = _guest_version(guest)
    _run_upgrade(guest)
    _reboot_pristine(guest)
    assert _guest_version(guest) == ver_before
    assert guest.run("nas status", timeout=180).rc in (0, 1)  # no data disk -> warn ok
    assert guest.run(f"ls {C.BOOTMNT}/apks").rc == 0, "/apks missing after upgrade"


def test_upgrade_succeeds_at_4gb_ram(upgrade_guest, golden):
    """THE alpha-4 regression: Alpine's copy-modloop ENOSPC'd a 4 GB box
    mid-firmware and wedged lbu; _free_modloop (modules only) must let the
    whole upgrade succeed with -m 4096."""
    guest, _, _ = upgrade_guest(golden.base_img, name="ram4g", mem_mb=4096)
    guest.wait_ssh(timeout=420)
    r = _run_upgrade(guest)
    assert "could not free the modloop" not in r.out
    _reboot_pristine(guest)
    assert guest.run("nas commit -m 'post-4g-upgrade'", timeout=180).rc == 0, \
        "lbu commit wedged after upgrade (the alpha-4 tmpfs-full symptom)"


@pytest.mark.faults
def test_powercut_during_staging_old_system_boots(upgrade_guest, guest_factory,
                                                  golden):
    """Cut power while payloads are being staged (.new copies): phase 1
    changes nothing, so the old system must boot untouched."""
    guest, disks, _ = upgrade_guest(golden.base_img, name="cutstage")
    guest.wait_ssh(timeout=420)
    # drive over serial so we can kill at the exact phase
    guest.login_serial()
    guest.sendline(UPGRADE_CMD)
    guest.expect(r"Writing the new system to the USB", timeout=1200)
    time.sleep(guest.cfg.scaled(3))       # a few seconds into staging
    guest.quit_hard()

    g2 = guest_factory(disks, name="cutstage-b", ssh_key=golden.ssh_key)
    g2.wait_ssh(timeout=420)              # old system boots
    assert _guest_version(g2) == golden.meta["nas_version"]
    assert g2.run("ls /media/mnasboot/apks").rc == 0, "/apks damaged by staging cut"
    st = g2.run("nas status", timeout=180)
    assert st.rc in (0, 1), f"box wedged after staging power cut: {st.rc}"


@pytest.mark.faults
def test_powercut_late_window_boots_old_or_new(upgrade_guest, guest_factory,
                                               golden):
    """Cut power late in the write phase (staging tail / commit renames):
    the box must boot with EITHER version -- never a mixed kernel/modloop
    pair (which does not boot) and never a missing /apks."""
    guest, disks, _ = upgrade_guest(golden.base_img, name="cutlate")
    guest.wait_ssh(timeout=420)
    guest.login_serial()
    guest.sendline(UPGRADE_CMD)
    guest.expect(r"Writing the new system to the USB", timeout=1200)
    time.sleep(guest.cfg.scaled(45))      # deep into the write phase
    guest.quit_hard()

    g2 = guest_factory(disks, name="cutlate-b", ssh_key=golden.ssh_key)
    g2.wait_ssh(timeout=420)              # THE invariant: it boots
    ver = _guest_version(g2)
    assert ver == golden.meta["nas_version"], ver   # self-upgrade: old == new
    assert g2.run("ls /media/mnasboot/apks").rc == 0, \
        "/apks missing -- _commit_dir failed to restore .old"
    g2.screenshot("post-late-powercut")


@pytest.mark.network
@pytest.mark.needs_prev
def test_user_packages_survive_upgrade(upgrade_guest, prev_base, golden):
    """extras = world - old base must ride across the version bump."""
    if prev_base is None:
        pytest.skip("no previous release available")
    guest, _, _ = upgrade_guest(prev_base, name="pkgsurv")
    guest.wait_ssh(timeout=420)
    r = guest.run("apk add figlet", timeout=300)
    if r.rc != 0:
        pytest.skip(f"apk add failed on the old release: {r.out[-400:]}")
    _run_upgrade(guest)
    _reboot_pristine(guest)
    guest.run("grep -qx figlet /etc/apk/world", check=True)
    guest.poll_until("command -v figlet", timeout=300,
                     desc="figlet reinstalled post-upgrade")


def test_gzip_sniff_accepts_wrong_extension(upgrade_guest, golden):
    """Filenames lie (a beta-2 tester's browser saved .img.tgz): the upgrade
    must sniff the 1f8b magic, not trust the extension."""
    guest, _, _ = upgrade_guest(golden.base_img, name="sniff")
    guest.wait_ssh(timeout=420)
    guest.run(f"mkdir -p {PAYLOAD_MOUNT} && mount /dev/vdb {PAYLOAD_MOUNT}",
              check=True)
    guest.run(f"cp {PAYLOAD_MOUNT}/new.img.gz {PAYLOAD_MOUNT}/saved.img.tgz",
              timeout=600, check=True)
    r = guest.run(f"TMPDIR={PAYLOAD_MOUNT} nas upgrade --yes "
                  f"{PAYLOAD_MOUNT}/saved.img.tgz", timeout=2400)
    assert r.rc == 0, f"sniff failed on .img.tgz name:\n{r.out[-3000:]}"
    assert "Upgrade written successfully" in r.out


def test_rejects_non_gzip_payload(upgrade_guest, golden):
    """Random bytes with an .img.gz name must be rejected cleanly with the
    box untouched -- not losetup'd as garbage."""
    guest, _, _ = upgrade_guest(golden.base_img, name="junk")
    guest.wait_ssh(timeout=420)
    guest.run(f"mkdir -p {PAYLOAD_MOUNT} && mount /dev/vdb {PAYLOAD_MOUNT}",
              check=True)
    guest.run(f"dd if=/dev/urandom of={PAYLOAD_MOUNT}/junk.img.gz bs=1M count=4",
              check=True)
    r = guest.run(f"TMPDIR={PAYLOAD_MOUNT} nas upgrade --yes "
                  f"{PAYLOAD_MOUNT}/junk.img.gz", timeout=600)
    assert r.rc != 0, "upgrade accepted random bytes as an image"
    assert "Upgrade written successfully" not in r.out
    # nothing changed: same version, boot files intact
    assert guest.run("ls /media/mnasboot/boot/vmlinuz-lts").rc == 0
    assert _guest_version(guest) == golden.meta["nas_version"]


def test_upgrade_from_url(upgrade_guest, golden, http_server, image_bundle):
    """URL upgrades download into TMPDIR, sniff after arrival, and proceed;
    the payload disk provides both the mount and the scratch space."""
    import shutil
    shutil.copyfile(image_bundle.img_gz, http_server.directory / "new.img.gz")
    guest, _, _ = upgrade_guest(golden.base_img, name="urlup")
    guest.wait_ssh(timeout=420)
    guest.run(f"mkdir -p {PAYLOAD_MOUNT} && mount /dev/vdb {PAYLOAD_MOUNT}",
              check=True)
    url = http_server.guest_url("new.img.gz")
    r = guest.run(f"TMPDIR={PAYLOAD_MOUNT} nas upgrade --yes {url}",
                  timeout=3600)
    assert r.rc == 0, f"URL upgrade failed:\n{r.out[-3000:]}"
    assert "Upgrade written successfully" in r.out
    _reboot_pristine(guest)
    assert _guest_version(guest) == golden.meta["nas_version"]


@pytest.mark.network
def test_upgrade_check_against_github(upgrade_guest, golden):
    """`nas upgrade --check` must produce a sane verdict against the real
    releases API (needs the repo public -- the beta-2 lesson is that the
    error for a private repo must say so, not 404 cryptically)."""
    guest, _, _ = upgrade_guest(golden.base_img, name="check")
    guest.wait_ssh(timeout=420)
    r = guest.run("nas upgrade --check", timeout=300)
    assert r.rc in (0, 1), f"--check crashed: rc={r.rc}\n{r.out}"
    out = r.out.lower()
    assert any(w in out for w in ("up to date", "available", "newer",
                                  "release", "public")), \
        f"--check output unrecognizable:\n{r.out}"


def test_free_space_precheck_aborts(upgrade_guest, golden):
    """TMPDIR without ~3.75 GiB free must abort BEFORE touching anything."""
    guest, _, _ = upgrade_guest(golden.base_img, name="nospace")
    guest.wait_ssh(timeout=420)
    guest.run(f"mkdir -p {PAYLOAD_MOUNT} && mount /dev/vdb {PAYLOAD_MOUNT}",
              check=True)
    # /root lives in the RAM rootfs -- nowhere near 3.75 GiB free
    r = guest.run(f"TMPDIR=/root nas upgrade --yes "
                  f"{PAYLOAD_MOUNT}/new.img.gz", timeout=300)
    assert r.rc != 0, "upgrade proceeded without enough temp space"
    assert "not enough free space" in r.out.lower() or "free space" in r.out.lower(), \
        r.out[-1500:]
    assert guest.run("ls /media/mnasboot/boot/vmlinuz-lts").rc == 0
