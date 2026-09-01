# shellcheck shell=sh
# nas commit / nas save
# Sourced by /usr/sbin/nas (never run directly). Shared helpers: lib.sh.

cmd_commit() {
	# --no-ask: internal callers only (wizard, upgrade, shutdown --save) —
	# their commits must never stop for the interactive note prompt below
	local ask note nts keep f sz verbose delta n_delta n_total
	ask=1; verbose=0
	while :; do
		case "${1:-}" in
			--no-ask) ask=0; shift ;;
			-v|--verbose) verbose=1; shift ;;
			*) break ;;
		esac
	done
	note=""
	if [ "${1:-}" = "-m" ]; then
		note="${2:-}"
		[ -n "$note" ] || { usage "nas commit [-v] [-m \"what you changed\"]"; return 1; }
		# notes are one line in a tab-separated file — flatten hostile chars
		note=$(printf '%s' "$note" | tr '\t\n' '  ')
	elif [ -n "${1:-}" ]; then
		usage "nas commit [-v] [-m \"what you changed\"]"; return 1
	fi
	mountpoint -q "$CFG" || { bad "config partition ($CFG) not mounted — refusing (would save to RAM)"; return 1; }
	grep -qE "^\+/?(mnt/nasdata|mnt/disk|mnt/parity)" /etc/apk/protected_paths.d/lbu.list 2>/dev/null \
		&& { bad "a data path is in the lbu include list — refusing (would tar your data disk)"; return 1; }
	# No -m on an interactive run: ask for the note instead of making the user
	# remember the flag. Enter skips; prompting happens AFTER the refusal
	# gates so a doomed commit never asks first. Non-tty callers (ssh -T,
	# cron, pipes) skip straight through.
	if [ "$ask" = 1 ] && [ -z "$note" ] && [ -t 0 ] && [ -t 1 ]; then
		printf 'Note for this save (Enter for none): '
		IFS= read -r note || note=""
		note=$(printf '%s' "$note" | tr '\t\n' '  ')
	fi
	# Show what THIS commit saves (the delta), not the whole archive: lbu
	# rebuilds the complete overlay tarball every time, so its -v listing
	# prints ~100 steady-state files and tar's "socket ignored" noise — which
	# reads as "why is it saving everything?!" when the user changed two
	# files. The full listing stays available behind -v.
	delta=$(lbu status 2>/dev/null)
	n_delta=$(printf '%s' "$delta" | grep -c .)
	if [ "${n_delta:-0}" -gt 0 ]; then
		step "Saving $n_delta change(s):"
		printf '%s\n' "$delta" | sed 's/^/    /'
	else
		step "No new changes — re-packing the overlay as-is..."
	fi
	if [ "$verbose" = 1 ]; then
		lbu commit -v || { bad "lbu commit failed"; return 1; }
	else
		# quiet path: swallow tar's per-member listing and its harmless
		# "socket ignored" warnings, but a FAILURE still shows its output
		f=$(lbu commit -v 2>&1) || {
			printf '%s\n' "$f" | tail -n 6 | sed 's/^/    /'
			bad "lbu commit failed"; return 1; }
	fi
	n_total=$(tar -tzf "$CFG/$(hostname).apkovl.tar.gz" 2>/dev/null | grep -vc '/$')
	hint "full overlay re-packed: ${n_total:-?} files -> $CFG/$(hostname).apkovl.tar.gz (list: nas commit -v)"
	if [ -n "$note" ]; then
		nts=$(date -u -r "$CFG/$(hostname).apkovl.tar.gz" +%Y%m%d%H%M%S 2>/dev/null)
		[ -n "$nts" ] && printf '%s\t%s\n' "$nts" "$note" >> "$CFG/.mountnas-notes" 2>/dev/null
	fi
	# Prune notes whose snapshot lbu has rotated away: keep entries whose
	# mtime-stamp matches a tarball still on /cfg (any hostname, so snapshots
	# from before a hostname change keep theirs). Without this the file
	# collects an orphaned line for every rotation, forever.
	if [ -f "$CFG/.mountnas-notes" ]; then
		keep=$(for f in "$CFG"/*.tar.gz; do date -u -r "$f" +%Y%m%d%H%M%S 2>/dev/null; done)
		awk -F'\t' -v k="$keep" 'BEGIN{n=split(k,a,/[[:space:]]+/); for(i=1;i<=n;i++)K[a[i]]=1} $1 in K' \
			"$CFG/.mountnas-notes" > "$CFG/.mountnas-notes.new" 2>/dev/null \
			&& mv "$CFG/.mountnas-notes.new" "$CFG/.mountnas-notes" \
			|| rm -f "$CFG/.mountnas-notes.new"
	fi
	sz=$(du -k "$CFG"/*.apkovl.tar.gz 2>/dev/null | awk '{s+=$1}END{print s}')
	[ "${sz:-0}" -gt 51200 ] && warn "overlay is large (${sz}KB) — a big file in a tracked path (e.g. /root)?"
	_mirror_overlay
	_ops_log commit "${note:-(no note)}"
	ok "saved to $CFG${note:+  (note: $note)}"
}

# help page for 'nas commit' / 'nas save --help' / 'nas help commit'
help_commit() {
	cat <<EOF
nas commit [-v] [-m "note"]   (alias: nas save)
  Save the in-RAM /etc changes to the USB config partition. Review first
  with 'nas changes --diff'. Undo a bad commit with 'nas rollback'.
  Prints what THIS commit saves; the overlay itself is always re-packed
  in full (that is how lbu works). -v lists every packed file.
  Each commit also mirrors the overlay to /mnt/nasdata/config-backups/
  (newest 30) — the disaster copy if the boot stick dies (see README
  "Recovery from a dead USB").
  Run interactively without -m, it asks for a note (Enter skips) — notes
  are shown by 'nas rollback --list', so snapshots stay identifiable
  ("before enabling nfs", "smb share added", ...). -m still works for
  scripts and one-liners.
EOF
}
