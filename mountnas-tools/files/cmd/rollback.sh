# shellcheck shell=sh
# nas rollback
# Sourced by /usr/sbin/nas (never run directly). Shared helpers: lib.sh.

# nas rollback — the config time machine. lbu already keeps BACKUP_LIMIT prior
# overlays on /cfg (named <hostname>.<YYYYMMDDHHMMSS>.tar.gz, mtime-ordered);
# this exposes them. Restoring swaps the ACTIVE overlay
# (<hostname>.apkovl.tar.gz), which the diskless init applies at the NEXT boot —
# the running system is untouched until then. The pre-rollback overlay is
# preserved under lbu's own backup naming, so a rollback can itself be rolled
# back (roll forward). Before this existed, recovering from a bad commit meant
# pulling the stick and hand-editing tarballs on another machine.
_ovl_backups() {   # newest first, one path per line
	ls -1t "$CFG/$(hostname)".[0-9]*.tar.gz 2>/dev/null
}
cmd_rollback() {
	local act list i f fn an sel seln ts keep kc
	act="$CFG/$(hostname).apkovl.tar.gz"
	mountpoint -q "$CFG" || { bad "config partition ($CFG) not mounted"; return 1; }
	# a power cut between cp and mv in a previous rollback can leave a stale
	# .new behind — clear it, or the encrypted-overlay glob below matches it
	# and locks rollback out forever with a misleading error. Glob over every
	# hostname: a .new staged before a hostname change is just as stale, and
	# clearing only the current host's left it tripping the glob forever.
	rm -f "$CFG"/*.apkovl.tar.gz.new
	if ls "$CFG"/*.apkovl.tar.gz.* >/dev/null 2>&1; then
		bad "encrypted overlay detected — nas rollback supports plain overlays only"; return 1
	fi
	list=$(_ovl_backups)
	if [ -z "${1:-}" ] || [ "$1" = "--list" ]; then
		hdr "Saved-config snapshots on $CFG"
		hint "newest first; lbu keeps the last few"
		if [ -f "$act" ]; then
			an=$(_snap_note "$act")
			printf '       %-20s %8s  %s%s\n' \
				"$(date -r "$act" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" \
				"$(du -k "$act" 2>/dev/null | awk '{print $1"K"}')" \
				"${C_B}ACTIVE (applies at next boot)${C_NO}" "${an:+  — $an}"
		fi
		if [ -z "$list" ]; then
			echo "  (no snapshots yet — they appear from your second 'nas commit' on)"
		else
			i=1
			printf '%s\n' "$list" | while read -r f; do
				fn=$(_snap_note "$f")
				printf '  %-4s %-20s %8s  %s%s\n' "[$i]" \
					"$(date -r "$f" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" \
					"$(du -k "$f" 2>/dev/null | awk '{print $1"K"}')" \
					"$(basename "$f")" "${fn:+  — $fn}"
				i=$((i+1))
			done
		fi
		hint "Restore one with: nas rollback <number>   (applies at the NEXT boot)"
		hint "Label your commits so this list stays readable:  nas commit -m \"note\""
		return 0
	fi
	case "$1" in *[!0-9]*) usage "nas rollback [--list | <number>]"; return 1 ;; esac
	sel=$(printf '%s\n' "$list" | awk -v n="$1" 'NR==n{print; exit}')
	[ -n "$sel" ] || { bad "no snapshot number $1 — see: nas rollback --list"; return 1; }
	[ -f "$act" ] || { bad "no active overlay at $act (hostname changed since the last commit?)"; return 1; }
	seln=$(_snap_note "$sel")
	echo "Rolling the SAVED config back to: $(basename "$sel")  ($(date -r "$sel" '+%Y-%m-%d %H:%M:%S' 2>/dev/null))${seln:+  — $seln}"
	echo "  - the running system is NOT changed; the restored config applies at the NEXT boot"
	echo "  - the current saved config is kept as a snapshot (you can roll forward)"
	echo "  - uncommitted changes stay in RAM and vanish at reboot, as always"
	confirm "Proceed?" || { echo "Cancelled."; return 1; }
	# preserve the current active overlay under lbu's own mtime-stamp naming
	ts=$(date -u -r "$act" +%Y%m%d%H%M%S 2>/dev/null || date -u +%Y%m%d%H%M%S)
	keep="$CFG/$(hostname).$ts.tar.gz"
	# loop (not a single retry) so no amount of collisions can silently
	# overwrite an existing snapshot; the digit suffix keeps the name inside
	# the pattern lbu rotates and _ovl_backups lists
	kc=0
	while [ -e "$keep" ]; do
		kc=$((kc+1)); keep="$CFG/$(hostname).$ts$kc.tar.gz"
	done
	# -p preserves the mtime — the note lookup keys off it
	cp -p "$act" "$keep" || { bad "could not preserve the current overlay — aborting, nothing changed"; return 1; }
	# stage + rename so a power cut cannot leave a torn active overlay
	if cp "$sel" "$act.new" && mv "$act.new" "$act"; then
		sync
		_ops_log rollback "restored $(basename "$sel")${seln:+ — $seln}"
		ok "restored $(basename "$sel") as the active saved config"
		# the mirror mirrors the ACTIVE overlay — a rollback just changed
		# it, and no commit follows a rollback, so refresh here too or the
		# disaster copy stays the config the user just rolled back FROM
		_mirror_overlay
		hint "Reboot to apply it:  nas reboot"
	else
		rm -f "$act.new"
		bad "restore failed — the active overlay is unchanged"; return 1
	fi
}

# help page for 'nas rollback --help' / 'nas help rollback'
help_rollback() {
	cat <<EOF
nas rollback [--list | <number>]
  Revert to a previous committed config. lbu keeps the last few overlays on
  /cfg automatically; --list shows them, <number> swaps one in as the
  active config (crash-safe). Applies at the NEXT boot; the replaced
  config is kept as a snapshot, so you can roll forward again.
Examples:
  nas rollback --list
  nas rollback 1 && nas reboot
EOF
}
