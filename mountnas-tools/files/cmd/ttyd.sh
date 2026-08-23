# shellcheck shell=sh
# nas ttyd
# Sourced by /usr/sbin/nas (never run directly). Shared helpers: lib.sh.

# nas ttyd — the browser terminal (mountnas-ttyd service: ttyd serving a
# REAL /bin/login prompt, never a bare shell). OFF by default; same opt-in +
# persistence-honesty pattern as nas web.
#
# Root login: busybox login consults /etc/securetty, which ships with no
# pts/* entries — so root would be silently refused on the web terminal.
# 'on' appends pts/0..15 (idempotent, maintainer decision). Scope is narrow:
# securetty only gates login(1), and only ttyd spawns login on a pty here —
# SSH has its own PermitRootLogin and the consoles are already listed.
_ttyd_unsaved() {
	lbu status 2>/dev/null | grep -qE '(runlevels/[a-z]*/mountnas-ttyd|conf\.d/mountnas-ttyd|securetty)'
}
cmd_ttyd() {
	local tport tp_i i
	tport=$(sed -n 's/^PORT=//p' /etc/conf.d/mountnas-ttyd 2>/dev/null | head -n1)
	# a hand-edited conf.d can hold garbage; never propagate it into URLs
	case "$tport" in ''|*[!0-9]*) tport=22222 ;; esac
	case "${1:-status}" in
	on)
		if [ -n "${2:-}" ]; then
			case "$2" in *[!0-9]*) usage "nas ttyd [on [port] | off | status]"; return 1 ;; esac
			tport=$2
			_conf_set_port /etc/conf.d/mountnas-ttyd "$tport" \
				|| { bad "could not update /etc/conf.d/mountnas-ttyd"; return 1; }
		fi
		command -v ttyd >/dev/null 2>&1 \
			|| { bad "ttyd missing — run: apk add ttyd && nas commit"; return 1; }
		# key on ANY pts line: if one exists the user manages the policy —
		# re-appending would duplicate; if none exist, add the block once
		if [ -f /etc/securetty ] && ! grep -q '^pts/' /etc/securetty; then
			{
				echo "# pts entries added by 'nas ttyd on' (root login on the web terminal)"
				i=0; while [ "$i" -le 15 ]; do echo "pts/$i"; i=$((i + 1)); done
			} >> /etc/securetty
			ok "root login enabled on web terminals (pts entries added to /etc/securetty)"
		fi
		rc-update -q add mountnas-ttyd default 2>/dev/null || true
		rc-service mountnas-ttyd restart >/dev/null 2>&1 \
			|| { bad "mountnas-ttyd failed to start — check: rc-service mountnas-ttyd status"; return 1; }
		# same bind-probe rationale as cmd_web: --background masks EADDRINUSE
		tp_i=0
		until curl -fsS --max-time 2 "http://127.0.0.1:$tport/" >/dev/null 2>&1; do
			tp_i=$((tp_i + 1))
			[ "$tp_i" -ge 6 ] && { warn "started, but nothing answers on port $tport — port already in use? check: rc-service mountnas-ttyd status"; break; }
			sleep 0.5
		done
		_ops_log ttyd "enabled (port $tport)"
		ok "browser terminal ON -> http://$(hostname).local:$tport/  (login prompt)"
		warn "plain HTTP on your LAN: the password transits in cleartext (trusted-LAN posture)"
		if _ttyd_unsaved; then
			warn "setting NOT saved — the terminal is OFF again after a reboot unless you run: nas commit"
		fi
		;;
	off)
		rc-service mountnas-ttyd stop >/dev/null 2>&1 || true
		rc-update -q del mountnas-ttyd default 2>/dev/null || true
		_ops_log ttyd "disabled"
		ok "browser terminal OFF"
		if _ttyd_unsaved; then
			warn "setting NOT saved — the terminal comes BACK at reboot unless you run: nas commit"
		fi
		;;
	status)
		if rc-service mountnas-ttyd status >/dev/null 2>&1; then
			ok "browser terminal running -> http://$(hostname).local:$tport/"
			if _ttyd_unsaved; then
				warn "running now but NOT saved — off after a reboot unless: nas commit"
			fi
			hint "disable: nas ttyd off"
		elif rc-update show default 2>/dev/null | grep -q mountnas-ttyd; then
			warn "browser terminal enabled but not running — try: rc-service mountnas-ttyd start"
		else
			if _ttyd_unsaved; then
				warn "off now but NOT saved — comes back at reboot unless: nas commit"
			fi
			hint "browser terminal off (enable: nas ttyd on [port] — default port 22222)"
		fi
		;;
	*) usage "nas ttyd [on [port] | off | status]"; return 1 ;;
	esac
}

# help page for 'nas ttyd --help' / 'nas help ttyd'
help_ttyd() {
	cat <<EOF
nas ttyd [on [port] | off | status]
  Browser-based terminal (ttyd) serving a REAL login prompt — never a
  bare shell. Off by default; plain HTTP on your trusted LAN (the
  password transits in cleartext, same trust model as Samba).
  on [port]   enable (default port 22222) and start it now
  off         stop + disable
  status      is it enabled/running/saved, and on which URL
  Root login works: 'on' adds pts entries to /etc/securetty once
  (busybox login refuses root on unlisted ttys otherwise).
  IMPORTANT: on/off lives in RAM until 'nas commit' (the command warns).
EOF
}
