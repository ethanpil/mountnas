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
	# Base cmdline only. write-bootcfg appends per-slot modloop=/alpine_repo=.
	# Overlay is found by partition label (no magic UUID to keep in sync).
	kernel_cmdline="modules=loop,squashfs,sd-mod,usb-storage,vfat,ext4 console=tty0 console=ttyS0,115200 ovl_dev=LABEL=MNASCFG"
	syslinux_serial="0 115200"
	apks="$apks $(_nas_pkglist)"
	local _f; for _f in $kernel_flavors; do apks="$apks linux-$_f"; done
}
