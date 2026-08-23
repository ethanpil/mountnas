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
SNAPRAIDD_CONF=/etc/snapraidd.conf
SNAPRAIDD_DEFAULT=/usr/share/snapraidd/snapraidd.conf.default

# The daemon's net_port is "[IP:]PORT[s]", and a comma-separated list may name
# several listeners. Read the WHOLE value once; every caller below derives
# from it, so the port, the loopback test and the rewrite can never disagree.
_snapraid_netport() {
	sed -n 's/^[[:space:]]*net_port[[:space:]]*=[[:space:]]*//p' "$SNAPRAIDD_CONF" 2>/dev/null \
		| tail -n1 | tr -d '[:space:]'
}
# The EFFECTIVE listener: the last entry, which is the one this command
# reports and rewrites. Empty when net_port is absent — and that is NOT the
# same as 7627, because the daemon then binds 127.0.0.1 only.
_snapraid_listener() { printf '%s' "$(_snapraid_netport)" | sed 's/.*,//'; }
_snapraid_port() {
	local p
	p=$(_snapraid_listener); p=${p##*:}; p=${p%s}
	case "$p" in ''|*[!0-9]*) p=7627 ;; esac
	printf '%s' "$p"
}
# Is the EFFECTIVE listener loopback? Judging the whole value instead would
# call a daemon "loopback only" whenever ANY listener is local — and then skip
# the no-password warning while a LAN port stays open. An ABSENT net_port is
# loopback too: that is the daemon's own documented default.
_snapraid_loopback() {
	local l
	l=$(_snapraid_listener)
	case "$l" in
		'') return 0 ;;
		127.*|::1*|\[::1\]*) return 0 ;;
		*) return 1 ;;
	esac
}
# Only the runlevel entry decides whether the daemon comes back after a
# reboot. The config is tracked separately: the daemon rewrites it itself
# from its web UI, so an uncommitted config must not be reported as "the
# service will be off after a reboot".
_snapraid_unsaved_svc() {
	lbu status 2>/dev/null | grep -qE 'runlevels/[a-z]*/snapraidd'
}
_snapraid_unsaved_conf() {
	lbu status 2>/dev/null | grep -qE 'etc/snapraidd\.conf'
}
_snapraid_url() {
	if _snapraid_loopback; then printf 'http://127.0.0.1:%s/' "$(_snapraid_port)"
	else printf 'http://%s.local:%s/' "$(hostname)" "$(_snapraid_port)"; fi
}
# Ensure a config exists: a box that UPGRADED into this package never saw the
# apkovl seed, so copy the packaged default once (the init script does the
# same at boot). Returns 1 only when neither exists.
_snapraid_seed_conf() {
	[ -f "$SNAPRAIDD_CONF" ] && return 0
	[ -f "$SNAPRAIDD_DEFAULT" ] || return 1
	cp "$SNAPRAIDD_DEFAULT" "$SNAPRAIDD_CONF" || return 1
	ok "seeded $SNAPRAIDD_CONF from the packaged default"
	return 0
}
cmd_snapraid() {
	local sport si host addr new
	case "${1:-status}" in
	on)
		command -v snapraidd >/dev/null 2>&1 \
			|| { bad "snapraidd missing — run: apk add snapraid-daemon && nas commit"; return 1; }
		_snapraid_seed_conf \
			|| { bad "no $SNAPRAIDD_CONF and no packaged default at $SNAPRAIDD_DEFAULT"; return 1; }
		if [ -n "${2:-}" ]; then
			# A port is 1-65535. Digits alone are not enough: 0 makes the
			# kernel pick a random port (the passwordless API then listens
			# somewhere nobody can find), and 99999 makes the daemon exit.
			case "$2" in *[!0-9]*) usage "nas snapraid [on [port] | off | status]"; return 1 ;; esac
			if [ "$2" -lt 1 ] || [ "$2" -gt 65535 ] 2>/dev/null; then
				bad "port must be 1-65535 (got $2)"; return 1
			fi
			sport=$2
			# Rewrite the WHOLE net_port line from its parsed parts, keeping
			# the address of the effective listener. Matching on the value's
			# shape (the old sed) silently did nothing for a comma-separated
			# list or a trailing comment, while the command still reported
			# success on the new port.
			addr=$(_snapraid_listener); addr=${addr%s}
			case "$addr" in
				*:*) new="${addr%:*}:$sport" ;;
				*)   new="$sport" ;;
			esac
			_conf_set_kv "$SNAPRAIDD_CONF" net_port "$new" " = " \
				|| { bad "could not update $SNAPRAIDD_CONF"; return 1; }
		fi
		sport=$(_snapraid_port)
		# The array itself is optional: the daemon starts and its UI explains
		# that /etc/snapraid.conf is empty. Say so here rather than refuse —
		# turning the daemon on FIRST and configuring the array in its web UI
		# is a legitimate order of work.
		grep -qE '^[[:space:]]*(data|parity)[[:space:]]' /etc/snapraid.conf 2>/dev/null \
			|| hint "no array in /etc/snapraid.conf yet — the daemon will say so; add disks there or in its UI"
		rc-update -q add snapraidd default 2>/dev/null || true
		rc-service snapraidd restart >/dev/null 2>&1 \
			|| { bad "snapraidd failed to start — check: rc-service snapraidd status"; return 1; }
		# Probe the address the daemon actually binds, not 127.0.0.1: a
		# daemon bound to one LAN address never answers on loopback, and a
		# net_acl that omits +127.0.0.1 denies the loopback probe. Either way
		# the old probe reported a healthy daemon as broken.
		if _snapraid_loopback; then host=127.0.0.1; else host=$(_snapraid_listener); host=${host%s}; host=${host%:*}; fi
		case "$host" in ''|"$sport") host=127.0.0.1 ;; esac
		si=0
		until curl -fsS --max-time 2 "http://$host:$sport/" >/dev/null 2>&1; do
			si=$((si + 1))
			[ "$si" -ge 6 ] && { warn "started, but nothing answers on http://$host:$sport/ — port in use, or net_acl denies this probe? check: rc-service snapraidd status"; break; }
			sleep 0.5
		done
		_ops_log snapraid "daemon enabled (port $sport)"
		ok "SnapRAID Daemon ON -> $(_snapraid_url)"
		if _snapraid_loopback; then
			hint "bound to loopback only — reach it over SSH or Tailscale, or set net_port in $SNAPRAIDD_CONF"
		else
			warn "the REST API is READ-WRITE and has NO password: anyone who can reach"
			warn "port $sport can start a sync or scrub and change settings. Restrict it with"
			warn "net_acl in $SNAPRAIDD_CONF on an untrusted LAN, then: nas commit"
		fi
		if _snapraid_unsaved_svc; then
			warn "setting NOT saved — the daemon is OFF again after a reboot unless you run: nas commit"
		elif _snapraid_unsaved_conf; then
			warn "settings in $SNAPRAIDD_CONF are NOT saved — they revert at the next reboot unless you run: nas commit"
		fi
		;;
	off)
		rc-service snapraidd stop >/dev/null 2>&1 || true
		rc-update -q del snapraidd default 2>/dev/null || true
		_ops_log snapraid "daemon disabled"
		ok "SnapRAID Daemon OFF"
		hint "your array and its parity are untouched — 'snapraid' on the command line still works"
		if _snapraid_unsaved_svc; then
			warn "setting NOT saved — the daemon comes BACK at reboot unless you run: nas commit"
		fi
		;;
	status)
		if rc-service snapraidd status >/dev/null 2>&1; then
			ok "SnapRAID Daemon running -> $(_snapraid_url)"
			_snapraid_schedule_hint
			if _snapraid_unsaved_svc; then
				warn "running now but NOT saved — off after a reboot unless: nas commit"
			elif _snapraid_unsaved_conf; then
				warn "settings NOT saved — they revert at the next reboot unless: nas commit"
			fi
			hint "disable: nas snapraid off"
		elif rc-update show default 2>/dev/null | grep -q snapraidd; then
			warn "SnapRAID Daemon enabled but not running — try: rc-service snapraidd start"
		else
			if _snapraid_unsaved_svc; then
				warn "off now but NOT saved — comes back at reboot unless: nas commit"
			fi
			hint "SnapRAID Daemon off (enable: nas snapraid on [port] — default port 7627)"
		fi
		;;
	*) usage "nas snapraid [on [port] | off | status]"; return 1 ;;
	esac
}
# A running daemon with no maintenance_schedule syncs NOTHING. That is the one
# way this feature silently fails to do its job, so say it out loud.
_snapraid_schedule_hint() {
	local sched
	sched=$(sed -n 's/^[[:space:]]*maintenance_schedule[[:space:]]*=[[:space:]]*//p' \
		"$SNAPRAIDD_CONF" 2>/dev/null | tail -n1)
	if [ -n "$sched" ]; then
		ok "maintenance schedule: $sched"
	else
		warn "no maintenance_schedule set — the daemon is running but syncs NOTHING."
		warn "Set one in $SNAPRAIDD_CONF (e.g. 'maintenance_schedule = 02:00'), then: nas commit"
	fi
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
  Settings live in /etc/snapraidd.conf; the full option reference is at
  /usr/share/snapraidd/snapraidd.conf.example. The daemon rewrites its own
  config from the web UI, so run 'nas commit' after changing settings.
  WARNING: the REST API is READ-WRITE and has NO password. On an untrusted
  network bind it to loopback (net_port = 127.0.0.1:7627) or restrict
  net_acl. Off by default.
  IMPORTANT: on/off lives in RAM until 'nas commit' (the command warns).
EOF
}
