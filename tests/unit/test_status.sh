#!/bin/sh
# nas status: the fstab/config checks, the exit code, and --json.
# Hardware and services are stubs; the check logic and the files are real.
. "$(dirname "$0")/harness.sh"

# Healthy baseline. Every case starts from this and breaks ONE thing.
baseline() {
	printf 'LABEL=MNASCFG  /cfg  ext4  rw,noatime,nofail  0 0\n' > /etc/fstab
	printf 'UUID=aaaa-0001  /mnt/nasdata  ext4  rw,noatime,nofail  0 2\n' >> /etc/fstab
	printf 'UUID=aaaa-0002  /mnt/disk1    xfs   rw,noatime,nofail  0 2\n' >> /etc/fstab
	echo ok > "$STATE/data"
	: > /etc/apk/protected_paths.d/lbu.list
	rm -f /etc/conf.d/mountnas /etc/mountnas/notify.conf /etc/mountnas/alert-email \
		/etc/ufw/ufw.conf /etc/exports /etc/snapraid.conf
	printf '%s %s\n' "$(date +%s)" "$(date '+%Y-%m-%d %H:%M')" > /etc/mountnas/last-backup
	mkdir -p /etc/docker /etc/samba
	printf '{ "data-root": "/mnt/nasdata/docker" }\n' > /etc/docker/daemon.json
	printf '[media]\n   path = /mnt/disk1/media\n' > /etc/samba/smb.conf
	# devices: sda1/sda2 are data disks, sdz is the boot USB
	stub findfs 'case "$1" in
		LABEL=BOOT) echo /dev/sdz1 ;;
		UUID=aaaa-0001) echo /dev/sda1 ;;
		UUID=aaaa-0002) echo /dev/sda2 ;;
		UUID=boot-0003) echo /dev/sdz3 ;;
		*) exit 1 ;; esac'
	stub lsblk 'case "$*" in
		*pkname*) echo sdz ;;
		*NAME,PKNAME*) printf "sda1 sda\nsda2 sda\nsdz1 sdz\nsdz3 sdz\n" ;;
		*NAME,TYPE*) echo "sda disk" ;;
		*) exit 0 ;; esac'
	stub mountpoint 'case "$2" in /|/cfg|/mnt/nasdata|/mnt/disk1) exit 0 ;; esac; exit 1'
	stub rc-service 'exit 0'
	stub rc-update ':'
	stub lbu ':'
	stub ip ':'
	stub free 'echo "Mem: 4000 1000 3000"'
	stub iptables 'exit 1'
	stub hdparm 'echo " drive state is:  standby"'
}

t "healthy box: exit 0, compact ok lines"
baseline; run_nas status
assert_rc 0
assert_match '\[ OK \] config partition mounted' "$OUT"
assert_match '\[ OK \] data disk mounted' "$OUT"
assert_match '\[ OK \] /mnt/nasdata: resolves, nofail, mounted' "$OUT"
assert_match '\[ OK \] /mnt/disk1: resolves, nofail, mounted' "$OUT"
assert_match '\[ OK \] samba path /mnt/disk1/media on a mounted fs' "$OUT"
assert_match '\[ OK \] docker/samba/nfs not in a runlevel' "$OUT"
assert_match 'all [0-9]+ checks passed' "$OUT"
assert_nomatch '\[FAIL\]' "$OUT"

t "missing nofail is a warning, not a failure"
baseline; sed -i 's/xfs   rw,noatime,nofail/xfs   rw,noatime/' /etc/fstab
run_nas status
assert_rc 0
assert_match '\[WARN\] /mnt/disk1: missing nofail' "$OUT"
assert_match 'checks passed, 1 warning' "$OUT"

t "a UUID that does not resolve fails"
baseline; sed -i 's/aaaa-0002/dead-beef/' /etc/fstab
run_nas status
assert_rc 1
assert_match '\[FAIL\] /mnt/disk1: UUID=dead-beef NOT FOUND' "$OUT"
assert_match '1 check\(s\) failed' "$OUT"

