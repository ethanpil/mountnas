#!/bin/sh
# mkimg.nas.sh — MountNAS diskless profile.
# env: PACKAGES_LIST=/abs/packages.list

_nas_pkglist() {
	local f="${PACKAGES_LIST:?}"
	[ -f "$f" ] || { echo "mkimg.nas: PACKAGES_LIST not found" >&2; return 1; }
	sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$f"
}

profile_nas() {
	profile_standard
	profile_abbrev="nas"
	title="MountNAS"
	desc="MountNAS diskless NAS"
	arch="${ARCH:-x86_64}"
	kernel_flavors="lts"
	# Base cmdline only. write-bootcfg appends modloop=/boot/modloop-lts alpine_repo=auto.
	# Overlay is found by partition label (no magic UUID to keep in sync).
	# Disk-bus drivers (ahci/nvme/virtio_*) included so the image also boots from a
	# VM virtual disk (Proxmox defaults to VirtIO SCSI), not just a USB stick.
	# Inapplicable modules are silently skipped on real hardware.
	# console=tty1 (NOT tty0): the diskless initramfs auto-appends a getty for each
	# console= that has no inittab entry. tty0 = the active VT (== VT1 on the VGA), so
	# console=tty0 appended a SECOND getty on the same noVNC screen as our tty1 getty —
	# two prompts fighting over input, login impossible. tty1 matches our inittab getty.
	kernel_cmdline="modules=loop,squashfs,sd-mod,usb-storage,vfat,ext4,ahci,nvme,virtio_pci,virtio_scsi,virtio_blk console=tty1 console=ttyS0,115200 ovl_dev=LABEL=MNASCFG"
	syslinux_serial="0 115200"
	apks="$apks $(_nas_pkglist)"
	local _f; for _f in $kernel_flavors; do apks="$apks linux-$_f"; done
}
