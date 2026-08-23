# shellcheck shell=sh
# nas history
# Sourced by /usr/sbin/nas (never run directly). Shared helpers: lib.sh.

# nas history — render the append-only operations log (see _ops_log). Answers
# "what happened to this box and when" in one read: setups, commits (with
# their notes), rollbacks, backups, upgrades, shutdowns/reboots — each with a
# UTC timestamp and who ran it. Zero setup, zero config, nothing to rotate.
cmd_history() {
	local hn
	hn=25
	case "${1:-}" in
		-n) hn="${2:-}"; case "$hn" in ''|*[!0-9]*) usage "nas history [-n N | --all]"; return 1 ;; esac ;;
		--all) hn=1000000 ;;
		'') : ;;
		*) usage "nas history [-n N | --all]"; return 1 ;;
	esac
	hdr "operations log"
	if [ ! -s "$OPSLOG" ]; then
		echo "  (empty — setups, commits, backups, upgrades and power events land here)"
		hint "kept at $OPSLOG on the config partition; persists without a commit"
		return 0
	fi
	tail -n "$hn" "$OPSLOG" | awk -F'\t' '{ printf "  %-20s  %-13s  %-20s  %s\n", $1, $2, $3, $4 }'
	hint "showing the last $hn (of $(wc -l < "$OPSLOG")) — full file: $OPSLOG"
}

# help page for 'nas history --help' / 'nas help history'
help_history() {
	cat <<EOF
nas history [-n N | --all]
  The append-only operations log: every setup, commit (with its note),
  rollback, backup, upgrade and shutdown/reboot — UTC timestamp, who ran
  it, and the outcome. Stored at /cfg/mountnas-ops.log on the config
  partition: persists immediately, NO 'nas commit' needed, survives even
  a box that comes up half-broken. Self-trimming (~1000 entries).
EOF
}
