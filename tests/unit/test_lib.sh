#!/bin/sh
# lib.sh helpers: pure functions and the file-editing helpers.
. "$(dirname "$0")/harness.sh"
src_nas

t "_uptime_h formats seconds"
assert_eq "3d 4h" "$(_uptime_h 273600)"
assert_eq "4h 12m" "$(_uptime_h 15120)"
assert_eq "12m" "$(_uptime_h 720)"
assert_eq "45s" "$(_uptime_h 45)"
assert_eq "0s" "$(_uptime_h junk)"
assert_eq "0s" "$(_uptime_h)"

t "_data_services: no conf.d -> built-in set"
rm -f /etc/conf.d/mountnas
assert_eq "docker samba nfs" "$(_data_services)"

t "_data_services: commented out -> built-in set"
printf '#DATA_SERVICES="samba nfs"\n' > /etc/conf.d/mountnas
assert_eq "docker samba nfs" "$(_data_services)"

t "_data_services: a subset"
printf 'DATA_SERVICES="samba nfs"\n' > /etc/conf.d/mountnas
assert_eq "samba nfs" "$(_data_services)"

t "_data_services: an explicitly empty list means EMPTY"
printf 'DATA_SERVICES=""\n' > /etc/conf.d/mountnas
assert_eq "" "$(_data_services)"

t "_data_services: a conf.d that dies falls back to the built-in set"
printf 'DATA_SERVICES="samba"\nexit 3\n' > /etc/conf.d/mountnas
assert_eq "docker samba nfs" "$(_data_services)"
printf 'set -u\nDATA_SERVICES="$UNSET_TYPO"\n' > /etc/conf.d/mountnas
assert_eq "docker samba nfs" "$(_data_services)"
rm -f /etc/conf.d/mountnas

t "_conf_set_port: adds, replaces, keeps other lines"
f=/etc/conf.d/unit-port; rm -f "$f"
_conf_set_port "$f" 8080
assert_eq "PORT=8080" "$(cat "$f")"
printf '# keep me\nWEB_REFRESH_SEC=30\nPORT=8080\n' > "$f"
_conf_set_port "$f" 9090
assert_eq "$(printf '# keep me\nWEB_REFRESH_SEC=30\nPORT=9090')" "$(cat "$f")"
rm -f "$f"

t "_syslog_target / _syslog_set_persist keep user tokens"
printf '# syslog conf\nSYSLOGD_OPTS="-t -R 10.0.0.9 -m 0"\nOTHER=1\n' > /etc/conf.d/syslog
assert_eq "" "$(_syslog_target)"
_syslog_set_persist "-O /mnt/nasdata/logs/messages -s 1024 -b 5"
assert_eq "/mnt/nasdata/logs/messages" "$(_syslog_target)"
assert_eq '# syslog conf
SYSLOGD_OPTS="-t -R 10.0.0.9 -m 0 -O /mnt/nasdata/logs/messages -s 1024 -b 5"
OTHER=1' "$(cat /etc/conf.d/syslog)"
_syslog_set_persist ""
assert_eq 'SYSLOGD_OPTS="-t -R 10.0.0.9 -m 0"' "$(grep SYSLOGD_OPTS /etc/conf.d/syslog)"
assert_eq "" "$(_syslog_target)"

t "_syslog_set_persist: missing file and missing line"
rm -f /etc/conf.d/syslog
_syslog_set_persist "-O /x"
assert_eq 'SYSLOGD_OPTS="-t -O /x"' "$(cat /etc/conf.d/syslog)"
rm -f /etc/conf.d/syslog

t "_snap_note keys on the file mtime stamp"
snap=/cfg/unit.20240102030405.tar.gz
# TZ first: busybox reads 'touch -d' in LOCAL time, _snap_note stamps with -u
TZ=UTC; export TZ
: > "$snap"; touch -d '2024-01-02 03:04:05' "$snap"
printf '20240102030405\tbefore nfs\n20240101000000\tother\n' > /cfg/.mountnas-notes
assert_eq "before nfs" "$(_snap_note "$snap")"
assert_eq "" "$(_snap_note /cfg/does-not-exist)"
rm -f "$snap" /cfg/.mountnas-notes

