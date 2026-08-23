#!/bin/sh
# nas snapraid — the SnapRAID Daemon switch. The daemon and OpenRC are stubs;
# the port parsing, the config surgery and the on/off/status logic are real.
. "$(dirname "$0")/harness.sh"

CONF=/etc/snapraidd.conf
seed() {
	cat > "$CONF" <<EOF
### seeded
sys_engine = /usr/bin/snapraid
sys_log_directory = /mnt/nasdata/snapraid/logs
net_enabled = 1
net_port = ${1:-7627}
net_web_root = commander.zip
#net_acl = +192.168.1.0/24
EOF
	: > /tmp/rc-state          # "" = stopped, "up" = running
	: > /tmp/rc-runlevel       # "" = not enabled
	printf 'parity /mnt/parity1/x\ndata d1 /mnt/disk1\n' > /etc/snapraid.conf
}
# rc-service/rc-update backed by the two files above, so on/off really flip
stub rc-service 'case "$2" in
	status) [ "$(cat /tmp/rc-state)" = up ] ;;
	start|restart) echo up > /tmp/rc-state ;;
	stop) : > /tmp/rc-state ;;
	esac'
stub rc-update 'case "$1" in
	-q) case "$2" in add) echo snapraidd > /tmp/rc-runlevel ;; del) : > /tmp/rc-runlevel ;; esac ;;
	show) cat /tmp/rc-runlevel ;;
	esac'
stub snapraidd 'exit 0'
stub curl 'exit 0'          # the bind probe succeeds
stub lbu ':'
stub mountpoint 'exit 0'

t "status: off by default, and says how to enable it"
seed; run_nas snapraid status
assert_rc 0
assert_match 'SnapRAID Daemon off \(enable: nas snapraid on' "$OUT"
assert_match 'default port 7627' "$OUT"

t "on: enables, starts, and prints the LAN URL"
seed; run_nas snapraid on
assert_rc 0
assert_match "SnapRAID Daemon ON -> http://$(hostname).local:7627/" "$OUT"
assert_eq snapraidd "$(cat /tmp/rc-runlevel)" "added to the runlevel"
assert_eq up "$(cat /tmp/rc-state)" "service started"

t "on: warns that the API is read-write and unauthenticated"
assert_match 'READ-WRITE and has NO password' "$OUT"
assert_match 'net_acl' "$OUT"

t "status: running now reports the URL"
run_nas snapraid status
assert_rc 0
assert_match "SnapRAID Daemon running -> http://$(hostname).local:7627/" "$OUT"

t "off: stops and disables, and says the array is untouched"
run_nas snapraid off
assert_rc 0
assert_match 'SnapRAID Daemon OFF' "$OUT"
assert_match 'array and its parity are untouched' "$OUT"
assert_eq "" "$(cat /tmp/rc-runlevel)" "removed from the runlevel"
assert_eq "" "$(cat /tmp/rc-state)" "service stopped"

t "on <port>: rewrites ONLY net_port and keeps every other line"
seed; run_nas snapraid on 9000
assert_rc 0
assert_match 'http://[^ ]*:9000/' "$OUT"
assert_eq "net_port = 9000" "$(grep '^net_port' $CONF)"
assert_match 'sys_engine = /usr/bin/snapraid' "$(cat $CONF)"
assert_match 'net_web_root = commander.zip' "$(cat $CONF)"
assert_match '#net_acl = \+192.168.1.0/24' "$(cat $CONF)"
assert_match '^### seeded' "$(cat $CONF)"

t "a loopback bind keeps its address and is reported as local-only"
seed 127.0.0.1:7627
run_nas snapraid on
assert_rc 0
assert_match 'http://127.0.0.1:7627/' "$OUT"
assert_nomatch "$(hostname).local" "$OUT" "must not advertise a LAN URL for a loopback bind"
assert_match 'bound to loopback only' "$OUT"
assert_nomatch 'READ-WRITE' "$OUT" "no LAN warning when it is not on the LAN"

t "on <port> on a loopback bind stays on loopback"
seed 127.0.0.1:7627
run_nas snapraid on 8123
assert_eq "net_port = 127.0.0.1:8123" "$(grep '^net_port' $CONF)"
assert_match 'http://127.0.0.1:8123/' "$OUT"

t "a TLS port suffix and a multi-listener line still yield a port"
seed "7627s"; run_nas snapraid status
assert_match 'default port 7627|:7627/' "$OUT"
seed "127.0.0.1:7627,8080"; run_nas snapraid on
assert_match ':8080/' "$OUT" "last listener wins"

t "a missing or garbled net_port falls back to 7627"
seed; sed -i '/^net_port/d' "$CONF"; run_nas snapraid status
assert_match 'default port 7627' "$OUT"
seed; sed -i 's/^net_port.*/net_port = junk/' "$CONF"; run_nas snapraid status
assert_match 'default port 7627' "$OUT"

t "on with no array configured hints instead of refusing"
seed; : > /etc/snapraid.conf
run_nas snapraid on
assert_rc 0
assert_match 'no array in /etc/snapraid.conf yet' "$OUT"
assert_eq up "$(cat /tmp/rc-state)" "still started"

t "on refuses when the daemon binary is missing"
seed; rm -f "$STUBS/snapraidd"
run_nas snapraid on
assert_rc 1
assert_match 'snapraidd missing' "$OUT"
stub snapraidd 'exit 0'

t "on refuses when the config was removed"
seed; rm -f "$CONF"
run_nas snapraid on
assert_rc 1
assert_match '/etc/snapraidd.conf missing' "$OUT"

t "a bad argument is a usage error"
seed; run_nas snapraid bogus
assert_rc 1
assert_match 'usage: nas snapraid' "$OUT"
run_nas snapraid on notaport
assert_rc 1
assert_match 'usage: nas snapraid' "$OUT"

t "unsaved changes are called out"
seed; stub lbu 'echo "M etc/snapraidd.conf"'
run_nas snapraid status
assert_match 'NOT saved' "$OUT"
stub lbu ':'

t "enabled but not running is reported distinctly"
seed; echo snapraidd > /tmp/rc-runlevel; : > /tmp/rc-state
run_nas snapraid status
assert_match 'enabled but not running' "$OUT"

finish
