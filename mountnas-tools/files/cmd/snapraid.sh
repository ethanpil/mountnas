# shellcheck shell=sh
# nas snapraid
# Sourced by /usr/sbin/nas (never run directly). Shared helpers: lib.sh.

# nas snapraid — gated SnapRAID maintenance (SPEC-snapraid-maint.md).
# The runner (/usr/libexec/mountnas/snapraid-maint) does the work; this
# command runs it, schedules it, and answers "what is my array and is it
# protected" at every stage of setup.
SRMAINT=/usr/libexec/mountnas/snapraid-maint
SRMAINT_CONF=/etc/mountnas/snapraid-maint.conf
SRMAINT_STATE=/mnt/nasdata/snapraid/state/last-run
SRMARK='# mountnas-snapraid'

# create-if-absent (the genapkovl seed reaches freshly flashed boxes only;
# an upgraded box needs a file to edit and lbu a file to track)
_snapraid_seed_conf() {
	[ -f "$SRMAINT_CONF" ] && return 0
	mkdir -p /etc/mountnas
	cat > "$SRMAINT_CONF" <<'EOF'
# snapraid-maint — you own this file (edit, then: nas commit).
DEL_THRESHOLD=100       # block sync above this many deleted files (0 = no gate)
UPD_THRESHOLD=200       # block sync above this many updated files (0 = no gate)
SCRUB_PERCENT=7         # scrub the oldest N% of blocks after a clean sync (0 = off)
SCRUB_OLDER_DAYS=10     # scrub only blocks not checked in N days
NOTIFY=problems         # problems | always | never
EOF
	ok "created $SRMAINT_CONF with the defaults"
}
_snapraid_configured() {
	grep -qE '^[[:space:]]*data[[:space:]]' /etc/snapraid.conf 2>/dev/null
}
_snapraid_cronline() { crontab -l 2>/dev/null | grep -F "$SRMARK"; }
_snapraid_unsaved() {
	lbu status 2>/dev/null | grep -qE '(cron/crontabs|etc/mountnas/snapraid-maint\.conf)'
}
# every array path with role/mount/size — from snapraid.conf, /proc/mounts
# and df only. CHEAP by contract: the table must never wake a disk, so no
# snapraid call on this path (that is what --deep is for).
_snapraid_disk_table() {
	awk '$1!~/^#/ {
		if ($1=="data") printf "%s\tdata\t%s\n", $2, $3
		else if ($1 ~ /^([2-6]-|z-)?parity$/) { n=split($2,a,","); for(i=1;i<=n;i++) printf "%s\tparity\t%s\n", $1, a[i] }
	}' /etc/snapraid.conf 2>/dev/null | while IFS="$(printf '\t')" read -r name role path; do
		d=$path; [ -d "$d" ] || d=$(dirname "$path")
		mnt=MISSING; sz="-"
		p=$d
		while [ "$p" != "/" ]; do
			if mountpoint -q "$p" 2>/dev/null; then mnt=mounted; break; fi
			p=$(dirname "$p")
		done
		[ "$mnt" = mounted ] && sz=$(df -h "$d" 2>/dev/null | awk 'NR==2{printf "%s/%s", $3, $2}')
		printf '         %-8s %-7s %-22s %-8s %s\n' "$name" "$role" "$path" "$mnt" "${sz:--}"
	done
}
_snapraid_mounted_counts() {   # -> "mounted total" on stdout
	_snapraid_disk_table | awk '{t++; if ($4=="mounted") m++} END{printf "%d %d", m+0, t+0}'
}

