# shellcheck shell=sh
# nas backup
# Sourced by /usr/sbin/nas (never run directly). Shared helpers: lib.sh.

# Full image of the WHOLE boot USB (OS + config partition) to a gzip file. This
# is the rollback net for 'nas upgrade': restore = write the image back to a
# USB and boot it. Reading the device while running is safe (dd/gzip only reads);
# we briefly remount /cfg read-only so its filesystem is quiescent in the image.
cmd_backup() {
	# strict args: a bare path ('nas backup /mnt/usb/x.img.gz' — forgetting
	# --to) used to be silently IGNORED and the image landed in the default
	# location, discovered only during a disaster restore. Unknown args and a
	# missing --to value are usage errors like every other subcommand.
	dest=""
	case "${1:-}" in
	"") ;;
	--to)
		dest="${2:-}"
		[ -n "$dest" ] || { usage "nas backup [--to <dir|file>]"; return 1; }
		[ -z "${3:-}" ] || { usage "nas backup [--to <dir|file>]"; return 1; }
		;;
	*) usage "nas backup [--to <dir|file>]"; return 1 ;;
	esac
	cat <<EOF
  Note: this images the BOOT USB (the OS + your saved config on MNASCFG).
  It does NOT back up your data disks or Docker data — those live on
  separate storage and are not part of this image.
EOF
	disk=$(_boot_usb_disk)
	[ -n "$disk" ] || { bad "cannot find the BOOT partition or its parent disk"; return 1; }
	dev="/dev/$disk"
	if [ -z "$dest" ]; then
		mountpoint -q "$DATA" || { bad "data disk not mounted — give a target: nas backup --to <dir|file>"; return 1; }
		dest="$DATA/backups"; mkdir -p "$dest"
	fi
	if [ -d "$dest" ]; then out="$dest/mountnas-backup-$(hostname)-$(date +%Y%m%d-%H%M%S).img.gz"; else out="$dest"; fi
	sz=$(lsblk -bdno SIZE "$dev" 2>/dev/null)
	echo "Imaging $dev (~$(( ${sz:-0} /1048576)) MB) -> $out"
	echo "This can take several minutes; the image compresses (mostly-empty space shrinks away)."
	mkdir -p "$STATE" 2>/dev/null || true
	# /cfg is remounted read-only for a quiescent image. An interrupt (Ctrl-C,
	# or HUP from a dropped SSH session — backups are typically run over SSH)
	# during the multi-minute imaging must never strand it read-only — every
	# later 'nas commit' would fail long after the cause is forgotten — and must
	# not leave a partial backup file behind. (An untrapped fatal signal skips
	# EXIT traps in ash, so HUP must be trapped explicitly.)
	trap 'mount -o remount,rw "$CFG" 2>/dev/null; rm -f "$out"; echo; bad "backup interrupted — partial file removed, $CFG restored read-write"; exit 130' HUP INT TERM
	sync; mount -o remount,ro "$CFG" 2>/dev/null || true
	# pv gives a progress bar + ETA when available. Both stages must be checked:
	# if pv hits a read error mid-device, gzip still exits 0 on the truncated
	# stream — so pv drops a marker file on failure.
	if command -v pv >/dev/null 2>&1; then
		rm -f "$STATE/pv.err"
		{ pv "$dev" || : > "$STATE/pv.err"; } | gzip -c > "$out" && [ ! -f "$STATE/pv.err" ] && rc=0 || rc=1
		rm -f "$STATE/pv.err"
	else
		gzip -c < "$dev" > "$out" && rc=0 || rc=1
	fi
	trap - HUP INT TERM
	if [ "$rc" = 0 ]; then
		mount -o remount,rw "$CFG" 2>/dev/null \
			|| warn "could not remount $CFG read-write — 'nas commit' will fail until you run: mount -o remount,rw $CFG"
		sync
		# Read the file back and check the gzip stream end-to-end. This image is
		# the ONLY rollback net for 'nas upgrade' — a bad sector or truncated
		# write on the destination is best caught now, not during a disaster
		# restore months later.
		echo "Verifying the written image (gzip -t) ..."
		gzip -t "$out" 2>/dev/null \
			|| { bad "verification FAILED — the written backup is corrupt: $out"; rm -f "$out"; return 1; }
		ok "backup written and verified: $out"
		date '+%Y-%m-%d %H:%M' > "$STATE/last-backup" 2>/dev/null || true
		# persistent copy ("<epoch> <date>") so 'nas status' and the upgrade gate
		# can report backup age across reboots (saved with the next commit)
		mkdir -p /etc/mountnas 2>/dev/null || true
		printf '%s %s\n' "$(date +%s)" "$(date '+%Y-%m-%d %H:%M')" > /etc/mountnas/last-backup 2>/dev/null || true
		_ops_log backup "verified -> $out"
		warn "COPY THIS FILE TO ANOTHER COMPUTER — a backup stored only on this box can't save a dead box."
	else
		mount -o remount,rw "$CFG" 2>/dev/null \
			|| warn "could not remount $CFG read-write — 'nas commit' will fail until you run: mount -o remount,rw $CFG"
		bad "backup failed (out of space?): $out"; rm -f "$out" 2>/dev/null; return 1
	fi
}

# help page for 'nas backup --help' / 'nas help backup'
help_backup() {
	cat <<EOF
nas backup [--to <dir|file>]
  Image the WHOLE boot USB (OS + saved config) to a gzip file and verify
  it. Default target: /mnt/nasdata/backups. Copy it OFF this box.
  Restore: write it to a DIFFERENT stick (Etcher/dd) and boot that.
  Data disks are NOT included — back those up separately (restic is baked in).
EOF
}
