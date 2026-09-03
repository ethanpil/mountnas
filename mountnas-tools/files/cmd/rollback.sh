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
# newest first, one path per line. Deliberately across EVERY hostname, not
# just the current one: renaming the box does not rename its history, so a
# host-pinned glob hid every snapshot taken under the old name — while
# 'nas commit' retention, which is already host-agnostic, went on counting
# and deleting them. The time machine went blank at the exact moment a user
# most wants it, after a change big enough to rename the machine for.
# The restore path always WRITES the current hostname, so a snapshot from
# any era restores correctly.
# The case arm drops the ACTIVE overlay, which the wider glob can otherwise
# reach on a box whose hostname ends in a dot and digits (nas.2 ->
# nas.2.apkovl.tar.gz). The active overlay is printed separately above.
# 'ls -1t' supplies the newest-first order a glob cannot; the filter is a
# case, not a grep, so the order survives and shellcheck stays quiet.
_ovl_backups() {
	local _f
	ls -1t "$CFG"/*.[0-9]*.tar.gz 2>/dev/null | while IFS= read -r _f; do
		case "$_f" in *.apkovl.tar.gz) ;; *) printf '%s\n' "$_f" ;; esac
	done
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
	# The list above shows snapshots from every hostname this box has had, so
	# the restore must accept one. Right after a rename there is no overlay
	# under the NEW name yet, which used to refuse the restore and contradict
	# the list. Carry the overlay across first -- a no-op on a box that never
	# changed its name.
	[ -f "$act" ] || _rename_stale_overlay
	[ -f "$act" ] || { bad "no active overlay at $act — run 'nas commit' first"; return 1; }
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
	# stage + rename so a power cut cannot leave a torn overlay. Plain cp
	# ON PURPOSE (no -p): _mirror_overlay stamps the mirror from the active
	# overlay's mtime, and the restored config must become the NEWEST
	# mirror — the README's recovery step says "copy the newest"; an old
	# preserved stamp would make that step restore the config the user
	# just escaped.
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
