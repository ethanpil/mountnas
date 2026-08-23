# shellcheck shell=sh
# nas changes
# Sourced by /usr/sbin/nas (never run directly). Shared helpers: lib.sh.

# nas changes (alias: changed) — list WHAT 'nas commit' would save, not just a
# count. Surfaces Alpine's own 'lbu status' (A=added M=modified D=deleted).
# --diff additionally shows unified diffs of each file against the committed
# overlay: review before you persist.
cmd_changes() {
	out=$(lbu status 2>/dev/null)
	n=$(printf '%s' "$out" | grep -c .)
	mkdir -p "$STATE"; printf '%s\n' "${n:-0}" > "$STATE/unsaved" 2>/dev/null || true; UNSAVED_FRESH=1
	if [ "${n:-0}" -eq 0 ]; then ok "no unsaved changes — nothing to commit"; return 0; fi
	echo "$n unsaved change(s) that 'nas commit' would save (A=added M=modified D=deleted):"
	printf '%s\n' "$out" | sed 's/^/  /'
	if [ "${1:-}" = "--diff" ]; then
		ovl="$CFG/$(hostname).apkovl.tar.gz"
		d=$(mktemp -d) || { bad "mktemp failed"; return 1; }
		if [ -f "$ovl" ]; then tar -xzf "$ovl" -C "$d" 2>/dev/null
		else warn "no committed overlay yet ($ovl) — every tracked file shows as new"; fi
		echo
		hint "--- committed (last nas commit)    +++ live (in RAM now)"
		printf '%s\n' "$out" | while read -r st path; do
			[ -n "$path" ] || continue
			old="$d/$path"; new="/$path"
			# live directories: mode/owner deltas still matter, content does not
			if [ -d "$new" ]; then
				if [ -e "$old" ]; then
					om=$(stat -c '%a %U:%G' "$old" 2>/dev/null)
					nm=$(stat -c '%a %U:%G' "$new" 2>/dev/null)
					[ "$om" != "$nm" ] && { sub "$st $path/"; echo "mode/owner: $om -> $nm"; }
				else
					sub "$st $path/ (new directory)"
				fi
				continue
			fi
			# deleted directory: diff cannot express it — list what disappears
			if [ ! -e "$new" ] && [ -d "$old" ]; then
				sub "$st $path/ (directory deleted; contents were:)"
				( cd "$d" && find "$path" 2>/dev/null | sed 's/^/  /' )
				continue
			fi
			sub "$st $path"
			# a chmod/chown is a real committed change a content diff cannot show
			om=""; nm=""
			if [ -e "$old" ] && [ -e "$new" ]; then
				om=$(stat -c '%a %U:%G' "$old" 2>/dev/null)
				nm=$(stat -c '%a %U:%G' "$new" 2>/dev/null)
				[ "$om" != "$nm" ] && echo "mode/owner: $om -> $nm"
			fi
			o="$old"; [ -e "$o" ] || o=/dev/null
			n="$new"; [ -e "$n" ] || n=/dev/null
			if [ "$o" != /dev/null ] && [ "$n" != /dev/null ] && cmp -s "$o" "$n"; then
				# identical bytes: say so rather than leaving a bare header
				[ "$om" = "$nm" ] && echo "  (no content or mode change visible — lbu may track other metadata)"
			elif [ -n "$C_OK" ]; then
				# tty: tint the diff (file headers/hunks cyan, adds green,
				# removals red). Raw ESC bytes ride through awk -v untouched
				# (no backslashes, so no escape processing). Piped output takes
				# the plain branch and stays patch-clean.
				diff -u "$o" "$n" 2>/dev/null | awk -v G="$C_OK" -v R="$C_FA" -v H="$C_HD" -v N="$C_NO" '
					/^(\+\+\+|---|@@)/ {print H $0 N; next}
					/^\+/ {print G $0 N; next}
					/^-/  {print R $0 N; next}
					{print}'
			else
				diff -u "$o" "$n" 2>/dev/null || true
			fi
		done
		rm -rf "$d"
		echo
	fi
	hint "Save them with: nas commit    (review first: nas changes --diff)"
}

# help page for 'nas changes' / 'nas changed --help' / 'nas help changes'
help_changes() {
	cat <<EOF
nas changes [--diff]
  List what 'nas commit' would save (A=added M=modified D=deleted).
  --diff   unified diffs of every file against the last committed overlay
EOF
}
