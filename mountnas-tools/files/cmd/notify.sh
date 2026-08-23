# shellcheck shell=sh
# nas notify
# Sourced by /usr/sbin/nas (never run directly). Shared helpers: lib.sh.

# nas notify — send through / inspect the notification sinks. The actual
# fan-out lives in ONE place (/usr/libexec/mountnas/notify — also called by
# data-watch, smartd-notify and the health digest); this command is the
# user-facing front: list what is configured, test it, or send ad-hoc
# messages from scripts and cron jobs.
cmd_notify() {
	case "${1:-}" in
	""|--list|status)
		sinks=$(/usr/libexec/mountnas/notify --list 2>/dev/null)
		hdr "notification sinks"
		if [ -n "$sinks" ]; then
			printf '%s\n' "$sinks" | sed 's/^/  /'
			hint "test them: nas notify --test"
		else
			echo "  (none configured)"
			hint "add sinks to /etc/mountnas/notify.conf — email, ntfy, webhook,"
			hint "slack, discord, gotify. Then: nas notify --test && nas commit"
		fi
		;;
	--test)
		sinks=$(/usr/libexec/mountnas/notify --list 2>/dev/null)
		[ -n "$sinks" ] || { bad "no sinks configured — edit /etc/mountnas/notify.conf first"; return 1; }
		step "Sending a test notification to $(printf '%s\n' "$sinks" | grep -c .) sink(s)..."
		if /usr/libexec/mountnas/notify "MountNAS test notification" \
			"This is a test from 'nas notify --test'. If you can read this, the sink works."; then
			ok "test notification sent to every sink"
		else
			bad "at least one sink failed — see /var/log/mountnas.log"
			return 1
		fi
		;;
	-*)
		usage "nas notify [--test | <subject> [body]]"; return 1
		;;
	*)
		nsub=$1; shift
		/usr/libexec/mountnas/notify "$nsub" "$*" \
			&& ok "notification sent" \
			|| { bad "at least one sink failed — see /var/log/mountnas.log"; return 1; }
		;;
	esac
}

# help page for 'nas notify --help' / 'nas help notify'
help_notify() {
	cat <<EOF
nas notify [--test | <subject> [body]]
  Notification sinks: with no arguments, list what is configured in
  /etc/mountnas/notify.conf (email, ntfy, webhook, slack, discord,
  gotify — one 'type:target' per line; alert-email still works too).
  Disk-loss alerts, SMART trouble and health digests fan out to ALL sinks.
  --test              send a test message to every sink
  <subject> [body]    send an ad-hoc message (cron/script friendly)
Examples:
  nas notify --test
  snapraid sync 2>&1 | nas notify "snapraid sync finished"
EOF
}
