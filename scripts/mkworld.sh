#!/bin/sh
# mkworld.sh — emit the canonical MountNAS world package set, one name per line.
# env: PACKAGES_LIST=/abs/packages.list
#
# SINGLE SOURCE OF TRUTH for the world list. It is consumed by BOTH:
#   - scripts/genapkovl-mountnas.sh  (the seed overlay's /etc/apk/world)
#   - .github/workflows/build.yml    (world.base on the BOOT partition)
# The two MUST be identical: 'nas upgrade' reconciles the live /etc/apk/world
# against world.base (new base ∪ user extras), so any package that is in
# world.base but not resolvable from the on-media repo gets injected into every
# upgraded box's world and breaks apk at every boot. CI diffs the two outputs.
#
# NOTE: do NOT add bare 'linux-firmware' here. It is not in packages.list (which
# carries the curated linux-firmware-<vendor> subpackages) and is therefore NOT
# cached on the boot media, so world[linux-firmware] fails to resolve at boot and
# on every later 'apk' run (e.g. 'ERROR: linux-firmware (no such package)'). The
# vendor subpackages already provide the firmware; mkinitfs is in packages.list.
set -eu
: "${PACKAGES_LIST:?}"
{
	echo alpine-base
	sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$PACKAGES_LIST"
	echo mkinitfs
} | tr ' ' '\n' | sort -u