t "_ops_log appends a tab-separated record and self-trims"
stub mountpoint 'exit 0'
rm -f /cfg/mountnas-ops.log
_ops_log commit "note one"
assert_match "^[0-9T:Z-]+	commit	[^	]+	note one$" "$(cat /cfg/mountnas-ops.log)"
i=0; while [ $i -lt 1205 ]; do echo "x	y	z	$i"; i=$((i+1)); done > /cfg/mountnas-ops.log
_ops_log backup "last"
assert_eq 1000 "$(wc -l < /cfg/mountnas-ops.log)" "trimmed to the last 1000 (new record included)"
assert_match "	backup	.*	last$" "$(tail -n1 /cfg/mountnas-ops.log)"

t "_ops_log is a silent no-op without /cfg"
stub mountpoint 'exit 1'
rm -f /cfg/mountnas-ops.log
_ops_log commit "lost"
[ ! -e /cfg/mountnas-ops.log ] || fail "wrote without /cfg mounted"

t "_path_on_disk classifies ok / dead / ram, and refuses a relative path"
stub mountpoint 'case "$2" in /|/mnt/disk1) exit 0;; esac; exit 1'
mkdir -p /mnt/disk1/media/films
# _blocked reads the real /proc/mounts, so the blocked case is not testable here
assert_eq "ok" "$(_path_on_disk /mnt/disk1/media/films)"
assert_eq "ram" "$(_path_on_disk /srv/share)"
# a relative path must never reach the walk: dirname's fixpoint is '.', which
# never equals '/', so walking one spun forever and hung the whole command
assert_eq "ram" "$(_path_on_disk mnt/disk1/media)"
# a detached device: the mount is still listed but every read returns EIO
stub ls 'exit 2'
assert_eq "dead" "$(_path_on_disk /mnt/disk1/media/films)"
rm -f "$STUBS/ls"

t "_space_check: ok / warn / fail by percent used"
# df is stubbed so the thresholds are exercised deterministically, with no
# real filesystem to fill. Columns match df -Pk / -Ph: size, used, avail.
NAS_CHECKS=$(mktemp); export NAS_CHECKS
stub df 'echo "Filesystem 1024-blocks Used Available Capacity Mounted"; echo "/dev/x 1000 500 500 50% /p"'
out=$(_space_check /p "test fs" 80 90 "it breaks"); assert_match "\[ OK \]" "$out" "50% is ok"
stub df 'echo "Filesystem 1024-blocks Used Available Capacity Mounted"; echo "/dev/x 1000 850 150 85% /p"'
out=$(_space_check /p "test fs" 80 90 "it breaks"); assert_match "\[WARN\]" "$out" "85% warns"
assert_match "it breaks" "$out" "the consequence is named"
stub df 'echo "Filesystem 1024-blocks Used Available Capacity Mounted"; echo "/dev/x 1000 950 50 95% /p"'
out=$(_space_check /p "test fs" 80 90 "it breaks"); assert_match "\[FAIL\]" "$out" "95% fails"
# an unreadable df must stay SILENT, never invent a verdict
stub df 'exit 1'
out=$(_space_check /p "test fs" 80 90 "it breaks"); assert_eq "" "$out" "unreadable df says nothing"
rm -f "$STUBS/df"

t "_boot_usb_disk uses findfs + lsblk pkname"
stub findfs 'echo /dev/sdz1'
stub lsblk 'echo sdz'
assert_eq "sdz" "$(_boot_usb_disk)"
stub findfs 'exit 1'
stub lsblk 'exit 1'
assert_eq "" "$(_boot_usb_disk)"

t "_phys_disks drops zram/loop/ram devices"
stub lsblk 'printf "sda  disk
zram0 disk
loop0 disk
sr0  rom
nvme0n1 disk
"'
assert_eq "sda
nvme0n1" "$(_phys_disks)"

finish
