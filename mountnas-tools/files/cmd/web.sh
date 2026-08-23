# shellcheck shell=sh
# nas web
# Sourced by /usr/sbin/nas (never run directly). Shared helpers: lib.sh.

# nas web — the read-only LAN status dashboard + built-in user guide
# (mountnas-web service: busybox httpd serving a tmpfs webroot that
# gen-webstatus re-renders every ~2 min; static files only, no request-time
# code, httpd dropped to nobody). OFF by default; this is the opt-in switch.
#
# The on/off state is /etc config (a runlevel symlink + the conf.d port
# file), so like EVERYTHING under /etc it lives in RAM until 'nas commit' —
# same honesty pattern as 'nas logs --persist': say loudly when the current
# setting would not survive a reboot, because a dashboard that silently
# vanishes (or resurrects) at the next boot looks like a bug.
_web_unsaved() {
	lbu status 2>/dev/null | grep -qE '(runlevels/[a-z]*/mountnas-web|conf\.d/mountnas-web)'
}
cmd_web() {
	local wport wp_i
	wport=$(sed -n 's/^PORT=//p' /etc/conf.d/mountnas-web 2>/dev/null | head -n1)
	# a hand-edited conf.d can hold garbage; never propagate it into URLs
	case "$wport" in ''|*[!0-9]*) wport=8080 ;; esac
	case "${1:-status}" in
	on)
		if [ -n "${2:-}" ]; then
			case "$2" in *[!0-9]*) usage "nas web [on [port] | off | status]"; return 1 ;; esac
			wport=$2
			_conf_set_port /etc/conf.d/mountnas-web "$wport" \
				|| { bad "could not update /etc/conf.d/mountnas-web"; return 1; }
		fi
		command -v httpd >/dev/null 2>&1 \
			|| { bad "busybox httpd missing — run: apk add busybox-extras && nas commit"; return 1; }
		rc-update -q add mountnas-web default 2>/dev/null || true
		rc-service mountnas-web restart >/dev/null 2>&1 \
			|| { bad "mountnas-web failed to start — check: rc-service mountnas-web status"; return 1; }
		# start-stop-daemon --background reports success once the process
		# forks — a failed bind (port already taken) dies AFTER that. Probe
		# the port so "ON" is never claimed over a dead listener.
		wp_i=0
		until curl -fsS --max-time 2 "http://127.0.0.1:$wport/" >/dev/null 2>&1; do
			wp_i=$((wp_i + 1))
			[ "$wp_i" -ge 6 ] && { warn "started, but nothing answers on port $wport — port already in use? check: rc-service mountnas-web status"; break; }
			sleep 0.5
		done
		_ops_log web "enabled (port $wport)"
		ok "web dashboard ON -> http://$(hostname).local:$wport/  (read-only, plain HTTP, LAN)"
		hint "built-in user guide: http://$(hostname).local:$wport/guide.html"
		if _web_unsaved; then
			warn "setting NOT saved — the dashboard is OFF again after a reboot unless you run: nas commit"
		fi
		;;
	off)
		rc-service mountnas-web stop >/dev/null 2>&1 || true
		rc-update -q del mountnas-web default 2>/dev/null || true
		_ops_log web "disabled"
		ok "web dashboard OFF"
		if _web_unsaved; then
			warn "setting NOT saved — the dashboard comes BACK at reboot unless you run: nas commit"
		fi
		;;
	status)
		if rc-service mountnas-web status >/dev/null 2>&1; then
			ok "web dashboard running -> http://$(hostname).local:$wport/"
			if _web_unsaved; then
				warn "running now but NOT saved — off after a reboot unless: nas commit"
			fi
			hint "disable: nas web off"
		elif rc-update show default 2>/dev/null | grep -q mountnas-web; then
			warn "web dashboard enabled but not running — try: rc-service mountnas-web start"
		else
			if _web_unsaved; then
				warn "off now but NOT saved — comes back at reboot unless: nas commit"
			fi
			hint "web dashboard off (enable: nas web on [port] — default port 8080)"
		fi
		;;
	*) usage "nas web [on [port] | off | status]"; return 1 ;;
	esac
}

# help page for 'nas web --help' / 'nas help web'
help_web() {
	cat <<EOF
nas web [on [port] | off | status]
  Read-only LAN status dashboard + the built-in user guide, served by a
  tiny static-file server (busybox httpd as nobody). A background job
  re-renders the page every ~2 minutes into RAM — no request-time code,
  no disk writes, nothing to manage. Plain HTTP on your trusted LAN.
  on [port]   enable (default port 8080) and start it now
  off         stop + disable
  status      is it enabled/running/saved, and on which URL
  IMPORTANT: like every /etc setting, on/off lives in RAM until you run
  'nas commit' — uncommitted, the dashboard is gone (or back) after a
  reboot. The command warns whenever the current state is unsaved.
  Pages: / (dashboard incl. hardware, added packages and a collapsible
  syslog tail), /guide.html (user guide), /status.json (machine-readable).
EOF
}
