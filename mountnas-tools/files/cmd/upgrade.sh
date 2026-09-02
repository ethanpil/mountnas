# shellcheck shell=sh
# nas upgrade — single-slot, in-place (full detail in UPGRADE.md)
# Sourced by /usr/sbin/nas (never run directly). Shared helpers: lib.sh.

# ---------- upgrade (single-slot, in-place; full detail in UPGRADE.md) ----------
_mount_boot_rw() {
	mkdir -p "$BOOTMNT"
	mountpoint -q "$BOOTMNT" || mount LABEL=BOOT "$BOOTMNT" 2>/dev/null || { bad "cannot mount BOOT partition"; return 1; }
	mount -o remount,rw "$BOOTMNT" 2>/dev/null || true
	[ -f "$BOOTMNT/.nas-boot" ] || { bad "BOOT partition missing .nas-boot marker — refusing"; return 1; }
}
# Undo what cmd_upgrade did to the RUNNING system on its way out: re-establish
# the offline-apk bind it released (an aborted upgrade otherwise silently
# breaks offline 'apk add' until the next reboot) and put BOOT back read-only
# (the supervisor mounts it ro; _mount_boot_rw flipped it). The rebind is
# skipped once the phase-2 renames began (UPG_COMMITTED=1): at that point the
# on-USB repo is the NEW release's, and binding it under the still-running OLD
# system could mix package generations — after a successful upgrade the reboot
# re-binds it, after a failed one the box needs a restore anyway. Idempotent.
_boot_restore() {
	if [ "${UPG_COMMITTED:-0}" = 0 ] && [ -d "$BOOTMNT/apks" ] \
		&& ! mountpoint -q "$STATE/apks" 2>/dev/null; then
		mkdir -p "$STATE/apks"
		mount --bind "$BOOTMNT/apks" "$STATE/apks" 2>/dev/null || true
	fi
	mount -o remount,ro "$BOOTMNT" 2>/dev/null || true
	return 0
}

# Staged, crash-safe in-place replace — two phases:
#   _stage_*  : copy the payload to <target>.new (slow; the system on the USB
#               stays fully intact and bootable while this runs)
#   _commit_* : rename <target>.new into place (fast)
# cmd_upgrade stages EVERYTHING first and only then commits back-to-back, so
# the window in which the USB holds a MIXED system (e.g. new kernel beside an
# old modloop = unbootable module mismatch) shrinks from the minutes a modloop
# copy takes on USB 2.0 to a handful of renames.
_stage_file() { cp "$1" "$2.new"; }
_commit_file() { mv "$1.new" "$1"; }
_stage_dir() {
	rm -rf "$2.new"; mkdir -p "$2.new"
	cp -r "$1"/. "$2.new/" || { rm -rf "$2.new"; return 1; }
}
# Swap the staged $1.new into place, keeping $1.old until the swap-in has
# succeeded: a missing tree (/apks!) can mean an unbootable USB, so on a
# failed swap-in the old tree is moved back rather than deleted.
_commit_dir() {
	rm -rf "$1.old"
	if [ -d "$1" ]; then mv "$1" "$1.old" || { rm -rf "$1.new"; return 1; }; fi
	if ! mv "$1.new" "$1"; then
		[ -d "$1" ] || mv "$1.old" "$1" 2>/dev/null
		return 1
	fi
	rm -rf "$1.old"
}

