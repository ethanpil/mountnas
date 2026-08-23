# shellcheck shell=sh
# lib.sh — shared state and helpers for every 'nas' command
# Sourced by /usr/sbin/nas before the cmd/*.sh files. No side effects
# beyond reading the version files and choosing colors.

DATA=/mnt/nasdata
CFG=/cfg
STATE=/run/mountnas
BOOTMNT=/media/mnasboot
WBCFG=/usr/libexec/mountnas/write-bootcfg
REPO=ethanpil/mountnas   # canonical GitHub repo ('nas upgrade --check' + docs)
VERSION=$(cat /usr/share/mountnas/version 2>/dev/null || echo "?")
# RELEASE = the tag users know (alpha-7, ...) — what we display and compare
# against GitHub. VERSION stays the apk pkgver (build id; CI reads that file).
# The fallback logic lives in ONE place: /usr/libexec/mountnas/release-string.
RELEASE=$(/usr/libexec/mountnas/release-string 2>/dev/null)
[ -n "$RELEASE" ] && [ "$RELEASE" != "?" ] || RELEASE="$VERSION"
# Color the status tags when stdout is a terminal (NO_COLOR honored, TERM=dumb
# excluded); pipes and logs get plain text. The literal [ OK ]/[WARN]/[FAIL]
# words stay intact inside the escapes, so grep/CI match colored output too.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then
	C_OK="$(printf '\033[32m')"; C_WA="$(printf '\033[33m')"; C_FA="$(printf '\033[1;31m')"; C_NO="$(printf '\033[0m')"
	C_HD="$(printf '\033[1;36m')"; C_B="$(printf '\033[1m')"; C_D="$(printf '\033[2m')"
else
	C_OK=""; C_WA=""; C_FA=""; C_NO=""; C_HD=""; C_B=""; C_D=""
