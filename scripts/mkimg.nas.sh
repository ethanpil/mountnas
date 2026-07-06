#!/bin/sh
# mkimg.nas.sh — MountNAS diskless profile.
# env: PACKAGES_LIST=/abs/packages.list
#      CMDLINE_FILE=/abs/scripts/cmdline.base

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
	# Early CPU microcode, same mechanism as Alpine's Extended profile: the
	# vendor ucode packages are fetched as boot addons (their boot/*-ucode.img
	# lands on the media next to the kernel) and write-bootcfg prepends them to
	# the initrd line when present. The CPU picks its vendor's blob; the other
	# is ignored. Stability fix for real hardware (errata are microcode fixes).
	boot_addons="amd-ucode intel-ucode"
	initrd_ucode="/boot/amd-ucode.img /boot/intel-ucode.img"
	# Base cmdline only, read from scripts/cmdline.base — the SINGLE source of
	# truth also copied onto the BOOT partition by build.yml (write-bootcfg reads
	# it there). Never inline a cmdline here. Context that shaped its content:
	# - write-bootcfg appends modloop=/boot/modloop-lts alpine_repo=auto.
	# - Overlay is found by partition label (no magic UUID to keep in sync).
	# - Disk-bus drivers (ahci/nvme/virtio_*) included so the image also boots from
	#   a VM virtual disk (Proxmox defaults to VirtIO SCSI), not just a USB stick.
	#   Inapplicable modules are silently skipped on real hardware.
	# - console=tty1 (NOT tty0): the diskless initramfs auto-appends a getty for each
	#   console= that has no inittab entry. tty0 = the active VT (== VT1 on the VGA), so
	#   console=tty0 appended a SECOND getty on the same noVNC screen as our tty1 getty —
	#   two prompts fighting over input, login impossible. tty1 matches our inittab getty.
	kernel_cmdline="$(cat "${CMDLINE_FILE:?}")"
	syslinux_serial="0 115200"
	apks="$apks $(_nas_pkglist)"
	# NOTE: linux-lts is deliberately NOT added to $apks. The kernel/modloop on
	# /boot come from mkimage's own kernel section (independent of $apks), the
	# world never contains linux-lts (kernel updates arrive via 'nas upgrade'
	# replacing /boot files, never via apk), so the ~140 MB linux-lts apk in the
	# media repo was dead weight nothing could ever install. The CI world check
	# still proves every world.base entry resolves from the media repo.
}
