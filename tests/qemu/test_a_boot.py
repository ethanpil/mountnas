"""Category A -- boot & image integrity.

Boot-to-login under both firmwares, getty layout, supervisor state without
storage, partition labels, and data-disk detection on every bus the kernel
cmdline module list claims to support (virtio-blk/scsi, AHCI, NVMe).
"""

from __future__ import annotations

import pytest

from lib import config as C
from lib import images
from lib.guest import DiskSpec


@pytest.mark.smoke
def test_boot_seabios_login(pristine_guest):
    """Fresh image reaches a login prompt under SeaBIOS (CI parity)."""
    pristine_guest.expect(C.LOGIN, timeout=420)
    pristine_guest.screenshot("seabios-login-prompt")


def test_boot_ovmf_login(suite_config, guest_factory, tmp_path, golden):
    """Fresh image reaches a login prompt under OVMF/UEFI (CI parity)."""
    if not suite_config.ovmf:
        pytest.skip("no OVMF firmware on this host")
    sysd = images.create_overlay(golden.base_img, "raw", tmp_path / "uefi.qcow2")
    guest = guest_factory([DiskSpec(str(sysd))], name="uefi",
                          firmware="uefi", ssh_key=golden.ssh_key,
                          throwaway=[sysd])
    guest.expect(C.LOGIN, timeout=420)
    guest.screenshot("ovmf-login-prompt")


@pytest.mark.smoke
def test_boot_sequence_gif(golden, artifacts):
    """The golden build captured a first-boot screendump GIF; anchor it here
    so the report has the boot sequence animation."""
    if not golden.boot_gif or not golden.boot_gif.exists():
        pytest.skip("boot GIF not captured (Pillow missing at golden build?)")
    artifacts.attach_file("first-boot sequence", golden.boot_gif,
                          mime="image/gif")


def test_getty_on_tty1_and_ttys0(golden_guest):
    """Explicit inittab: exactly one getty on tty1 (VGA) and one on ttyS0.

    Guards the double-getty regression: the diskless initramfs appends a getty
    for any console= device missing from inittab, and `console=tty0` used to
    produce two prompts fighting over the VGA console (CONTEXT.md section 3).
    """
    inittab = golden_guest.run("cat /etc/inittab", check=True).out
    tty1 = [l for l in inittab.splitlines()
            if l.strip().startswith("tty1:") and "getty" in l]
    ttys0 = [l for l in inittab.splitlines()
             if l.strip().startswith("ttyS0:") and "getty" in l]
    assert len(tty1) == 1, f"expected exactly one tty1 getty:\n{inittab}"
    assert len(ttys0) == 1, f"expected exactly one ttyS0 getty:\n{inittab}"
    # no auto-appended duplicate under the initramfs marker comment
    assert inittab.count("tty1:") == 1, "duplicate tty1 entry (auto-appended?)"
    # the kernel cmdline must name the same consoles
    cmdline = golden_guest.run("cat /proc/cmdline", check=True).out
    assert "console=tty1" in cmdline and "console=ttyS0" in cmdline, cmdline
    golden_guest.screenshot("vga-console-getty")


def test_boot_without_data_disk_state_fresh(pristine_guest):
    """No data disk in fstab -> supervisor reports 'fresh' and the boot still
    reaches a shell (storage must never stall the default runlevel)."""
    pristine_guest.login_serial()
    st = pristine_guest.run_serial(f"cat {C.STATE_DIR}/data")
    assert st.out.strip() == "fresh", f"state={st.out!r}"
    pristine_guest.screenshot("fresh-state-console")


def test_partition_labels_boot_mnascfg(golden_guest):
    """Single-slot layout: BOOT (FAT) + MNASCFG (ext4), overlay found by
    label -- both must be present and mounted where expected."""
    r = golden_guest.run("blkid", check=True)
    assert 'LABEL="BOOT"' in r.out, r.out
    assert 'LABEL="MNASCFG"' in r.out, r.out
    cfg = golden_guest.run("mountpoint -q /cfg && findmnt -n -o SOURCE /cfg")
    assert cfg.rc == 0, "/cfg (MNASCFG) is not mounted"


@pytest.mark.parametrize("bus", ["virtio-scsi", "ahci", "nvme"])
def test_data_disk_detected_per_bus(bus, guest_factory, overlay_disks, golden):
    """The fstab entry is LABEL=nasdata, so the data disk must be found and
    mounted no matter which controller it hangs off -- exercising the ahci/
    nvme/virtio_scsi modules carried by scripts/cmdline.base."""
    sysd, datad = overlay_disks(prefix=bus)
    guest = guest_factory(
        [DiskSpec(str(sysd)),
         DiskSpec(str(datad), bus=bus, serial=f"NAS{bus[:4].upper()}")],
        name=bus, ssh_key=golden.ssh_key, throwaway=[sysd, datad],
    )
    guest.wait_ssh()
    guest.poll_until(f"[ \"$(cat {C.STATE_DIR}/data)\" = ok ]",
                     timeout=180, desc=f"data state ok on {bus}")
    r = guest.run("nas disks --json", check=True)
    assert '"nasdata"' in r.out, f"nasdata label not visible on {bus}:\n{r.out}"
    assert guest.run(f"mountpoint -q {C.DATA_MOUNT}").rc == 0