# Free the live modloop so its file on BOOT can be overwritten. Replaces
# Alpine's copy-modloop, which cp -a's the WHOLE modloop tree — kernel modules
# AND the full firmware set (hundreds of MB) — into the tmpfs RAM root (sized
# at half of RAM): on a 4 GB box the copy hits ENOSPC mid-way (confirmed on
# real hardware) and the aborted partial copy fills the tmpfs, wedging lbu.
# A running system does not read firmware FILES again: every probed device got
# its firmware uploaded at boot, and anything plugged in before the reboot
# falls back to /lib/firmware (where apk-installed blobs live). So copy ONLY
# the kernel modules (tens of MB), retarget the kernel's firmware search path
# away from the vanishing modloop, and detach it.
_free_modloop() {
	local src need_kb d free_kb fwp dkb
	src=$(readlink -f /lib/modules 2>/dev/null)
	case "$src" in
		/.modloop/*) ;;
		*) return 0 ;;   # not modloop-backed (already freed) — nothing to do
	esac
	# accurate headroom check: kernel modules only, firmware excluded
	need_kb=65536   # + margin for the rest of the upgrade
	for d in "$src"/*; do
		[ "$(basename "$d")" = firmware ] && continue
		# NEVER inline the substitution into $(( )): an EMPTY result is a fatal
		# ash "arithmetic syntax error" that kills the whole nas process on the
		# spot, and this runs after BOOT is already remounted read-write. du
		# returns nothing whenever the glob matched no real directory — e.g.
		# /lib/modules still points into a modloop somebody already detached.
		dkb=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
		case "$dkb" in ''|*[!0-9]*) dkb=0 ;; esac
		need_kb=$((need_kb + dkb))
	done
	free_kb=$(df -Pk / 2>/dev/null | awk 'NR==2{print $4}')
	if [ "${free_kb:-0}" -lt "$need_kb" ]; then
		bad "not enough RAM headroom to hold the kernel modules: need ~$((need_kb / 1024)) MB free on / (RAM root), have $(( ${free_kb:-0} / 1024)) MB."
		return 1
	fi
	rm -rf /lib/modules.tmp; mkdir -p /lib/modules.tmp
	for d in "$src"/*; do
		[ "$(basename "$d")" = firmware ] && continue
		cp -a "$d" /lib/modules.tmp/ || { rm -rf /lib/modules.tmp; return 1; }
	done
	# in-modloop firmware disappears with the unmount: clear the kernel's
	# custom firmware search path if it points there, so any load between now
	# and the reboot falls back to /lib/firmware
	fwp=/sys/module/firmware_class/parameters/path
	case "$(cat "$fwp" 2>/dev/null)" in
		/.modloop/*) printf '' > "$fwp" 2>/dev/null || true ;;
	esac
	# detach. The service is the normal path; a direct/lazy umount is the
	# fallback for a transient holder (a spurious 'target is busy' was seen
	# once under QEMU) — with -l the mount leaves the namespace now and the
	# loop device auto-clears when the last reference drops, which frees the
	# modloop file for the crash-safe rename-overwrite either way.
	if ! rc-service modloop stop >/dev/null 2>&1; then
		umount /.modloop 2>/dev/null || umount -l /.modloop 2>/dev/null \
			|| { rm -rf /lib/modules.tmp; return 1; }
	fi
	rm -f /lib/modules 2>/dev/null || rm -rf /lib/modules
	mv /lib/modules.tmp /lib/modules
	return 0
}

# nas upgrade --check — one GitHub API call: is a different release published?
# No auto-update, no scheduling; prints the exact command to run when one is.
_upgrade_check() {
	local api hc json tag rel_url
	step "Checking the latest release of $REPO ..."
	api="https://api.github.com/repos/$REPO/releases/latest"
	# capture the HTTP status: a 404 (private repo, or no releases) used to be
	# reported as "no network" even while the box was fully online (beta-1
	# test 16 — the repo was private). curl is baked in; wget is the coarse
	# fallback.
	if command -v curl >/dev/null 2>&1; then
		hc=$(curl -sL -o "/tmp/.nas-check.$$" -w '%{http_code}' "$api" 2>/dev/null) || hc=000
		json=$(cat "/tmp/.nas-check.$$" 2>/dev/null); rm -f "/tmp/.nas-check.$$"
	else
		json=$(wget -qO- "$api" 2>/dev/null) && hc=200 || hc=000
	fi
	case "$hc" in
		200) : ;;
		000) bad "cannot reach the GitHub API — check network/DNS"; return 1 ;;
		404) bad "no release info at github.com/$REPO — the repository is PRIVATE or has no releases (on-box checks need a public repo)"; return 1 ;;
		403|429) bad "GitHub API rate limit — try again in a few minutes"; return 1 ;;
		*) bad "GitHub API returned HTTP $hc"; return 1 ;;
	esac
	tag=$(printf '%s\n' "$json" | jq -r '.tag_name // empty' 2>/dev/null)
	[ -n "$tag" ] || { bad "no release found for $REPO"; return 1; }
	# compare tag-to-tag: RELEASE carries the tag this image was built from
	# (comparing against the apk pkgver always mismatched — alpha-6 vs 1.0.0_git…)
	if [ "$tag" = "$RELEASE" ] || [ "${tag#v}" = "$RELEASE" ]; then
		ok "up to date: MountNAS $RELEASE is the latest release"; return 0
	fi
	warn "a different release is published: $tag (running: $RELEASE)"
	rel_url=$(printf '%s\n' "$json" | jq -r '.assets[]?.browser_download_url // empty' 2>/dev/null | grep -m1 '\.img\.gz$')
	hint "Upgrade with (see UPGRADE.md — run 'nas backup' FIRST):"
	if [ -n "$rel_url" ]; then echo "    nas upgrade $rel_url"
	else echo "    nas upgrade <mountnas-$tag.img.gz>   (release has no .img.gz asset?)"; fi
}

# nas upgrade <mountnas-*.img.gz>
# Overwrites the OS on the boot USB in place, then you reboot. The live modloop is
# busy (loop-mounted), so we free it first with _free_modloop (copies only the
# kernel modules to RAM, detaches the loopback) — after that the modloop file can
# be rewritten safely. Config (/cfg) and data disks are never touched.
cmd_upgrade() {
	local img url assume_yes a lb plb pbe page tmp img_gz need_kb avail_kb sums want got ec f d av cb pw rl svc sdirs sfiles old_wb new_wb old_rc new_rc
	img=""; url=""; UPG_DLF=""; assume_yes=0
	for a in "$@"; do
		case "$a" in
			--check) _upgrade_check; return $? ;;
			--yes)   assume_yes=1 ;;   # scripted use: skip the YES gate (warning still prints)
			-*) usage "nas upgrade [--yes] <mountnas-*.img.gz | https://.../mountnas-*.img.gz | --check>   (see UPGRADE.md)"; return 1 ;;
			*) img="$a" ;;
		esac
	done
	[ -n "$img" ] || { usage "nas upgrade [--yes] <mountnas-*.img.gz | https://.../mountnas-*.img.gz | --check>   (see UPGRADE.md)"; return 1; }
	case "$img" in
		http://*|https://*) url="$img" ;;
		*) [ -f "$img" ] || { bad "not found: $img"; return 1; } ;;
	esac

	# ---- warning + backup gate ----
	cat <<EOF

${C_FA}  ========================= UPGRADE WARNING =========================${C_NO}
  This rewrites the OS on the boot USB. If it fails, this box may not
  boot again.
    * FIRST run:  nas backup   — it images this USB to a file. COPY that
      file to ANOTHER computer (not this box).
    * Recover a failed upgrade by writing that image to a DIFFERENT USB
      and booting from it.
    * NEVER boot with two MountNAS USB drives attached at once
      (duplicate disk labels will collide).
${C_FA}  ===================================================================${C_NO}
EOF
	lb=$(cat "$STATE/last-backup" 2>/dev/null || true)
	[ -n "$lb" ] && echo "  Last 'nas backup' this session: $lb" || echo "  No 'nas backup' recorded this session."
	plb=$(cat /etc/mountnas/last-backup 2>/dev/null || true)
	if [ -n "$plb" ] && [ -z "$lb" ]; then
		# show the age too, loudly when stale: this gate exists so nobody
		# upgrades against a rollback net that is months out of date
		pbe=${plb%% *}; page=""
		case "$pbe" in ''|*[!0-9]*) ;; *) page=$(( ( $(date +%s) - pbe ) / 86400 )) ;; esac
		echo "  Last recorded 'nas backup' (earlier session): ${plb#* }${page:+  ($page day(s) ago)}"
		if [ -n "$page" ] && [ "$page" -gt 90 ]; then
			printf '  %sThat backup is over 3 months old — run nas backup again FIRST.%s\n' "$C_FA" "$C_NO"
		fi
	fi
	if [ "$assume_yes" = 1 ]; then
		echo "  --yes given: proceeding without the interactive confirmation."
	else
		printf '  Type YES (uppercase) to confirm you have a backup and continue: '
		read -r a; [ "$a" = YES ] || { echo "Aborted — no changes made."; return 1; }
	fi
	_ops_log upgrade-start "from $RELEASE, source: ${url:-$img}"

	_mount_boot_rw || return 1

	# ---- cleanup that also fires on Ctrl-C / kill ----
	# The download + unpack stages hold multi-GB temp files and a loop device;
	# without a trap an interrupted upgrade leaks them (temp space usually lives
	# on the data disk). Idempotent: every step is guarded, so running it again
	# on the EXIT trap after an explicit call is harmless.
	# The UPG_ names are GLOBAL, and the prefix says so: the EXIT trap runs
	# _cleanup AFTER this function returns, when a local would already be gone.
	# _boot_restore reads UPG_COMMITTED from inside that same trap. Never
	# declare these local. (UPG_DLF is set with the arguments, further up.)
	UPG_RAW=""; UPG_MNT=""; UPG_LOOP=""; UPG_COMMITTED=0
	_cleanup() {
		[ -n "$UPG_MNT" ] && umount "$UPG_MNT" 2>/dev/null
		[ -n "$UPG_LOOP" ] && losetup -d "$UPG_LOOP" 2>/dev/null
		[ -n "$UPG_RAW" ] && rm -f "$UPG_RAW"
		[ -n "$UPG_DLF" ] && rm -f "$UPG_DLF"
		[ -n "$UPG_MNT" ] && rmdir "$UPG_MNT" 2>/dev/null
		# every exit (failure return via the EXIT trap, signal, success) also
		# restores the running system's state: apks bind + BOOT read-only
		_boot_restore
		return 0
	}
	# HUP included: an upgrade started over SSH must clean up its multi-GB temp
	# files when the session drops (ash skips EXIT traps on untrapped signals).
	trap '_cleanup; trap - EXIT HUP INT TERM; exit 130' HUP INT TERM
	trap '_cleanup' EXIT

	# ---- choose temp space and pre-check it fits the decompressed image ----
	# Work in KiB with df -Pk so this holds under both busybox and coreutils df.
	tmp="${TMPDIR:-}"
	[ -n "$tmp" ] || { mountpoint -q "$DATA" && tmp="$DATA" || { bad "no temp space: data disk not mounted. Mount it or set TMPDIR=<disk dir>."; return 1; }; }
	# gzip is detected by CONTENT (the 1f 8b magic), never by filename: a
	# beta-2 tester fed a correctly-gzipped image saved as .img.tgz and the
	# old *.gz match treated the compressed bytes as a raw disk image
	# (losetup garbage, unmountable p1). URLs are assumed compressed until
	# downloaded (releases ship .img.gz), then re-sniffed.
	img_gz=0
	if [ -n "$url" ]; then
		img_gz=1
	elif [ "$(od -An -tx1 -N2 "$img" 2>/dev/null | tr -d ' \t\n')" = "1f8b" ]; then
		img_gz=1
	fi
	if [ "$img_gz" = 1 ]; then
		need_kb=3932160   # ~3.75 GiB: image is 3.5 GiB raw (gzip -l is unreliable >4 GiB)
	else
		need_kb=$(( ( $(stat -c %s "$img" 2>/dev/null || echo 3758096384) / 1024 ) + 262144 ))
	fi
	[ -n "$url" ] && need_kb=$((need_kb + 2097152))   # + ~2 GiB for the downloaded .img.gz
	avail_kb=$(df -Pk "$tmp" 2>/dev/null | awk 'NR==2{print $4}')
	if [ -z "$avail_kb" ] || [ "$avail_kb" -lt "$need_kb" ]; then
		bad "not enough free space in $tmp to unpack the image."
		bad "need ~$((need_kb/1024)) MB, have ~$(( ${avail_kb:-0} /1024)) MB. Free space or set TMPDIR=<bigger dir>."
		return 1
	fi

	# ---- URL: download into temp space, verify against SHA256SUMS if published ----
	if [ -n "$url" ]; then
		UPG_DLF="$tmp/.nas-upgrade.$$.${url##*/}"
		step "Downloading $url ..."
		if command -v curl >/dev/null 2>&1; then curl -fL -o "$UPG_DLF" "$url"
		else wget -O "$UPG_DLF" "$url"; fi \
			|| { bad "download failed"; rm -f "$UPG_DLF"; return 1; }
		# a GitHub release publishes SHA256SUMS next to the image — verify when found
		sums=$( { command -v curl >/dev/null 2>&1 && curl -fsL "${url%/*}/SHA256SUMS" \
			|| wget -qO- "${url%/*}/SHA256SUMS"; } 2>/dev/null || true)
		want=$(printf '%s\n' "$sums" | awk -v f="${url##*/}" '$2==f{print $1}')
		if [ -n "$want" ]; then
			got=$(sha256sum "$UPG_DLF" | awk '{print $1}')
			[ "$got" = "$want" ] && ok "checksum verified against SHA256SUMS" \
				|| { bad "checksum MISMATCH — refusing this download"; rm -f "$UPG_DLF"; return 1; }
		else
			warn "no SHA256SUMS found next to the URL — skipping checksum verification"
		fi
		img="$UPG_DLF"
		# re-sniff the actual downloaded bytes (a URL could serve either form)
		if [ "$(od -An -tx1 -N2 "$img" 2>/dev/null | tr -d ' \t\n')" = "1f8b" ]; then
			img_gz=1
		else
			img_gz=0
		fi
	fi

	# ---- unpack + loop-mount the image's BOOT partition (p1) ----
	# mktemp failing here means the RAM root is full — name that, instead of
	# letting every later mount fail and blaming the user's image file.
	UPG_RAW="$tmp/.nas-upgrade.$$.img"
	UPG_MNT=$(mktemp -d) || { bad "cannot create a temp directory — RAM root full? check: df -h /"; _cleanup; return 1; }
	[ -n "$UPG_MNT" ] || { bad "cannot create a temp directory — RAM root full? check: df -h /"; _cleanup; return 1; }
	step "Unpacking image into $tmp ..."
	if [ "$img_gz" = 1 ]; then
		# pv shows unpack progress when available; gzip -dc itself still
		# detects a truncated/corrupt stream, so no extra status capture.
		if command -v pv >/dev/null 2>&1; then pv "$img" | gzip -dc > "$UPG_RAW"
		else gzip -dc "$img" > "$UPG_RAW"; fi \
			|| { bad "decompress failed"; _cleanup; return 1; }
	else
		cp "$img" "$UPG_RAW" || { bad "copy failed"; _cleanup; return 1; }
	fi
	# the downloaded .gz is no longer needed once unpacked — free the space now
	[ -n "$UPG_DLF" ] && { rm -f "$UPG_DLF"; UPG_DLF=""; }
	UPG_LOOP=$(losetup -fP --show "$UPG_RAW") || { bad "losetup failed"; _cleanup; return 1; }
	# losetup -fP scans the partition table ASYNCHRONOUSLY, and eudev then
	# re-processes the loop's change events — each rescan DELETES and re-adds
	# the partition nodes, so "the node exists" is not "the node is stable".
	# The old wait-for-existence + one-shot mount still aborted an upgrade when
	# the mount landed in a deletion window (caught by the QEMU suite's
	# docker-survives-upgrade run validating 1.0rc3, with dockerd keeping udev
	# busy). Settle udev when available, then retry the MOUNT itself (bounded,
	# ~10s) — existence-then-mount can never be race-free.
	command -v partprobe >/dev/null 2>&1 && partprobe "$UPG_LOOP" 2>/dev/null
	command -v udevadm >/dev/null 2>&1 && udevadm settle -t 5 2>/dev/null
	pw=0
	until mount -o ro "${UPG_LOOP}p1" "$UPG_MNT" 2>/dev/null; do
		pw=$((pw+1))
		if [ "$pw" -ge 50 ]; then
			# Separate the two causes the retry would otherwise merge: a payload
			# with no partition table at all vs. a partition we could never mount.
			if [ ! -b "${UPG_LOOP}p1" ]; then
				bad "this file has no BOOT partition — is it really a MountNAS release image (mountnas-<tag>.img.gz)?"
			else
				bad "the image's BOOT partition exists but would not mount — corrupt or truncated download?"
			fi
			_cleanup; return 1
		fi
		sleep 0.2
	done
	for f in boot/vmlinuz-lts boot/initramfs-lts boot/modloop-lts; do
		[ -f "$UPG_MNT/$f" ] || { bad "image is missing $f — not a MountNAS image?"; _cleanup; return 1; }
	done

	# ---- free the live modloop so we can overwrite it in place ----
	# _free_modloop copies ONLY the kernel modules to RAM (not the firmware
	# tree) and does its own headroom pre-check — fits comfortably on 4 GB
	# boxes, unlike Alpine's copy-modloop (see the function comment).
	step "Freeing the live modloop (copying kernel modules to RAM) ..."
	umount "$STATE/apks" 2>/dev/null || true   # release the mountnas bind on $BOOTMNT/apks (re-bound by _boot_restore on abort)
	_free_modloop || { bad "could not free the modloop — aborting (nothing on the USB was changed yet)"; _cleanup; return 1; }

	# ---- overwrite boot files in place, crash-safe (stage all, then rename) ----
	step "Writing the new system to the USB ..."
	cp "$BOOTMNT/world.base" "$STATE/old.world.base" 2>/dev/null || true
	# The BOOT copy lives on FAT, which a power cut can truncate to zero — and
	# without a valid PREVIOUS base the reconciliation below cannot tell user
	# extras from base packages, so it keeps everything this release dropped
	# (they then fail to resolve from the new on-media repo). The mountnas
	# service mirrors world.base into /etc at every boot exactly for this.
	[ -s "$STATE/old.world.base" ] || cp /etc/mountnas/world.base "$STATE/old.world.base" 2>/dev/null || true
	cp "$BOOTMNT/rc.base" "$STATE/old.rc.base" 2>/dev/null || true
	# Phase 1 — stage: every payload is copied to a .new name first. All the
	# slow USB writes happen here while the old system is still complete and
	# bootable; a failure or power cut in this phase changes nothing.
	# Bootloader payload (EFI, boot/grub) rides along: plain files on the FAT —
	# safe to replace from a running box, unlike the VBR/MBR boot code, which
	# stays untouched. grub's core and modules ship as a matched pair from the
	# build; refreshing them with the kernel avoids running an ever-newer system
	# under an ever-older loader. Optional entries are guarded so an older image
	# without them simply skips them.
	#
	# ldlinux.c32 is deliberately NOT refreshed. syslinux 6.x requires
	# ldlinux.sys and the .c32 modules to come from the SAME syslinux version,
	# and ldlinux.sys can only be written by 'syslinux --install' against the
	# UNMOUNTED partition (it patches a sector map into the boot record), which
	# a running box cannot do and which ships no syslinux binary anyway. Copying
	# only the .c32 half left a new module beside an old loader, and the next
	# legacy-BIOS boot stopped at "Failed to load ldlinux.c32" — an unbootable
	# headless box. The flashed pair stays matched and keeps booting; the config
	# it reads is regenerated by write-bootcfg below.
	ec=0; sfiles=""; sdirs=""
	for f in boot/vmlinuz-lts boot/initramfs-lts boot/modloop-lts; do
		_stage_file "$UPG_MNT/$f" "$BOOTMNT/$f" && sfiles="$sfiles $f" || ec=1
	done
	# cmdline.base rides along: write-bootcfg (below) reads the ON-MEDIA copy,
	# so skipping it would pin upgraded sticks to their original kernel cmdline
	# forever — a release that grows the boot module list would never arrive.
	for f in world.base alpine.base rc.base cmdline.base boot/amd-ucode.img boot/intel-ucode.img; do
		[ -f "$UPG_MNT/$f" ] || continue
		_stage_file "$UPG_MNT/$f" "$BOOTMNT/$f" && sfiles="$sfiles $f" || ec=1
	done
	_stage_dir "$UPG_MNT/apks" "$BOOTMNT/apks" && sdirs="$sdirs apks" || ec=1
	for d in EFI boot/grub confd.base; do
		[ -d "$UPG_MNT/$d" ] || continue
		_stage_dir "$UPG_MNT/$d" "$BOOTMNT/$d" && sdirs="$sdirs $d" || ec=1
	done
	if [ "$ec" != 0 ]; then
		# remove staged leftovers (a failed cp can leave a partial .new) — the
		# running system on the USB was never touched
		for f in boot/vmlinuz-lts boot/initramfs-lts boot/modloop-lts world.base alpine.base rc.base cmdline.base boot/amd-ucode.img boot/intel-ucode.img; do
			rm -f "$BOOTMNT/$f.new"
		done
		for d in apks EFI boot/grub confd.base; do rm -rf "$BOOTMNT/$d.new"; done
		bad "staging the new system failed (USB full or failing?) — nothing on the USB was changed."
		_cleanup; trap - EXIT HUP INT TERM
		return 1
	fi
	# push all staged data to the stick so the rename window carries no
	# pending writes, then commit with back-to-back renames (phase 2)
	sync
	UPG_COMMITTED=1   # from here the on-USB repo may be the new release's — no apks rebind (see _boot_restore)
	for f in $sfiles; do _commit_file "$BOOTMNT/$f" || ec=1; done
	for d in $sdirs; do _commit_dir "$BOOTMNT/$d" || ec=1; done
	sync
	if [ "$ec" != 0 ]; then
		_cleanup; trap - EXIT HUP INT TERM
		bad "some files failed to write — RESTORE YOUR BACKUP before rebooting."
		_ops_log upgrade "FAILED after write — restore backup (was $RELEASE)"
		# the one alert you most want pushed to your phone (best-effort)
		/usr/libexec/mountnas/notify "UPGRADE FAILED — action required" \
			"nas upgrade failed AFTER writing to the boot USB. Do NOT reboot until you have restored your 'nas backup' image (see UPGRADE.md)." \
			>/dev/null 2>&1 || true
		return 1
	fi

	# ---- reconcile /etc/apk/world (preserve user-added pkgs across the version bump) ----
	# extras = current world - the OLD release's base ; new world = NEW base ∪ extras.
	# The next boot installs this world from the new on-USB apks repo. awk (not comm)
	# so we need no sorted input and no extra binary.
	new_wb="$BOOTMNT/world.base"; old_wb="$STATE/old.world.base"
	# -s (not -f): with an EMPTY first file the awk NR==FNR idiom matches the
	# second file too, so every user-installed package would be silently dropped
	# from world. A zero-byte world.base is a real state — FAT truncates files
	# to zero on power loss.
	if [ -s "$new_wb" ]; then
		if [ -s "$old_wb" ]; then
			awk 'NR==FNR{a[$1];next} !($1 in a)' "$old_wb" /etc/apk/world > "$STATE/extras.$$"
			cat "$new_wb" "$STATE/extras.$$" | sort -u > "$STATE/desired.$$"
		else
			cat "$new_wb" /etc/apk/world | sort -u > "$STATE/desired.$$"
			warn "previous world.base missing — can't drop removed packages this upgrade"
		fi
		cp "$STATE/desired.$$" /etc/apk/world
		rm -f "$STATE/extras.$$" "$STATE/desired.$$"
	fi

	# ---- reconcile the shipped runlevel table (rc.base) ----
	# WHY this is not the union the world uses: removing a service from its
	# runlevel is the ONE documented way to disable it (README "Disabling
	# Unused Services"), so a union would silently undo every user's
	# 'rc-update del smartd default' at every upgrade. This is a THREE-WAY
	# merge instead — it adds only what is NEW in this release and removes only
	# what this release DROPPED, leaving anything present in both bases exactly
	# as the box has it. Without it a newly enabled service (ufw in 1.0rc3,
	# zram-init after it) reaches only freshly flashed sticks, never upgrades.
	# Every change is announced: an upgrade must never alter service state
	# silently.
	new_rc="$BOOTMNT/rc.base"; old_rc="$STATE/old.rc.base"
	if [ -s "$new_rc" ] && [ ! -s "$old_rc" ]; then
		# No PREVIOUS table: this stick predates the release that introduced
		# rc.base (1.0rc4), so there is nothing to three-way merge against and
		# the whole reconciliation used to be skipped. That left a service which
		# ships ENABLED but never reached upgraded boxes sitting in no runlevel
		# for good — ufw (so 'ufw enable' loads rules once and never again after
		# a reboot) and zram-init (no swap at all). A boot-time heal used to
		# cover those two by name; this replaces it with the shipped table.
		# ADD-ONLY and announced: with no previous base we cannot tell "new in
		# this release" from "the user disabled it", so we only ever add a
		# service that is in NO runlevel at all, and never remove one.
		warn "no previous runlevel table on this stick (pre-1.0rc4) — adding shipped services that are in no runlevel:"
		while read -r rl svc; do
			[ -n "${svc:-}" ] || continue
			[ -e "/etc/init.d/$svc" ] || continue
			rc-update show 2>/dev/null | grep -qE "^[[:space:]]*${svc}[[:space:]]" && continue
			if rc-update add "$svc" "$rl" >/dev/null 2>&1; then
				step "  enabled $svc ($rl) — ships enabled, absent from this box"
				_ops_log upgrade "enabled $svc ($rl) — no previous rc.base"
			fi
		done < "$new_rc"
	elif [ -s "$new_rc" ] && [ -s "$old_rc" ]; then
		while read -r rl svc; do
			[ -n "${svc:-}" ] || continue
			# already in the previous base -> not new -> the box's state wins
			grep -q "[[:space:]]$svc\$" "$old_rc" && continue
			[ -e "/etc/init.d/$svc" ] || continue
			# keyed on the NAME, not name+runlevel: if a later release MOVES a
			# service between runlevels, that must not resurrect one the user
			# deliberately disabled
			rc-update show 2>/dev/null | grep -qE "^[[:space:]]*${svc}[[:space:]]" && continue
			if rc-update add "$svc" "$rl" >/dev/null 2>&1; then
				step "  enabled $svc ($rl) — new in this release"
				_ops_log upgrade "enabled $svc ($rl)"
			fi
		done < "$new_rc"
		while read -r rl svc; do
			[ -n "${svc:-}" ] || continue
			grep -q "[[:space:]]$svc\$" "$new_rc" && continue
			if rc-update del "$svc" "$rl" >/dev/null 2>&1; then
				step "  disabled $svc ($rl) — no longer shipped"
				_ops_log upgrade "disabled $svc ($rl)"
			fi
		done < "$old_rc"
	fi

	# ---- seed NEW /etc/conf.d defaults (create-if-absent, NEVER overwrite) ----
	# conf.d files are user-owned config with arbitrary content — they cannot be
	# merged, and overwriting one would be far worse than the gap this closes
	# (/etc/conf.d/mountnas carries DATA_SERVICES, so a blind copy would
	# re-enable Docker on every box that turned it off). A file that exists is
	# left alone; a changed shipped default lands beside it as .new.
	if [ -d "$BOOTMNT/confd.base" ]; then
		mkdir -p /etc/conf.d
		for f in "$BOOTMNT"/confd.base/*; do
			[ -f "$f" ] || continue
			cb=$(basename "$f")
			if [ ! -e "/etc/conf.d/$cb" ]; then
				# explicit mode: the source lives on FAT, which reports whatever
				# the mount's fmask says rather than the file's real 0644
				cp "$f" "/etc/conf.d/$cb" 2>/dev/null && chmod 0644 "/etc/conf.d/$cb" \
					&& step "  seeded /etc/conf.d/$cb — new in this release"
			elif ! cmp -s "$f" "/etc/conf.d/$cb"; then
				cp "$f" "/etc/conf.d/$cb.new" 2>/dev/null \
					&& hint "  shipped default changed: /etc/conf.d/$cb.new (yours is untouched)"
			fi
		done
	fi

	# ---- re-pin the CDN repos to the new base's Alpine version ----
	# /etc/apk/repositories is user-owned config, so only the dl-cdn version
	# component is rewritten (from the alpine.base marker the image ships);
	# user-added repo lines are untouched. Without this a box upgraded across
	# an Alpine release would keep pulling packages for the OLD version.
	if [ -f "$BOOTMNT/alpine.base" ]; then
		av=$(cat "$BOOTMNT/alpine.base" 2>/dev/null)
		[ -n "$av" ] && sed -i -E "s#(dl-cdn\.alpinelinux\.org/alpine/)v[0-9]+\.[0-9]+/#\1v$av/#" /etc/apk/repositories 2>/dev/null || true
	fi

	# ---- regenerate the (single-slot) bootloader config + persist config ----
	# Both steps below are checked. They used to run with their status
	# discarded, so a failure fell straight through to "Upgrade written
	# successfully" and the box was told to reboot.
	if ! "$WBCFG" "$BOOTMNT"; then
		sync; _cleanup; trap - EXIT HUP INT TERM
		bad "could not regenerate the bootloader config on the USB."
		bad "Do NOT reboot — restore your 'nas backup' image first (see UPGRADE.md)."
		_ops_log upgrade "FAILED at write-bootcfg (was $RELEASE)"
		/usr/libexec/mountnas/notify "UPGRADE FAILED — action required" \
			"nas upgrade could not write the bootloader config on $(hostname). Do NOT reboot until you have restored your backup image." \
			>/dev/null 2>&1 || true
		return 1
	fi
	sync
	# BOOT writes are done: release the temp resources and put BOOT back ro.
	# _cleanup ends in _boot_restore (remount ro), so it must run AFTER
	# write-bootcfg — the last step that writes to $BOOTMNT — not right after
	# the renames as it used to.
	_cleanup; trap - EXIT HUP INT TERM
	# The new OS is on the USB either way, but this upgrade's three /etc writes
	# (the reconciled apk world, the seeded conf.d defaults, the re-pinned
	# repositories) live in RAM until this commit lands. A discarded failure
	# here meant the box was told to reboot and then came up on the NEW system
	# with the PREVIOUS release's world — the base-versus-media-repo skew that
	# breaks apk at every later boot.
	if ! cmd_commit --no-ask; then
		echo
		bad "The new system is written, but SAVING YOUR CONFIG FAILED."
		bad "This upgrade's /etc changes are in RAM only and a reboot LOSES them."
		hint "Fix the config partition, then run:   nas commit"
		hint "Check what is wrong with:             nas status   (and: df -h /cfg)"
		hint "Do not reboot until 'nas commit' succeeds."
		_ops_log upgrade "written but COMMIT FAILED (was $RELEASE) — run nas commit"
		/usr/libexec/mountnas/notify "upgrade written — commit FAILED" \
			"nas upgrade wrote the new system on $(hostname) but could not save the config. Run 'nas commit' before rebooting." \
			>/dev/null 2>&1 || true
		return 1
	fi

	echo
	# real ok() (the old heredoc faked an uncolored "[ OK ]"); the literal
	# "Upgrade written successfully" is a CI expect string — keep it contiguous
	ok "Upgrade written successfully. Your config and data disks are untouched."
	_ops_log upgrade "ok (was $RELEASE) — reboot pending"
	/usr/libexec/mountnas/notify "upgrade written" \
		"nas upgrade completed on $(hostname) (was $RELEASE). Reboot to run the new version." \
		>/dev/null 2>&1 || true
	hint "Reboot to run the new version:   nas reboot"
	hint "If the new version misbehaves, restore your 'nas backup' image"
	hint "to another USB and boot from it."
}

# help page for 'nas upgrade --help' / 'nas help upgrade'
help_upgrade() {
	cat <<EOF
nas upgrade [--yes] <img.gz | URL>   |   nas upgrade --check
  Rewrite the OS on the boot USB in place (config/data untouched), then
  reboot. URLs are checksum-verified against the release SHA256SUMS.
  --check  ask GitHub whether a newer release exists
  --yes    skip the interactive confirmation (scripted use)
  Run 'nas backup' FIRST — there is no automatic rollback. See UPGRADE.md.
EOF
}
