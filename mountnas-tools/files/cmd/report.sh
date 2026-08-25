# shellcheck shell=sh
# nas report
# Sourced by /usr/sbin/nas (never run directly). Shared helpers: lib.sh.

# nas report — diagnostics bundle for bug reports. Collects status, logs, and
# storage/service config into one tarball in /tmp (RAM). Deliberately EXCLUDES
# secrets: no /etc/shadow, no ssh keys, no samba password db. /var/log/messages
# is included because most bugs need it — the closing note tells the user to
# review before sharing.
cmd_report() {
	# rpt_-prefixed names on purpose: this function NESTS cmd_status --deep,
	# whose loops assign generic names (d, s, out, ...) — a plain 'd' here was
	# clobbered to the last disk name and the whole bundle wrote into a
	# directory literally called "sdd" (beta-1 test D).
	local rpt_d rpt_f f
	rpt_f="/tmp/mountnas-report-$(hostname)-$(date +%Y%m%d-%H%M%S).tar.gz"
	rpt_d=$(mktemp -d) || { bad "mktemp failed"; return 1; }
	step "Collecting diagnostics (runs 'nas status --deep' — may wake sleeping disks) ..."
	# Colors are decided once at startup from the script's own stdout, so a
	# report run from a terminal would embed ANSI escapes in the bundle. Blank
	# the palette inside a subshell so the captured file is plain text; the
	# parent's colors are untouched.
	( C_OK=""; C_WA=""; C_FA=""; C_NO=""; C_HD=""; C_B=""; C_D=""
	  cmd_status --deep ) > "$rpt_d/nas-status.txt" 2>&1 || true
	{ echo "MountNAS $RELEASE (build $VERSION)"; uname -a; uptime; } > "$rpt_d/system.txt" 2>&1 || true
	dmesg > "$rpt_d/dmesg.txt" 2>/dev/null || true
	cp /var/log/mountnas.log "$rpt_d/mountnas.log" 2>/dev/null || true
	cp /var/log/messages "$rpt_d/messages" 2>/dev/null || true
	cp /etc/fstab "$rpt_d/fstab" 2>/dev/null || true
	cp "$OPSLOG" "$rpt_d/ops-history.log" 2>/dev/null || true
	cat /proc/mounts > "$rpt_d/mounts.txt" 2>/dev/null || true
	lsblk -o NAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT > "$rpt_d/lsblk.txt" 2>/dev/null || true
	df -h > "$rpt_d/df.txt" 2>/dev/null || true
	cp /etc/apk/world "$rpt_d/world" 2>/dev/null || true
	rc-status -a > "$rpt_d/rc-status.txt" 2>/dev/null || true
	# swap state + its config: a RAM-root box that is thrashing looks identical
	# to a healthy one in every other file here
	cat /proc/swaps > "$rpt_d/swaps.txt" 2>/dev/null || true
	free -m > "$rpt_d/free.txt" 2>/dev/null || true
	for f in /etc/snapraid.conf /etc/mountnas/snapraid-maint.conf /mnt/nasdata/snapraid/state/last-run /etc/exports /etc/docker/daemon.json /etc/samba/smb.conf /etc/conf.d/zram-init /etc/conf.d/mountnas; do
		[ -f "$f" ] && cp "$f" "$rpt_d/$(basename "$f")" 2>/dev/null
	done
	if tar -czf "$rpt_f" -C "$rpt_d" .; then
		rm -rf "$rpt_d"
		ok "diagnostics bundle written: $rpt_f"
		hint "Attach it to your bug report: https://github.com/$REPO/issues"
		hint "No secrets are included (no shadow/ssh keys/samba passwords), but the"
		hint "system log is — review the contents before sharing."
	else
		rm -rf "$rpt_d"; bad "could not write $rpt_f"; return 1
	fi
}

# help page for 'nas report --help' / 'nas help report'
help_report() {
	cat <<EOF
nas report
  Secrets-free diagnostics bundle (status, logs, storage + service
  config) written to /tmp for attaching to bug reports.
EOF
}