t "declared but unmounted is a warning (a share on it is a failure)"
baseline; stub mountpoint 'case "$2" in /|/cfg|/mnt/nasdata) exit 0 ;; esac; exit 1'
run_nas status
assert_rc 1
assert_match '\[WARN\] /mnt/disk1: declared but not mounted' "$OUT"
assert_match '\[FAIL\] samba path /mnt/disk1/media is on RAM' "$OUT"
printf '[media]
   path = /mnt/nasdata/media
' > /etc/samba/smb.conf
run_nas status
assert_rc 0
assert_match '\[WARN\] /mnt/disk1: declared but not mounted' "$OUT"

t "duplicate UUID and duplicate mountpoint fail"
baseline; printf 'UUID=aaaa-0002  /mnt/disk1  xfs  rw,nofail  0 2\n' >> /etc/fstab
run_nas status
assert_rc 1
assert_match '\[FAIL\] duplicate UUID in fstab: UUID=aaaa-0002' "$OUT"
assert_match '\[FAIL\] duplicate mountpoint in fstab: /mnt/disk1' "$OUT"

t "a data entry on the boot USB fails loudly"
baseline; printf 'UUID=boot-0003  /mnt/disk2  ext4  rw,nofail  0 2\n' >> /etc/fstab
run_nas status
assert_rc 1
assert_match '\[FAIL\] UUID=boot-0003 resolves to the BOOT USB \(sdz\)' "$OUT"

t "a data path in the lbu include list fails"
baseline; echo '+mnt/nasdata/appdata' > /etc/apk/protected_paths.d/lbu.list
run_nas status
assert_rc 1
assert_match '\[FAIL\] a data path is in the lbu include list' "$OUT"

t "a samba path on the RAM root fails"
baseline; printf '[x]\n   path = /srv/ram\n' > /etc/samba/smb.conf
run_nas status
assert_rc 1
assert_match '\[FAIL\] samba path /srv/ram is on RAM' "$OUT"

t "nfs export is checked like a share"
baseline; printf '/mnt/disk1/pub *(ro)\n' > /etc/exports
run_nas status
assert_rc 0
assert_match '\[ OK \] nfs export /mnt/disk1/pub on a mounted fs' "$OUT"

t "docker data-root outside /mnt/nasdata fails"
baseline; printf '{ "data-root": "/var/lib/docker" }\n' > /etc/docker/daemon.json
run_nas status
assert_rc 1
assert_match '\[FAIL\] Docker data-root \(/var/lib/docker\) NOT under /mnt/nasdata' "$OUT"

t "a data service in a runlevel fails"
baseline; stub rc-update 'echo "               docker | default"'
run_nas status
assert_rc 1
assert_match '\[FAIL\] docker is in a runlevel' "$OUT"
assert_match '\[ OK \] samba/nfs not in a runlevel' "$OUT"

t "a stopped service warns; one disabled in conf.d is a hint"
baseline; stub rc-service 'case "$1" in docker|samba) exit 1 ;; esac; exit 0'
run_nas status
assert_rc 0
assert_match '\[WARN\] docker not running' "$OUT"
assert_match '\[WARN\] samba not running' "$OUT"
printf 'DATA_SERVICES="nfs"\n' > /etc/conf.d/mountnas
run_nas status
assert_rc 0
assert_nomatch 'docker not running' "$OUT"
assert_match 'disabled by /etc/conf.d/mountnas: docker samba' "$OUT"
assert_match '\[ OK \] nfs not in a runlevel' "$OUT"

t "data disk states from the supervisor"
baseline; echo disconnected > "$STATE/data"; run_nas status
assert_rc 1; assert_match '\[FAIL\] data disk NOT FOUND' "$OUT"
echo fresh > "$STATE/data"; run_nas status
assert_rc 0; assert_match '\[WARN\] no data disk configured' "$OUT"
echo netfs > "$STATE/data"; run_nas status
assert_rc 1; assert_match 'network filesystem' "$OUT"

t "config partition not mounted fails"
baseline; stub mountpoint 'case "$2" in /|/mnt/nasdata|/mnt/disk1) exit 0 ;; esac; exit 1'
run_nas status
assert_rc 1
assert_match '\[FAIL\] config partition NOT mounted' "$OUT"

