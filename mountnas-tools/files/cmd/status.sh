# shellcheck shell=sh
# nas status [--deep|--json]
# Sourced by /usr/sbin/nas (never run directly). Shared helpers: lib.sh.

# nas status [--deep]
# Fast glance + storage-config validation (all read-only, no disk spin-up).
# --deep adds SMART, SnapRAID status and time-sync — those can wake sleeping disks
# and be slow, so they are opt-in.
cmd_status() {
	# cmd_status is nested by cmd_report and cmd_status_json (CONTEXT.md: nesting
	# functions must not leak generic names into their callers); scope the
	# presentation vars this pass added so they can't clobber a caller.
	local svc_up rlv rl_ok vc vok vwa vfa alto alto_n ds_on ds_off fwr swt swu deep _own_checks ip swp lbu_out n plt lbk bdays res nf mt spec mp opts dupu dupm busb pkmap bd pk dr maxd par ps src fv h d s p
	deep=0; [ "${1:-}" = "--deep" ] && deep=1
	# Health-probe friendly: any FAIL record flips the exit code to 1. The
	# records file may already be provided by cmd_status_json; otherwise
	# create a private one here (see _rec at the top).
	_own_checks=0
	if [ -z "${NAS_CHECKS:-}" ]; then
		NAS_CHECKS=$(mktemp 2>/dev/null) || NAS_CHECKS=""
		_own_checks=1
	fi

	printf '%sMountNAS %s  —  %s (%s.local)  —  up %s%s\n' \
		"$C_B" "$RELEASE" "$(hostname)" "$(hostname)" \
		"$(_uptime_h "$(cut -d. -f1 /proc/uptime)")" "$C_NO"
	ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | paste -sd' ')
	# swap is part of the memory picture on a RAM-root box (zram holds the cold
	# pages), so it belongs on the same line — omitted entirely when there is none
	swp=$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{if (t>0) printf "    Swap: %d/%d MB", (t-f)/1024, t/1024}' /proc/meminfo 2>/dev/null)
	echo "  IP: ${ip:-none}    RAM: $(free -m | awk '/Mem:/{print $3"/"$2" MB"}')${swp}"

	hdr "system"
	mountpoint -q "$CFG" && ok "config partition mounted ($CFG)" || bad "config partition NOT mounted — saves will be lost"
	case "$(cat $STATE/data 2>/dev/null)" in
		ok)           ok "data disk mounted ($DATA)" ;;
		fresh)        warn "no data disk configured — add to /etc/fstab, then nas commit" ;;
		disconnected) bad "data disk NOT FOUND — check power/cabling" ;;
		mountfail)    bad "data disk failed to mount — check filesystem" ;;
		netfs)        bad "data disk is a network filesystem — unsupported for $DATA, use a local disk" ;;
		*)            warn "data disk state unknown" ;;
	esac
	# quiet success, loud failure: running services share ONE ok line (the
	# per-service SVC records still feed --json); a stopped one stays its own
	# warn line so it can't hide in a wall of green.
	# Data services DISABLED via DATA_SERVICES= in /etc/conf.d/mountnas (the
	# supported way to turn off Docker/Samba/NFS — see the supervisor's header)
	# are skipped, not warned: a deliberate off must not read as a failure.
	ds_on=$(_data_services)
	ds_off=""
	for s in docker samba nfs; do
		case " $ds_on " in *" $s "*) ;; *) ds_off="$ds_off $s" ;; esac
	done
	svc_up=""
	for s in $ds_on sshd avahi-daemon smartd crond chronyd; do
		if rc-service "$s" status >/dev/null 2>&1; then
			svc_up="$svc_up $s"; _rec SVC "$s" true
		else
			warn "$s not running"; _rec SVC "$s" false
		fi
	done
	[ -n "$svc_up" ] && ok "services:$svc_up"
	[ -n "$ds_off" ] && hint "disabled by /etc/conf.d/mountnas:$ds_off (re-enable: edit DATA_SERVICES, nas restart)"
	# clock offset (chronyc tracking = local socket, cheap). Drift silently
	# breaks SnapRAID timestamps, TLS and log order, and until now only
	# --deep looked. Emitted only when chronyd ANSWERS: a stopped chronyd is
	# already a warning from the service loop above, and a box without
	# chrony must not grow a bogus warning.
	local coff cmag cdir
	if command -v chronyc >/dev/null 2>&1; then
		coff=$(chronyc tracking 2>/dev/null \
			| sed -n 's/^System time *: *\([0-9.]*\) seconds \(fast\|slow\).*/\1 \2/p')
		if [ -n "$coff" ]; then
			cmag=${coff% *}; cdir=${coff#* }
			if awk -v m="$cmag" 'BEGIN{exit !(m < 0.5)}'; then
				ok "clock synced ($(awk -v m="$cmag" 'BEGIN{printf "%.1f", m*1000}') ms $cdir)"
			else
				warn "clock offset ${cmag}s $cdir — SnapRAID timestamps and TLS suffer; check chronyd"
			fi
		fi
	fi
	lbu_out=$(lbu status 2>/dev/null)
	n=$(printf '%s' "$lbu_out" | grep -c .)
	[ "${n:-0}" -gt 0 ] && warn "$n unsaved change(s) — run nas commit" || ok "no unsaved changes"
	# config mirror age (the disaster copy _mirror_overlay writes to the
	# data disk). Gated on the supervisor's own data-disk verdict (the
	# file's idiom — see the docker check below) rather than a second
	# mountpoint probe; an absent disk already warned above. Age carries
	# NO threshold, here or on the dashboard: mirror age equals
	# last-commit age, and a month without commits is an idle box, not a
	# failure — the one real failure (commits skipping the mirror) is not
	# age-shaped.
	local cmir cage
	if [ "$(cat "$STATE/data" 2>/dev/null)" = ok ]; then
		if cmir=$(_mirror_newest); then
			cage=${cmir##* }
			ok "config mirror: newest $cage day(s) old ($(find "$DATA/config-backups" -maxdepth 1 -name '*.apkovl.tar.gz' 2>/dev/null | wc -l | tr -d ' ') kept)"
		else
			hint "no config mirror yet — the next 'nas commit' writes one to $DATA/config-backups"
		fi
	fi
	# snapraid maintenance verdict (state written by snapraid-maint on the
	# data disk; boxes that never ran it, or run raw 'snapraid sync' by hand,
	# simply have no line here — the dashboard's parity-age view still works)
	if [ -f /mnt/nasdata/snapraid/state/last-run ]; then
		srv=$(sed -n 's/^verdict=//p' /mnt/nasdata/snapraid/state/last-run)
		srd=$(sed -n 's/^date=//p' /mnt/nasdata/snapraid/state/last-run)
		case "$srv" in
			SYNCED|NOTHING) ok "snapraid maintenance: $srv ($srd)" ;;
			BLOCKED) warn "snapraid maintenance: sync BLOCKED ($srd) — see: nas snapraid status" ;;
			*) bad "snapraid maintenance: $srv ($srd) — see: nas snapraid status" ;;
		esac
	fi
	# reuse this count for the prompt cache instead of running lbu again on exit
	mkdir -p "$STATE"; printf '%s\n' "${n:-0}" > "$STATE/unsaved" 2>/dev/null || true; UNSAVED_FRESH=1
	# persistent logging (line shown only when enabled; the setting itself is
	# /etc config, so it survives reboots only once committed)
	plt=$(_syslog_target)
	if [ -n "$plt" ]; then
		if printf '%s' "$lbu_out" | grep -q "etc/conf.d/syslog"; then
			warn "persistent logging -> $plt (NOT committed — lost at reboot)"
		else
			ok "persistent logging -> $plt"
		fi
	fi
	# last-backup recency (persisted by nas backup: "<epoch> <YYYY-mm-dd HH:MM>")
	# The backup is the ONLY rollback net for 'nas upgrade', so a stale one is
	# a real (if quiet) risk — past 90 days the green ok flips to a warn.
	lbk=$(cat /etc/mountnas/last-backup 2>/dev/null || true)
	case "${lbk%% *}" in
		'') warn "no 'nas backup' recorded yet — see UPGRADE.md" ;;
		*[!0-9]*) ok "last backup: $lbk" ;;
		*)
			bdays=$(( ( $(date +%s) - ${lbk%% *} ) / 86400 ))
			if [ "$bdays" -gt 90 ]; then
				warn "last backup: ${lbk#* } ($bdays day(s) ago) — stale; refresh with: nas backup"
			else
				ok "last backup: ${lbk#* } ($bdays day(s) ago)"
			fi ;;
	esac
	# alerting (data-watch / smartd / upgrades): surface whether any notification
	# sink is wired and can actually send, so a misconfig is caught now — not
	# when a disk dies. The notify helper is the single source for the active
	# sink list (notify.conf + the legacy alert-email address).
	alto=$(/usr/libexec/mountnas/notify --list 2>/dev/null)
	if [ -n "$alto" ]; then
		alto_n=$(printf '%s\n' "$alto" | grep -c .)
		if printf '%s\n' "$alto" | grep -q '^email:' && ! command -v mail >/dev/null 2>&1; then
			warn "alerts: email sink set but 'mail' unavailable — configure msmtp"
		else
			ok "alerts -> $alto_n notification sink(s)  (test: nas notify --test)"
		fi
	else
		hint "alerts off (add sinks to /etc/mountnas/notify.conf — email/ntfy/webhook/...)"
	fi
	# swap (zram): shipped on, so a box with none has either turned it off
	# deliberately or lost the service — either way that is a hint, not a
	# warning, but it must be VISIBLE: without this a thrashing box and a
	# swapless one both reported nothing at all.
	swt=$(awk '/^SwapTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
	swu=$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{print int((t-f)/1024)}' /proc/meminfo 2>/dev/null)
	if [ "${swt:-0}" -gt 0 ] 2>/dev/null; then
		if grep -q zram /proc/swaps 2>/dev/null; then
			ok "swap: ${swu} MB used of ${swt} MB (compressed, in RAM)"
		else
			ok "swap: ${swu} MB used of ${swt} MB"
		fi
		_rec SWAP "$swt" "$swu"
	else
		hint "no swap active (zram off — enable: rc-update add zram-init boot, then nas commit)"
		_rec SWAP 0 0
	fi
	# firewall (ufw): shipped disabled — the box trusts its LAN, so "off" is a
	# dim hint, never a warning. Active is probed via the loaded ufw chains
	# (one iptables lookup — no python spawn on every status/monitoring poll).
	# The state worth catching loudly: ENABLED=yes in ufw.conf but no chains
	# loaded — the box believes it has a firewall and is silently wide open.
	if iptables -nL ufw-user-input >/dev/null 2>&1; then
		fwr=$(cat /etc/ufw/user.rules /etc/ufw/user6.rules 2>/dev/null | grep -c '^### tuple')
		ok "firewall (ufw) active — $fwr rule(s)"; _rec FW active
	elif [ "$(awk -F= '$1=="ENABLED"{print tolower($2)}' /etc/ufw/ufw.conf 2>/dev/null)" = yes ]; then
		warn "firewall enabled in config but NOT loaded — run: rc-service ufw restart"; _rec FW broken
	else
		hint "firewall (ufw) off — box is LAN-open (enable: ufw allow SSH; ufw enable; nas commit)"
		_rec FW off
	fi

	# JSON mode skips the sensors block: its data has no JSON representation,
	# and per-disk hdparm probes on every monitoring poll would be pure waste.
	if [ -z "${NAS_NO_SENSORS:-}" ]; then
		hdr "sensors"
		_status_sensors
	fi

	hdr "storage config (fstab)"
	# per data mount — the trio (resolves/nofail/mounted) compacts to ONE ok
	# line when everything passes; any problem re-expands to the original
	# per-check lines so the failing one stays loud
	awk '$1!~/^#/ && $2 ~ /^\/mnt\//{print $1" "$2" "$4}' /etc/fstab | while read -r spec mp opts; do
		res=ok
		case "$spec" in UUID=*|LABEL=*)
			findfs "$spec" >/dev/null 2>&1 || res=bad ;;
		esac
		nf=ok; echo "$opts" | grep -q nofail || nf=warn
		mt=ok
		if _blocked "$mp"; then mt=bad
		elif ! mountpoint -q "$mp"; then mt=warn; fi
		if [ "$res$nf$mt" = okokok ]; then
			case "$spec" in
				UUID=*|LABEL=*) ok "$mp: resolves, nofail, mounted" ;;
				*)              ok "$mp: nofail, mounted" ;;
			esac
			continue
		fi
		case "$spec" in UUID=*|LABEL=*)
			[ "$res" = ok ] && ok "$mp: $spec resolves" || bad "$mp: $spec NOT FOUND" ;;
		esac
		[ "$nf" = ok ] && ok "$mp: nofail present" || warn "$mp: missing nofail (a missing disk could hang boot)"
		case "$mt" in
			bad)  bad "$mp: BLOCKED (disk missing/failed — ro placeholder mounted)" ;;
			warn) warn "$mp: declared but not mounted" ;;
			*)    ok "$mp: mounted" ;;
		esac
	done
	# duplicates
	dupu=$(awk '$1~/^UUID=/ && $2!~/^#/{print $1}' /etc/fstab | sort | uniq -d)
	[ -n "$dupu" ] && bad "duplicate UUID in fstab: $dupu"
	dupm=$(awk '$1!~/^#/ && $2 ~ /^\/(cfg|mnt)/{print $2}' /etc/fstab | sort | uniq -d)
	[ -n "$dupm" ] && bad "duplicate mountpoint in fstab: $dupm"
	# The one unrecoverable user error: a DATA fstab entry that resolves to the
	# boot USB itself — formatting or mounting it destroys the running OS.
	# /cfg (LABEL=MNASCFG) legitimately lives on the stick; only /mnt/* entries
	# are checked.
	busb=$(_boot_usb_disk)
	if [ -n "$busb" ]; then
		# one lsblk dump for the whole loop: a per-line lsblk spawn added a
		# subprocess pair for every fstab entry on every status run
		pkmap=$(lsblk -rno NAME,PKNAME 2>/dev/null)
		awk '$1!~/^#/ && $2 ~ /^\/mnt\//{print $1}' /etc/fstab | while read -r spec; do
			bd=""
			case "$spec" in
				UUID=*|LABEL=*|PARTUUID=*) bd=$(findfs "$spec" 2>/dev/null) ;;
				/dev/*) bd=$spec ;;
			esac
			[ -n "$bd" ] || continue
			pk=$(printf '%s\n' "$pkmap" | awk -v d="${bd#/dev/}" '$1==d{print $2; exit}')
			[ -n "$pk" ] || pk=${bd#/dev/}
			[ "$pk" = "$busb" ] && bad "$spec resolves to the BOOT USB ($busb) — REMOVE it from fstab (mkfs/mount there destroys the OS)"
		done
	fi
	# docker data-root: config points under $DATA, but only OK once the disk is mounted
	dr=$(awk -F'"' '/data-root/{print $4}' /etc/docker/daemon.json 2>/dev/null)
	if [ -n "$dr" ]; then
		if [ "${dr#"$DATA"}" != "$dr" ]; then
			[ "$(cat $STATE/data 2>/dev/null)" = ok ] \
				&& ok "Docker data-root under $DATA" \
				|| warn "Docker data-root configured for $DATA (disk not mounted yet)"
		else bad "Docker data-root ($dr) NOT under $DATA"; fi
	fi
	# no data path tracked (lbu's real list is protected_paths.d/lbu.list;
	# '+path' entries are what a commit archives)
	grep -qE "^\+/?(mnt/nasdata|mnt/disk|mnt/parity)" /etc/apk/protected_paths.d/lbu.list 2>/dev/null \
		&& bad "a data path is in the lbu include list (commit would copy your disk!) — remove with: lbu exclude <path>" \
		|| ok "lbu include has no data paths"
	# share/export paths must land on a live disk mount, not the RAM root
	awk -F= '/^[[:space:]]*path[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2}' \
		/etc/samba/smb.conf /etc/samba/mountnas-shares.conf 2>/dev/null | while read -r p; do
		[ -z "$p" ] && continue
		case "$(_path_on_disk "$p")" in
			ok)      ok "samba path $p on a mounted fs" ;;
			blocked) bad "samba path $p is BLOCKED (disk missing/failed)" ;;
			*)       bad "samba path $p is on RAM (no disk mounted)" ;;
		esac
	done
	[ -f /etc/exports ] && awk '/^\//{print $1}' /etc/exports | while read -r p; do
		case "$(_path_on_disk "$p")" in
			ok)      ok "nfs export $p on a mounted fs" ;;
			blocked) bad "nfs export $p is BLOCKED (disk missing/failed)" ;;
			*)       bad "nfs export $p is on RAM (no disk mounted)" ;;
		esac
	done
	# snapraid parity sizing (best-effort)
	if grep -q '^data ' /etc/snapraid.conf 2>/dev/null; then
		maxd=$(awk '/^data /{print $3}' /etc/snapraid.conf | while read -r d; do df -k "$d" 2>/dev/null|awk 'NR==2{print $2}'; done | sort -n | tail -1)
		par=$(awk '/^parity /{print $2}' /etc/snapraid.conf | sed 's#/[^/]*$##')
		[ -n "$par" ] && { ps=$(df -k "$par" 2>/dev/null|awk 'NR==2{print $2}')
			[ -n "$ps" ] && [ -n "$maxd" ] && { [ "$ps" -ge "$maxd" ] && ok "SnapRAID parity >= largest data disk" || bad "SnapRAID parity SMALLER than largest data disk"; }; }
	fi
	# data services must NOT be in a runlevel — mountnas owns them. A user who runs
	# 'rc-update add docker default' would start Docker before the disk mounts.
	# Only the services the supervisor actually manages ($ds_on) are checked: a
	# service removed from DATA_SERVICES is no longer mountnas-owned, and running
	# it from a runlevel is the user's only remaining mechanism — that must not
	# read as a FAIL forever.
	# One rc-update dump; clean services share one ok line, offenders stay loud.
	rlv=$(rc-update show 2>/dev/null)
	rl_ok=""
	for s in $ds_on; do
		if printf '%s\n' "$rlv" | grep -qE "^\s*$s\b"; then
			bad "$s is in a runlevel — mountnas must own it. Remove: rc-update del $s default"
		else rl_ok="$rl_ok${rl_ok:+/}$s"; fi
	done
	[ -n "$rl_ok" ] && ok "$rl_ok not in a runlevel (managed by mountnas)"

	if [ "$deep" = 1 ]; then
		hdr "deep: hardware / runtime"
		df -h / 2>/dev/null | awk 'NR==2{print "  root (RAM) used: "$5}'
		# fstab syntax/option validation from util-linux — catches classes the
		# hand-rolled checks above don't (typo'd options, unknown fs types).
		# Deep-only on purpose: findmnt probes device superblocks to verify
		# fstypes, which can wake sleeping disks; the fast section never may.
		if command -v findmnt >/dev/null 2>&1; then
			fv=$(findmnt --verify --fstab 2>&1 | grep -E '\[[WE]\]' || true)
			if [ -n "$fv" ]; then
				warn "findmnt --verify flagged /etc/fstab:"
				printf '%s\n' "$fv" | sed 's/^[[:space:]]*/     /'
			else ok "fstab passes findmnt --verify"; fi
		fi
		for d in $(_phys_disks); do
			h=$(smartctl -H "/dev/$d" 2>/dev/null | awk -F: '/overall-health/{gsub(/ /,"",$2);print $2}')
			[ -n "$h" ] && { [ "$h" = PASSED ] && ok "/dev/$d SMART PASSED" || bad "/dev/$d SMART $h"; }
		done
		command -v snapraid >/dev/null 2>&1 && grep -q '^data ' /etc/snapraid.conf 2>/dev/null && \
			snapraid status 2>/dev/null | grep -iE 'days|sync|scrub' | sed 's/^/  /'
		chronyc tracking >/dev/null 2>&1 && ok "time sync active" || warn "time not synced"
	else
		hint "Tip: 'nas status --deep' adds SMART/SnapRAID/time-sync (may wake disks)"
	fi
	# exit 1 when any FAIL record fired — usable from cron/monitoring as a probe.
	# Human runs (_own_checks=1) also render a verdict footer from the records.
	# (CI checks a healthy box is free of the literal [FAIL] tag, not the word
	# "fail", so verdict/message wording is unconstrained.)
	if [ -n "$NAS_CHECKS" ]; then
		if [ "$_own_checks" = 1 ]; then
			# one read of the records: awk counts drive both the footer and the
			# exit code (vfa>0 is exactly what "^FAIL<TAB>" would have matched)
			vc=$(awk -F'\t' '{c[$1]++} END{printf "%d %d %d", c["OK"]+0, c["WARN"]+0, c["FAIL"]+0}' "$NAS_CHECKS" 2>/dev/null)
			[ -n "$vc" ] || vc="0 0 0"
			vok=${vc%% *}; vfa=${vc##* }
			vwa=${vc#* }; vwa=${vwa% *}
			src=0; [ "$vfa" -gt 0 ] && src=1
			printf '%s%.*s%s\n' "$C_D" "$UI_W" "$_RULE_DA" "$C_NO"
			if [ "$vfa" -gt 0 ]; then
				printf '  %s%s check(s) failed, %s warning(s) — details above%s\n' "$C_FA" "$vfa" "$vwa" "$C_NO"
			elif [ "$vwa" -gt 0 ]; then
				printf '  %s%s checks passed, %s warning(s)%s\n' "$C_WA" "$vok" "$vwa" "$C_NO"
			else
				printf '  %sall %s checks passed%s\n' "$C_OK" "$vok" "$C_NO"
			fi
			rm -f "$NAS_CHECKS"; NAS_CHECKS=""
		else
			# records supplied by cmd_status_json/cmd_report: no footer, just the
			# probe exit code
			src=0
			grep -q "^FAIL	" "$NAS_CHECKS" 2>/dev/null && src=1
		fi
	else
		# Fail CLOSED: without the records file we cannot know whether a FAIL
		# fired — and a full RAM root (the state most worth alarming on) is
		# exactly what makes mktemp fail. Exit 2 = "could not track checks",
		# nonzero so probes treat it as unhealthy instead of silently green.
		warn "check tracking unavailable (mktemp failed — RAM root full?) — exit code 2"
		src=2
	fi
	return "$src"
}

# nas status --json — machine-readable snapshot for monitoring integrations
# (Uptime Kuma, Homepage, Zabbix, cron). The checks emit structured records
# (see _rec) and the JSON is rendered from those — NOT by parsing the human
# text, so the display format is free to change without breaking consumers.
# Exit code matches the human mode: 1 when any check FAILed.
cmd_status_json() {
	local dp jrc lb un
	dp="${1:-}"
	NAS_CHECKS=$(mktemp) || { echo '{"error":"mktemp failed"}'; return 1; }
	NAS_NO_SENSORS=1
	cmd_status $dp > /dev/null 2>&1
	jrc=$?
	lb=$(awk 'NR==1{print $1}' /etc/mountnas/last-backup 2>/dev/null)
	case "$lb" in ''|*[!0-9]*) lb=null ;; esac
	un=$(cat "$STATE/unsaved" 2>/dev/null); case "$un" in ''|*[!0-9]*) un=0 ;; esac
	jq -Rn \
		--arg release "$RELEASE" --arg version "$VERSION" --arg hostname "$(hostname)" \
		--argjson uptime "$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)" \
		--arg ips "$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | paste -sd' ')" \
		--arg cfg "$(mountpoint -q "$CFG" && echo ok || echo fail)" \
		--arg data "$(cat "$STATE/data" 2>/dev/null || echo unknown)" \
		--argjson unsaved "$un" \
		--argjson last_backup_epoch "$lb" 		--arg snapraid_last_run "$(sed -n 's/^verdict=//p' /mnt/nasdata/snapraid/state/last-run 2>/dev/null)" \
		--argjson deep "$([ "$dp" = "--deep" ] && echo true || echo false)" \
		--argjson memory "$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2}
			END{printf "{\"total_kb\":%d,\"available_kb\":%d,\"swap_total_kb\":%d,\"swap_used_kb\":%d}", t+0, a+0, st+0, (st-sf)+0}' /proc/meminfo 2>/dev/null || echo '{}')" \
		--argjson failed "$([ "$jrc" -ne 0 ] && echo true || echo false)" \
	'[inputs | split("\t")] as $r |
	 def msgs(t): [$r[] | select(.[0]==t) | .[1]];
	 {release:$release, version:$version, hostname:$hostname, uptime_seconds:$uptime,
	  ips: ($ips|split(" ")|map(select(length>0))),
	  config_partition:$cfg, data_disk:$data,
	  services: [$r[] | select(.[0]=="SVC") | {name:.[1], running:(.[2]=="true")}],
	  firewall: (msgs("FW")[0] // "unknown"),
	  memory: $memory,
	  unsaved_changes:$unsaved, last_backup_epoch:$last_backup_epoch, deep:$deep,
	  snapraid_last_run: (if $snapraid_last_run == "" then null else $snapraid_last_run end),
	  healthy: ($failed|not),
	  checks: {ok: (msgs("OK")|length), warn: (msgs("WARN")|length), fail: (msgs("FAIL")|length)},
	  fail_lines: msgs("FAIL"), warn_lines: msgs("WARN"), ok_lines: msgs("OK")}' < "$NAS_CHECKS"
	rm -f "$NAS_CHECKS"; NAS_CHECKS=""
	return "$jrc"
}

