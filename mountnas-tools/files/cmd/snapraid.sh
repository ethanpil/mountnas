# shellcheck shell=sh
# nas snapraid
# Sourced by /usr/sbin/nas (never run directly). Shared helpers: lib.sh.

# nas snapraid — the SnapRAID Daemon (snapraidd service: scheduler, REST API
# and web UI driving the SAME snapraid CLI). OFF by default; same opt-in +
# persistence-honesty pattern as nas web and nas ttyd.
#
# The daemon replaces the hand-written cron lines a SnapRAID user normally
# maintains: it schedules sync and scrub, watches SMART, spins disks down and
# sends notifications. MountNAS does not reimplement any of that — this
# command only turns the daemon on and off and tells you where it is.
#
# The port comes from net_port in /etc/snapraidd.conf, whose format is
# "[IP:]PORT[s]" — take the last colon-separated field and drop a trailing
# 's' (TLS marker) so a loopback-bound "127.0.0.1:7627" still yields 7627.
_snapraid_port() {
	local p
	p=$(sed -n 's/^[[:space:]]*net_port[[:space:]]*=[[:space:]]*//p' /etc/snapraidd.conf 2>/dev/null \
		| tail -n1 | tr -d '[:space:]')
	p=${p##*,}          # "a:1,b:2" -> last listener
	p=${p##*:}          # "127.0.0.1:7627" -> 7627
	p=${p%s}            # "7627s" (TLS) -> 7627
	case "$p" in ''|*[!0-9]*) p=7627 ;; esac
	printf '%s' "$p"
}
# Is the daemon reachable only on loopback? Then the LAN URL would be a lie.
_snapraid_loopback() {
	sed -n 's/^[[:space:]]*net_port[[:space:]]*=[[:space:]]*//p' /etc/snapraidd.conf 2>/dev/null \
		| tail -n1 | grep -qE '(^|[[:space:],])(127\.|\[?::1)'
}
_snapraid_unsaved() {
	lbu status 2>/dev/null | grep -qE '(runlevels/[a-z]*/snapraidd|etc/snapraidd\.conf|conf\.d/snapraidd)'
}
# Where to point a browser. Loopback-bound daemons get the loopback URL.
_snapraid_url() {
	if _snapraid_loopback; then printf 'http://127.0.0.1:%s/' "$(_snapraid_port)"
	else printf 'http://%s.local:%s/' "$(hostname)" "$(_snapraid_port)"; fi
}
cmd_snapraid() {
	local sport si
	sport=$(_snapraid_port)
	case "${1:-status}" in
	on)
		command -v snapraidd >/dev/null 2>&1 \
			|| { bad "snapraidd missing — run: apk add snapraid-daemon && nas commit"; return 1; }
		[ -f /etc/snapraidd.conf ] \
			|| { bad "/etc/snapraidd.conf missing — MountNAS seeds it; restore it first"; return 1; }
		if [ -n "${2:-}" ]; then
			case "$2" in *[!0-9]*) usage "nas snapraid [on [port] | off | status]"; return 1 ;; esac
			sport=$2
			# Rewrite ONLY the net_port line, keeping every comment and every
			# other setting — the same never-clobber contract the other conf
			# editors follow. A loopback bind is preserved: only the port
			# number changes, so 'on 8000' on a 127.0.0.1 daemon stays local.
			if grep -q '^[[:space:]]*net_port[[:space:]]*=' /etc/snapraidd.conf; then
				sed -i "s|^\([[:space:]]*net_port[[:space:]]*=[[:space:]]*\)\(.*:\)\?[0-9]*s\?[[:space:]]*$|\1\2$sport|" \
					/etc/snapraidd.conf || { bad "could not update /etc/snapraidd.conf"; return 1; }
			else
				printf 'net_port = %s\n' "$sport" >> /etc/snapraidd.conf
			fi
		fi
		# The array itself is optional: the daemon starts and its UI explains
		# that /etc/snapraid.conf is empty. Say so here rather than refuse —
		# turning the daemon on FIRST and configuring the array in its web UI
		# is a legitimate order of work.
		grep -qE '^[[:space:]]*(data|parity)[[:space:]]' /etc/snapraid.conf 2>/dev/null \
			|| hint "no array in /etc/snapraid.conf yet — the daemon will say so; add disks there or in its UI"
		rc-update -q add snapraidd default 2>/dev/null || true
		rc-service snapraidd restart >/dev/null 2>&1 \
			|| { bad "snapraidd failed to start — check: rc-service snapraidd status"; return 1; }
		# Same bind-probe rationale as cmd_web: a daemon that forks before it
		# binds reports success even when the port is taken.
		si=0
		until curl -fsS --max-time 2 "http://127.0.0.1:$sport/" >/dev/null 2>&1; do
			si=$((si + 1))
			[ "$si" -ge 6 ] && { warn "started, but nothing answers on port $sport — port already in use? check: rc-service snapraidd status"; break; }
			sleep 0.5
		done
		_ops_log snapraid "daemon enabled (port $sport)"
		ok "SnapRAID Daemon ON -> $(_snapraid_url)"
		if _snapraid_loopback; then
			hint "bound to loopback only — reach it over SSH or Tailscale, or set net_port in /etc/snapraidd.conf"
		else
			warn "the REST API is READ-WRITE and has NO password: anyone who can reach"
			warn "port $sport can start a sync or scrub and change settings. Restrict it with"
			warn "net_acl in /etc/snapraidd.conf on an untrusted LAN, then: nas commit"
		fi
		if _snapraid_unsaved; then
			warn "setting NOT saved — the daemon is OFF again after a reboot unless you run: nas commit"
		fi
		;;
	off)
		rc-service snapraidd stop >/dev/null 2>&1 || true
		rc-update -q del snapraidd default 2>/dev/null || true
		_ops_log snapraid "daemon disabled"
		ok "SnapRAID Daemon OFF"
		hint "your array and its parity are untouched — 'snapraid' on the command line still works"
		if _snapraid_unsaved; then
			warn "setting NOT saved — the daemon comes BACK at reboot unless you run: nas commit"
		fi
		;;
	status)
		if rc-service snapraidd status >/dev/null 2>&1; then
			ok "SnapRAID Daemon running -> $(_snapraid_url)"
			if _snapraid_unsaved; then
				warn "running now but NOT saved — off after a reboot unless: nas commit"
			fi
			hint "disable: nas snapraid off"
		elif rc-update show default 2>/dev/null | grep -q snapraidd; then
			warn "SnapRAID Daemon enabled but not running — try: rc-service snapraidd start"
		else
			if _snapraid_unsaved; then
				warn "off now but NOT saved — comes back at reboot unless: nas commit"
			fi
			hint "SnapRAID Daemon off (enable: nas snapraid on [port] — default port 7627)"
		fi
		;;
	*) usage "nas snapraid [on [port] | off | status]"; return 1 ;;
	esac
}

# help page for 'nas snapraid --help' / 'nas help snapraid'
help_snapraid() {
	cat <<EOF
nas snapraid [on [port] | off | status]
  The SnapRAID Daemon: scheduled sync and scrub, SMART monitoring, disk
  spindown and notifications, with a REST API and a web UI. It drives the
  SAME snapraid binary, so your array, parity and recovery are unchanged —
  and 'snapraid' on the command line keeps working either way.
  on [port]   enable (default port 7627) and start it now
  off         stop + disable (the array is not touched)
  status      is it enabled/running/saved, and on which URL
  Configure it in /etc/snapraidd.conf or through its web UI. The daemon
  writes that file itself, so run 'nas commit' after changing settings.
  WARNING: the REST API is READ-WRITE and has NO password. On an untrusted
  network bind it to loopback (net_port = 127.0.0.1:7627) or restrict
  net_acl. Off by default.
  IMPORTANT: on/off lives in RAM until 'nas commit' (the command warns).
EOF
}