t "clock offset: synced is ok, drift warns, silent when chronyc is absent"
baseline
stub chronyc 'echo "System time     : 0.000012345 seconds fast of NTP time"'
run_nas status
assert_match '\[ OK \] clock synced \(0\.0 ms fast\)' "$OUT"
stub chronyc 'echo "System time     : 2.500000000 seconds slow of NTP time"'
run_nas status
assert_match '\[WARN\] clock offset 2\.500000000s slow' "$OUT"
rm -f "$STUBS/chronyc"
run_nas status
assert_nomatch 'clock' "$OUT" "no chronyc = no clock line at all"

t "unsaved changes and backup age"
baseline; stub lbu 'printf "M etc/fstab\nA etc/x\n"'
run_nas status
assert_match '\[WARN\] 2 unsaved change\(s\)' "$OUT"
rm -f /etc/mountnas/last-backup; run_nas status
assert_match "\[WARN\] no 'nas backup' recorded yet" "$OUT"
printf '%s 2020-01-01 00:00\n' "$(( $(date +%s) - 100 * 86400 ))" > /etc/mountnas/last-backup
run_nas status
assert_match '\[WARN\] last backup: 2020-01-01 00:00 \(100 day\(s\) ago\) — stale' "$OUT"

t "firewall: off is a hint, configured-but-unloaded is a warning"
baseline; run_nas status
assert_match 'firewall \(ufw\) off' "$OUT"
mkdir -p /etc/ufw; printf 'ENABLED=yes\n' > /etc/ufw/ufw.conf
run_nas status
assert_match '\[WARN\] firewall enabled in config but NOT loaded' "$OUT"
stub iptables 'exit 0'; mkdir -p /etc/ufw; printf '### tuple ### a\n### tuple ### b\n' > /etc/ufw/user.rules
run_nas status
assert_match '\[ OK \] firewall \(ufw\) active — 2 rule\(s\)' "$OUT"
rm -rf /etc/ufw

t "--json: valid, mirrors the checks and the exit code"
baseline; run_nas status --json
assert_rc 0
printf '%s' "$OUT" | jq -e . >/dev/null || fail "not JSON: $OUT"
assert_eq "true" "$(printf '%s' "$OUT" | jq -r .healthy)"
assert_eq "0" "$(printf '%s' "$OUT" | jq -r .checks.fail)"
assert_eq "unit-test" "$(printf '%s' "$OUT" | jq -r .release)"
assert_eq "ok" "$(printf '%s' "$OUT" | jq -r .data_disk)"
sed -i 's/aaaa-0002/dead-beef/' /etc/fstab
run_nas status --json
assert_rc 1
assert_eq "false" "$(printf '%s' "$OUT" | jq -r .healthy)"
assert_eq "1" "$(printf '%s' "$OUT" | jq -r .checks.fail)"
assert_nomatch '\[FAIL\]' "$OUT" "human text leaked into --json"

t "--json --deep and --deep --json are the same thing"
baseline; stub smartctl 'echo "SMART overall-health self-assessment test result: PASSED"'
stub chronyc 'exit 0'; stub findmnt ':'
run_nas status --deep --json; a=$OUT; ra=$RC
run_nas status --json --deep; b=$OUT
assert_eq 0 "$ra"
printf '%s' "$a" | jq -e . >/dev/null || fail "not JSON: $a"
# The two orders must agree AND --deep must actually arrive. Comparing the
# orders only with each other cannot tell a working parser from one that
# drops the flag in both — the regression this parser exists to prevent.
assert_eq true "$(printf '%s' "$a" | jq -r .deep)" "--deep reached the JSON"
assert_eq true "$(printf '%s' "$b" | jq -r .deep)" "--deep reached the JSON (reversed)"
run_nas status --json
assert_eq false "$(printf '%s' "$OUT" | jq -r .deep)" "plain --json is not deep"
assert_eq "$(printf '%s' "$a" | jq -S 'del(.uptime_seconds, .memory)')" "$(printf '%s' "$b" | jq -S 'del(.uptime_seconds, .memory)')"

finish