# Compact sensors block for 'nas status': CPU package temp (max across the CPU
# hwmon chips), fan speeds, and per-disk temperatures via _disk_temp (which is
# standby-safe — it never wakes a sleeping drive). Pure /sys reads, instant.
# VMs expose no hwmon chips: say so quietly instead of printing nothing.
_status_sensors() {
	# local everything: this helper runs NESTED inside cmd_status, which is
	# itself nested by cmd_report/cmd_status_json — generic names leaking up
	# is exactly what broke nas report
	local cpu fans disks h hn t v r f d lbl out i
	cpu=""; fans=""
	for h in /sys/class/hwmon/hwmon*; do
		[ -f "$h/name" ] || continue
		hn=$(cat "$h/name" 2>/dev/null)
		case "$hn" in
			coretemp|k10temp|zenpower|cpu_thermal|soc_thermal|acpitz)
				for t in "$h"/temp*_input; do
					[ -f "$t" ] || continue
					v=$(cat "$t" 2>/dev/null)
					# allow negative millidegree readings (see _disk_temp)
					case "${v#-}" in ''|*[!0-9]*) continue ;; esac
					v=$((v / 1000))
					if [ -z "$cpu" ] || [ "$v" -gt "$cpu" ]; then cpu=$v; fi
				done ;;
		esac
		for f in "$h"/fan*_input; do
			[ -f "$f" ] || continue
			r=$(cat "$f" 2>/dev/null)
			case "$r" in ''|*[!0-9]*) continue ;; esac
			[ "$r" -gt 0 ] && fans="$fans ${r}rpm"
		done
	done
	disks=""
	for d in $(_phys_disks); do
		t=$(_disk_temp "$d")
		[ "$t" = "-" ] && continue
		disks="$disks $d:$t"
	done
	if [ -z "$cpu" ] && [ -z "$fans" ] && [ -z "$disks" ]; then
		echo "  (no hardware sensors exposed — typical inside a VM)"
		return 0
	fi
	if [ -n "$cpu" ] || [ -n "$fans" ]; then
		printf '  %s%s\n' "${cpu:+CPU: ${cpu}C   }" "${fans:+Fans:$fans}"
	fi
	# disk temps wrap at 5 per line so many-bay boxes stay narrow
	if [ -n "$disks" ]; then
		lbl="  Disks:"
		# shellcheck disable=SC2086  # word-splitting the "name:temp" tokens is the point
		set -- $disks
		while [ $# -gt 0 ]; do
			out="$lbl"; i=0
			while [ $# -gt 0 ] && [ "$i" -lt 5 ]; do out="$out $1"; shift; i=$((i+1)); done
			printf '%s\n' "$out"; lbl="        "
		done
	fi
}

# help page for 'nas status --help' / 'nas help status'
help_status() {
	cat <<EOF
nas status [--deep|--json]
  Health + storage-config check. Fast mode never wakes sleeping disks.
  Exit code: 0 = no [FAIL] lines, 1 = at least one (cron/monitor friendly).
  --deep   adds SMART, SnapRAID status, fstab verify, time-sync (may wake disks)
  --json   machine-readable snapshot (same checks, same exit code)
Examples:
  nas status --json | jq .healthy
  nas status || mail -s "NAS unhealthy" you@example.com < /dev/null
EOF
}