fi
# Structured check records: when NAS_CHECKS names a file, every ok/warn/bad
# also appends "TYPE<TAB>message" to it. cmd_status uses the records for its
# exit code and cmd_status_json renders JSON from them — the human text is
# presentation only, so its format is free to change. The checks run in pipe
# subshells, so a file append (not a shell variable) is what survives.
_rec() {
	local _oifs
	[ -n "${NAS_CHECKS:-}" ] || return 0
	# join all args with tabs ("$*" joins on the first char of IFS)
	{ _oifs=$IFS; IFS=$(printf '\t'); printf '%s\n' "$*" >> "$NAS_CHECKS"; IFS=$_oifs; } 2>/dev/null
	return 0
}
ok()  { printf '  %s[ OK ]%s %s\n' "$C_OK" "$C_NO" "$*"; _rec OK "$*"; }
warn(){ printf '  %s[WARN]%s %s\n' "$C_WA" "$C_NO" "$*"; _rec WARN "$*"; }
bad() { printf '  %s[FAIL]%s %s\n' "$C_FA" "$C_NO" "$*"; _rec FAIL "$*"; }
confirm() { printf '%s [y/N] ' "$1"; read -r a; [ "$a" = y ] || [ "$a" = Y ]; }
# ---------- shared UI kit (presentation only — never writes check records) ----
# One visual grammar for every screen, ASCII-only so serial consoles render it:
#   hdr   level-1 section header  '== title ====…'  filled to column 68
#   sub   level-2 item rule       '-- text ------…' filled to column 68
#   hint  dim guidance/next-step line (commands in hints stay copy-pasteable)
#   usage uniform usage error on stderr (callers add their own return/exit)
# Titles must stay ASCII: ${#} counts bytes, so UTF-8 would shorten the fill.
# Screen width lives in ONE place; rules are cut to length from these
# precomputed 'UI_W'-wide strings with printf %.*s (no per-call forks).
UI_W=68
_RULE_EQ=$(printf '%*s' "$UI_W" '' | tr ' ' '=')
_RULE_DA=$(printf '%*s' "$UI_W" '' | tr ' ' '-')
hdr() {
	local p
	p=$((UI_W - 4 - ${#1})); [ "$p" -gt 0 ] || p=2
	printf '\n%s== %s %.*s%s\n' "$C_HD" "$1" "$p" "$_RULE_EQ" "$C_NO"
}
sub() {
	local p
	p=$((UI_W - 4 - ${#1})); [ "$p" -gt 0 ] || p=2
	printf -- '\n-- %s%s%s %.*s\n' "$C_B" "$1" "$C_NO" "$p" "$_RULE_DA"
}
hint() { printf '  %s%s%s\n' "$C_D" "$*" "$C_NO"; }
step() { printf '%s%s%s\n' "$C_B" "$*" "$C_NO"; }
usage() { printf 'usage: %s\n' "$*" >&2; return 1; }
# seconds -> "3d 4h" / "4h 12m" / "12m" / "45s" (status header)
_uptime_h() {
	local s
	s=${1:-0}; case "$s" in ''|*[!0-9]*) s=0 ;; esac
	if [ "$s" -ge 86400 ]; then printf '%dd %dh' "$((s / 86400))" "$((s % 86400 / 3600))"
	elif [ "$s" -ge 3600 ]; then printf '%dh %dm' "$((s / 3600))" "$((s % 3600 / 60))"
	elif [ "$s" -ge 60 ]; then printf '%dm' "$((s / 60))"
	else printf '%ds' "$s"; fi
}
# True if $1 is covered by the read-only 'mountnas-blocked' placeholder that the
# mountnas service mounts over failed data mounts — mountpoint -q alone reports
# that placeholder as a healthy mount.
_blocked() { awk -v m="$1" '$1=="mountnas-blocked" && $2==m{f=1} END{exit !f}' /proc/mounts; }
# Disk-state of the filesystem a share/export path lands on: walk up to the
# nearest mountpoint, then classify. Echoes "ok" (a real disk mount), "blocked"
# (the ro placeholder over a failed disk), or "ram" (nothing mounted — lands on
# the RAM root). The walk always ends at a mountpoint ("/" and the placeholder
# are both mountpoints), so only a non-root, non-placeholder mount is a disk.
_path_on_disk() {
	local td=$1
	while [ "$td" != "/" ] && ! mountpoint -q "$td"; do td=$(dirname "$td"); done
	if _blocked "$td"; then echo blocked
	elif [ "$td" != "/" ] && mountpoint -q "$td"; then echo ok
	else echo ram; fi
}
# Parent disk of the BOOT partition (= the MountNAS boot USB); "" if absent.
# THE single copy: cmd_status, cmd_disks, cmd_disks_json and cmd_backup all
# rely on it, and boot-stick detection must never diverge between them.
_boot_usb_disk() {
	lsblk -no pkname "$(findfs LABEL=BOOT 2>/dev/null)" 2>/dev/null | head -n1
}
# Real disks only. lsblk types zram/ram devices as "disk" too, and every
# MountNAS box runs a zram swap device — without this filter it shows up as a
# phantom drive in the inventories and collects pointless smartctl/hdparm
# probes. THE single copy for the shell loops; the jq paths (cmd_disks,
# cmd_disks_json) carry the same name pattern inline.
_phys_disks() {
	lsblk -dno NAME,TYPE 2>/dev/null \
		| awk '$2=="disk" && $1 !~ /^(fd|sr|loop|ram|zram)/{print $1}'
}
# ---------- append-only operations log (nas history) ----------
# One line per destructive/notable operation, written DIRECTLY to /cfg (the
# ext4 config partition) — NOT the RAM overlay, so it persists immediately
# with no 'nas commit': an audit trail you had to remember to save would lose
# the record of exactly the operation that mattered (or of the crash before
# the commit). Lives on the boot stick, so the stick tells the whole story
# even when the data disks are gone. Volume is a handful of entries a year;
# a self-trim bounds the file with no logrotate dependency.
# Record: UTCts<TAB>op<TAB>actor<TAB>details   (greppable; nas history renders it)
OPSLOG=/cfg/mountnas-ops.log
_ops_actor() {
	local u t
	u=${DOAS_USER:-$(id -un 2>/dev/null || echo root)}
	if [ -n "${SSH_CONNECTION:-}" ]; then
		printf '%s@ssh:%s' "$u" "${SSH_CONNECTION%% *}"
	else
		t=$(tty 2>/dev/null)
		case "$t" in /dev/*) printf '%s@%s' "$u" "${t#/dev/}" ;; *) printf '%s@-' "$u" ;; esac
	fi
}
_ops_log() {
	local op
	op=$1; shift
	# best-effort by contract: never fail (or slow) the caller — skip silently
	# when /cfg is absent or momentarily read-only (e.g. during nas backup)
	mountpoint -q "$CFG" 2>/dev/null || return 0
	printf '%s\t%s\t%s\t%s\n' \
		"$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$op" "$(_ops_actor)" "$*" \
		>> "$OPSLOG" 2>/dev/null || return 0
	if [ "$(wc -l < "$OPSLOG" 2>/dev/null)" -gt 1200 ] 2>/dev/null; then
		tail -n 1000 "$OPSLOG" > "$OPSLOG.new" 2>/dev/null \
			&& mv "$OPSLOG.new" "$OPSLOG" 2>/dev/null || rm -f "$OPSLOG.new" 2>/dev/null
	fi
	return 0
}
# Refresh the prompt's unsaved-count cache. Called after every command so the
# PS1 indicator stays current without ever running lbu from the prompt itself.
# Commands that already counted changes write the cache themselves and set
# UNSAVED_FRESH so lbu doesn't run a second time.
_refresh_unsaved() {
	[ "${UNSAVED_FRESH:-0}" = 1 ] && return 0
	mkdir -p "$STATE"; lbu status 2>/dev/null | grep -c . > "$STATE/unsaved" 2>/dev/null || true
}

# THE single reader of the DATA_SERVICES override (callers: cmd_status,
# cmd_restart — the supervisor gets its own copy via OpenRC's conf.d
# sourcing). Reads in a subshell so a user's conf.d can never contaminate
# ours, and prefixes the value with a sentinel byte so we can tell an
# EXPLICITLY EMPTY list ("run no data services") apart from a conf.d whose
# sourcing died (a stray exit, a set -u typo, a missing file) — the latter
# must fail SAFE to the built-in set rather than silently drop every data
# service from the checks. '-' not ':-' so an empty list stays empty.
_data_services() {
	local _ds
	_ds=$(unset DATA_SERVICES; . /etc/conf.d/mountnas 2>/dev/null || :; printf '=%s' "${DATA_SERVICES-docker samba nfs}")
	case "$_ds" in
		=*) printf '%s' "${_ds#=}" ;;
		*)  printf '%s' "docker samba nfs" ;;
	esac
}

# ---------- helpers shared by more than one command ----------

# Disk temperature WITHOUT waking sleeping drives: hdparm -C reports the power
# state without spinning up — a drive in standby shows "standby" instead of a
# reading. Temps come from hwmon: the drivetemp module (loaded via /etc/modules)
# covers SATA; NVMe registers its own sensor. "-" when no sensor exists (VMs,
# USB bridges without SAT).
_disk_temp() {
	local f t
	case "$(hdparm -C "/dev/$1" 2>/dev/null)" in
		*standby*|*sleeping*) echo standby; return 0 ;;
	esac
	t=$(cat "/sys/block/$1/device/hwmon/hwmon"*/temp1_input 2>/dev/null | head -n1)
	if [ -z "$t" ]; then
		# fallback: sensor may sit deeper (e.g. NVMe controller); sysfs paths
		# never contain whitespace, so head+cat is safe
		f=$(find "/sys/block/$1/device/" -maxdepth 4 -name temp1_input 2>/dev/null | head -n1)
		[ -n "$f" ] && t=$(cat "$f" 2>/dev/null)
	fi
	# optional leading minus: hwmon reports millidegrees and sub-zero readings
	# are legitimate (cold ambient, sensor offsets) — a signed value beats
	# pretending the sensor does not exist
	case "${t#-}" in
		''|*[!0-9]*) echo "-" ;;
		*) echo "$((t / 1000))C" ;;
	esac
}

# Current persistent-syslog target from SYSLOGD_OPTS (-O path); "" when
# syslog still writes to RAM. Read by cmd_logs and cmd_status.
_syslog_target() {
	awk -F'"' '/^SYSLOGD_OPTS=/{print $2}' /etc/conf.d/syslog 2>/dev/null \
		| sed -n 's/.*-O *\([^ ]*\).*/\1/p'
}

# Rewrite ONLY the persistence tokens (-O/-s/-b) inside SYSLOGD_OPTS,
# preserving every other user token (remote forwarding -R, mark intervals, …)
# and every other line of the file — this appliance is built on hand-edited
# config, so a toggle must never clobber someone's additions. $1 = tokens to
# append after stripping ("" removes persistence). Values pass through the
# environment (not awk -v) so backslashes are never escape-processed.
_syslog_set_persist() {
	local f cur cleaned tmpf
	f=/etc/conf.d/syslog
	[ -f "$f" ] || : > "$f"
	cur=$(sed -n 's/^SYSLOGD_OPTS="\(.*\)"[[:space:]]*$/\1/p' "$f" 2>/dev/null | head -n1)
	[ -n "$cur" ] || cur="-t"
	cleaned=$(printf '%s\n' "$cur" | awk '{o=""; for(i=1;i<=NF;i++){ if($i=="-O"||$i=="-s"||$i=="-b"){i++;continue} o=o (o==""?"":" ") $i } print o}')
	tmpf=$(mktemp) || return 1
	NV="$cleaned${1:+ $1}" awk 'BEGIN{done=0}
		/^SYSLOGD_OPTS=/{ printf "SYSLOGD_OPTS=\"%s\"\n", ENVIRON["NV"]; done=1; next }
		{print}
		END{ if(!done) printf "SYSLOGD_OPTS=\"%s\"\n", ENVIRON["NV"] }' "$f" > "$tmpf" || { rm -f "$tmpf"; return 1; }
	cat "$tmpf" > "$f" && rm -f "$tmpf"
}

# Rewrite ONLY the PORT= line of a conf.d file, preserving every other line —
# mountnas-web documents WEB_REFRESH_SEC= in the same file, and this appliance
# is built on hand-edited config, so setting a port must never clobber a
# user's additions (same never-clobber contract as _syslog_set_persist).
_conf_set_port() {   # $1=conf.d file  $2=port
	local f tmpf
	f=$1
	[ -f "$f" ] || : > "$f"
	tmpf=$(mktemp) || return 1
	NP="$2" awk 'BEGIN{done=0}
		/^PORT=/{ printf "PORT=%s\n", ENVIRON["NP"]; done=1; next }
		{print}
		END{ if(!done) printf "PORT=%s\n", ENVIRON["NP"] }' "$f" > "$tmpf" || { rm -f "$tmpf"; return 1; }
	cat "$tmpf" > "$f" && rm -f "$tmpf"
}

# Note for a snapshot file: looked up by the file's mtime stamp — the exact
# identity lbu uses when it rotates the active overlay into
# <host>.<mtime-stamp>.tar.gz, so a note attached at commit time follows the
# snapshot automatically. Notes live in /cfg/.mountnas-notes (TS<TAB>text).
_snap_note() {
	local sn_ts
	sn_ts=$(date -u -r "$1" +%Y%m%d%H%M%S 2>/dev/null) || return 0
	awk -F'\t' -v t="$sn_ts" '$1==t{print $2; exit}' "$CFG/.mountnas-notes" 2>/dev/null
}