cmd_snapraid() {
	local sub hhmm line n_mount n_all v
	sub=${1:-status}
	case "$sub" in
	run)
		command -v snapraid >/dev/null 2>&1 || { bad "snapraid missing"; return 1; }
		_snapraid_configured || {
			bad "no array in /etc/snapraid.conf — 'nas disks' finds your disks; see the README's SnapRAID section"
			return 1; }
		_snapraid_seed_conf
		case "${2:-}" in
			'') ;;
			--force-sync) ;;
			*) usage "nas snapraid run [--force-sync]"; return 1 ;;
		esac
		# first sync runs for hours; a dropped SSH session SIGHUPs it
		# (harmless — sync is resumable — but a wasted night)
		if [ -t 1 ] && [ -z "${TMUX:-}" ]; then
			hint "tip: a first sync can run for hours — 'tmux' keeps it alive if SSH drops"
		fi
		if [ "${2:-}" = --force-sync ]; then
			warn "threshold gate DISABLED for this run"
			SNAPRAID_MAINT_FORCE=1 "$SRMAINT"
		else
			"$SRMAINT"
		fi ;;
	schedule)
		_snapraid_configured || {
			bad "no array in /etc/snapraid.conf — 'nas disks' finds your disks; see the README's SnapRAID section"
			return 1; }
		if [ "${2:-}" = off ]; then
			if [ -n "$(_snapraid_cronline)" ]; then
				crontab -l 2>/dev/null | grep -vF "$SRMARK" | crontab -
				_ops_log snapraid "schedule removed"
				ok "nightly maintenance unscheduled"
			else
				hint "nothing scheduled"
			fi
		else
			hhmm=${2:-02:00}
			case "$hhmm" in
				[0-9]:[0-5][0-9]|[0-1][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;;
				*) usage "nas snapraid schedule [HH:MM | off]"; return 1 ;;
			esac
			_snapraid_seed_conf
			# strip ONE leading zero per field ("00"->"0", "05"->"5"): plain
			# string surgery, because $((08)) is an octal error in busybox ash
			set -- "${hhmm%%:*}" "${hhmm#*:}"
			line="${2#0} ${1#0} * * * $SRMAINT $SRMARK"
			( crontab -l 2>/dev/null | grep -vF "$SRMARK"; printf '%s\n' "$line" ) | crontab -
			_ops_log snapraid "scheduled nightly at $hhmm"
			ok "nightly sync + scrub scheduled at $hhmm"
			# the docs told users to hand-write snapraid cron lines for
			# years; a leftover one would run parity twice, once ungated
			if crontab -l 2>/dev/null | grep -vF "$SRMARK" | grep -q snapraid; then
				warn "your crontab has ANOTHER snapraid line — remove it (crontab -e) or parity runs twice nightly"
			fi
			rc-service crond status >/dev/null 2>&1 \
				|| warn "crond is NOT running — the schedule never fires (rc-service crond start)"
		fi
		if _snapraid_unsaved; then
			warn "not saved — the schedule is gone after a reboot unless you run: nas commit"
		fi ;;
	status)
		case "${2:-}" in ''|--deep) ;; *) usage "nas snapraid status [--deep]"; return 1 ;; esac
		if ! _snapraid_configured; then
			hint "SnapRAID not configured (no data disks in /etc/snapraid.conf)"
			hint "  1) nas disks                    find disks + paste-ready fstab lines"
			hint "  2) edit /etc/snapraid.conf      the commented template shows the format"
			hint "  3) nas snapraid run             first sync (then: nas snapraid schedule)"
			return 0
		fi
		ok "array configured   (/etc/snapraid.conf: $(_snapraid_disk_table | awk '$2=="data"{d++} $2=="parity"{p++} END{printf "%d data, %d parity", d+0, p+0}'))"
		_snapraid_disk_table
		n_mount=$(_snapraid_mounted_counts); n_all=${n_mount#* }; n_mount=${n_mount%% *}
		if [ "$n_mount" = "$n_all" ]; then ok "disks mounted      ($n_mount/$n_all)"
		else bad "disks mounted      ($n_mount/$n_all — syncing now would treat missing disks as EMPTY)"; fi
		line=$(_snapraid_cronline)
		if [ -n "$line" ]; then
			if _snapraid_unsaved; then
				warn "scheduled ($(printf '%s' "$line" | awk '{printf "%02d:%02d", $2, $1}')) but NOT saved — gone after a reboot unless: nas commit"
			else
				ok "scheduled          ($(printf '%s' "$line" | awk '{printf "%02d:%02d", $2, $1}') nightly — saved)"
			fi
		else
			hint "not scheduled (nas snapraid schedule — nightly gated sync + scrub)"
		fi
		if [ -f "$SRMAINT_STATE" ]; then
			v=$(sed -n 's/^verdict=//p' "$SRMAINT_STATE")
			case "$v" in
				SYNCED|NOTHING) ok "last run           $(sed -n 's/^date=//p' "$SRMAINT_STATE") $v (+$(sed -n 's/^added=//p' "$SRMAINT_STATE") -$(sed -n 's/^deleted=//p' "$SRMAINT_STATE") ~$(sed -n 's/^updated=//p' "$SRMAINT_STATE"), scrub: $(sed -n 's/^scrubbed=//p' "$SRMAINT_STATE"))" ;;
				BLOCKED) warn "last run           $(sed -n 's/^date=//p' "$SRMAINT_STATE") BLOCKED by the threshold gate — parity untouched"
					hint "intentional change? nas snapraid run --force-sync" ;;
				*) bad "last run           $(sed -n 's/^date=//p' "$SRMAINT_STATE") $v" ;;
			esac
			hint "full log: $(sed -n 's/^log=//p' "$SRMAINT_STATE")"
		else
			hint "no maintenance run recorded yet (nas snapraid run)"
		fi
		if [ "${2:-}" = --deep ]; then
			hdr "snapraid's own view (reads content files — slow, wakes disks)"
			snapraid status 2>&1 | sed 's/^/  /'
			if [ -f "$SRMAINT_STATE" ]; then
				hdr "last run log tail"
				tail -n 15 "$(sed -n 's/^log=//p' "$SRMAINT_STATE")" 2>/dev/null | sed 's/^/  /'
			fi
		fi ;;
	*) usage "nas snapraid [run [--force-sync] | schedule [HH:MM|off] | status [--deep]]"; return 1 ;;
	esac
}

# help page for 'nas snapraid --help' / 'nas help snapraid'
help_snapraid() {
	cat <<EOF
nas snapraid [run [--force-sync] | schedule [HH:MM|off] | status [--deep]]
  Gated SnapRAID maintenance. A bare cron 'snapraid sync' would write a
  mass deletion (ransomware, a fat-fingered rm) INTO parity; this refuses
  to sync past the thresholds, refuses to run with a disk unmounted, and
  scrubs a slice of old blocks after each clean sync.
  run           sync + scrub now. --force-sync skips the threshold gate
                for one run (every other protection still applies).
  schedule      write the nightly cron line (default 02:00); 'off' removes
                it. Saved by 'nas commit' like every /etc change.
  status        the array per disk (role, mounted, used), the schedule and
                the last run's verdict. --deep adds snapraid's own
                statistics and scrub ages (slow; wakes spun-down disks).
  Thresholds and scrub settings: /etc/mountnas/snapraid-maint.conf.
  Run history: /mnt/nasdata/snapraid/logs. Alerts go through 'nas notify'
  sinks (/etc/mountnas/notify.conf) when a sync is blocked or fails.
EOF
}
