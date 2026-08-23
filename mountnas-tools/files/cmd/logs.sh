# shellcheck shell=sh
# nas logs
# Sourced by /usr/sbin/nas (never run directly). Shared helpers: lib.sh.

# nas logs — view the system log; --persist moves syslog onto the data disk.
# RAM logs vanish at reboot, so a crash or power cut — exactly when you need
# history — leaves nothing to read. Opt-in because periodic log writes keep
# the data disk awake (spin-down tradeoff). The mountnas service restarts
# syslogd after the data disk mounts at boot, so the target always exists by
# the time it is written.
cmd_logs() {
	local nn t unc
	case "${1:-}" in
	--persist)
		case "${2:-status}" in
		on)
			[ "$(cat "$STATE/data" 2>/dev/null)" = ok ] || { bad "data disk not mounted — persistent logs need $DATA"; return 1; }
			mkdir -p "$DATA/logs" || { bad "cannot create $DATA/logs"; return 1; }
			# -s = KB per file, -b = rotated copies kept; user tokens preserved
			_syslog_set_persist "-s 1024 -b 9 -O $DATA/logs/messages" \
				|| { bad "could not update /etc/conf.d/syslog"; return 1; }
			rc-service syslog restart >/dev/null 2>&1 || warn "syslog restart failed"
			ok "persistent logging ON -> $DATA/logs/messages (1 MB x 10 files)"
			warn "periodic writes keep the data disk awake — mind the spin-down tradeoff"
			hint "Persist the setting: nas commit"
			;;
		off)
			_syslog_set_persist "" \
				|| { bad "could not update /etc/conf.d/syslog"; return 1; }
			rc-service syslog restart >/dev/null 2>&1 || warn "syslog restart failed"
			ok "persistent logging OFF (logs live in RAM only again)"
			hint "Persist the setting: nas commit"
			;;
		''|status)
			t=$(_syslog_target)
			unc=""
			lbu status 2>/dev/null | grep -q "etc/conf.d/syslog" \
				&& unc=" — setting NOT saved, lost at reboot unless: nas commit"
			if [ -n "$t" ]; then
				if [ -n "$unc" ]; then warn "persistent logging ON -> $t$unc"
				else ok "persistent logging ON -> $t (saved)"; fi
			else
				if [ -n "$unc" ]; then warn "persistent logging OFF$unc"
				else ok "persistent logging OFF (RAM only; enable: nas logs --persist on)"; fi
			fi
			;;
		*)
			# a typo (onn, Off, --help) must not masquerade as a status query
			usage "nas logs --persist on|off|status"; return 1
			;;
		esac
		;;
	-f|--follow)
		t=$(_syslog_target); : "${t:=/var/log/messages}"
		# -F (follow by NAME, not fd): persistent logging rotates the file
		# (-s/-b in SYSLOGD_OPTS: messages -> messages.0, new file created),
		# and a plain -f keeps reading the rotated-away fd — the live view
		# silently freezes, exactly during the long watches it exists for.
		# -F also waits for a target that does not exist yet (persistence
		# configured but the data disk not mounted); say so instead of
		# leaving a silent blank screen.
		[ -f "$t" ] || warn "no log file at $t yet — waiting for it to appear"
		exec tail -F "$t"
		;;
	''|-n)
		nn=100
		if [ "${1:-}" = "-n" ]; then
			nn="${2:-100}"
			case "$nn" in ''|*[!0-9]*) usage "nas logs -n <lines>"; return 1 ;; esac
		fi
		t=$(_syslog_target); : "${t:=/var/log/messages}"
		hdr "$t (last $nn lines)"
		hint "follow: nas logs -f"
		tail -n "$nn" "$t" 2>/dev/null || warn "no log file at $t yet"
		;;
	*) usage "nas logs [-n N | -f | --persist on|off|status]"; return 1 ;;
	esac
}

# help page for 'nas logs' / 'nas log --help' / 'nas help logs'
help_logs() {
	cat <<EOF
nas logs [-n N | -f | --persist on|off|status]
  View the system log (RAM by default). --persist on moves syslog to
  /mnt/nasdata/logs with rotation so a crash leaves history behind —
  tradeoff: periodic writes keep the data disk awake.
EOF
}
