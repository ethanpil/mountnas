#!/bin/sh
# nas snapraid + the snapraid-maint runner. The snapraid binary is a stub
# that logs its invocations; the gate, the preflight, the parse, the
# schedule surgery and the status assembly are real.
. "$(dirname "$0")/harness.sh"

MAINT=/usr/libexec/mountnas/snapraid-maint
CALLS=/tmp/snapraid-calls
stub lbu ':'
stub rc-service 'exit 0'          # crond "running"
# mountpoint: everything is "mounted" except paths carrying not-mounted
stub mountpoint 'case "$2" in *not-mounted*) exit 1 ;; *) exit 0 ;; esac'

# The stub snapraid: logs every invocation; behavior driven by files.
#   /tmp/diff-out    the diff output    /tmp/diff-rc  its exit code
#   /tmp/sync-rc, /tmp/scrub-rc         exit codes (default 0)
stub snapraid 'echo "$*" >> /tmp/snapraid-calls
case "$1" in
	diff)  cat /tmp/diff-out 2>/dev/null; exit "$(cat /tmp/diff-rc 2>/dev/null || echo 0)" ;;
	sync)  exit "$(cat /tmp/sync-rc 2>/dev/null || echo 0)" ;;
	scrub) exit "$(cat /tmp/scrub-rc 2>/dev/null || echo 0)" ;;
	touch) exit 0 ;;
	status) echo "stub-status"; exit 0 ;;
esac'

# a mounted two-disk array: /proc/mounts is real in the chroot, so the
# preflight walk needs paths whose mountpoint is not /. Use /run (a real
# tmpfs mount in the chroot) as the "disk".
seed() {   # $1 = extra conf lines
	mkdir -p /run/disk1 /run/parity1
	cat > /etc/snapraid.conf <<EOF
parity /run/parity1/snapraid.parity
content /run/disk1/snapraid.content
data d1 /run/disk1
${1:-}
EOF
	rm -rf /mnt/nasdata/snapraid /etc/mountnas/snapraid-maint.conf \
		"$CALLS" /tmp/diff-out /tmp/diff-rc /tmp/sync-rc /tmp/scrub-rc
	crontab -r 2>/dev/null || true
}
diff_counts() {   # $1 add $2 rem $3 upd -> writes diff output + rc 2
	printf '   %s added\n   %s removed\n   %s updated\n   0 moved\n' \
		"$1" "$2" "$3" > /tmp/diff-out
	echo 2 > /tmp/diff-rc
}

t "runner: clean run syncs then scrubs, writes SYNCED state"
seed; diff_counts 12 3 0
"$MAINT"; rc=$?
assert_eq 0 "$rc" "exit code"
assert_match '^touch$' "$(cat $CALLS)" "touch ran"
assert_match '^sync$' "$(cat $CALLS)" "sync ran"
assert_match '^scrub -p 7 -o 10$' "$(cat $CALLS)" "scrub ran with defaults"
assert_match '^verdict=SYNCED$' "$(cat /mnt/nasdata/snapraid/state/last-run)"
assert_match '^deleted=3$' "$(cat /mnt/nasdata/snapraid/state/last-run)"

t "runner: gate blocks above DEL_THRESHOLD, parity untouched"
seed; diff_counts 0 101 0
"$MAINT"; rc=$?
assert_eq 1 "$rc" "exit 1 = blocked"
assert_nomatch '^sync$' "$(cat $CALLS)" "sync must NOT run"
assert_nomatch '^touch$' "$(cat $CALLS)" "a blocked run touches nothing"
assert_match '^verdict=BLOCKED$' "$(cat /mnt/nasdata/snapraid/state/last-run)"
assert_eq 1 "$(cat /mnt/nasdata/snapraid/state/blocked-count)" "blocked counter"

t "runner: passes AT the threshold, blocks at threshold+1 (updates)"
seed; diff_counts 0 0 200
"$MAINT"
assert_eq 0 "$?" "200 updated = at threshold, passes"
seed; diff_counts 0 0 201
"$MAINT"
assert_eq 1 "$?" "201 updated blocks"

t "runner: threshold 0 disables that gate (value carries an inline comment)"
seed; diff_counts 0 5000 0
# the SEEDED conf has an inline comment on every line — parsing must cut
# it, not glue it onto the value (the QEMU run caught exactly this)
printf 'DEL_THRESHOLD=0       # block sync above this many deleted files\n' \
	> /etc/mountnas/snapraid-maint.conf
"$MAINT"
assert_eq 0 "$?" "DEL_THRESHOLD=0 = no delete gate"
assert_match '^sync$' "$(cat $CALLS)"

t "runner: SNAPRAID_MAINT_FORCE=1 skips the gate"
seed; diff_counts 0 5000 5000
SNAPRAID_MAINT_FORCE=1 "$MAINT"
assert_eq 0 "$?"
assert_match '^sync$' "$(cat $CALLS)"

t "runner: unparseable diff output fails CLOSED"
seed
printf 'weird new format\n' > /tmp/diff-out; echo 2 > /tmp/diff-rc
"$MAINT"; rc=$?
assert_eq 1 "$rc" "must read as blocked, never as 0 changes"
assert_nomatch '^sync$' "$(cat $CALLS)"

t "runner: preflight refuses when a data disk is not mounted"
seed 'data d2 /not-mounted/disk2'
diff_counts 1 0 0
"$MAINT"; rc=$?
assert_eq 2 "$rc"
assert_nomatch '^diff$' "$(cat $CALLS 2>/dev/null || :)" "nothing ran"

t "runner: preflight covers 2-parity and split-parity paths"
seed '2-parity /not-mounted/p2/snapraid.2-parity'
"$MAINT"
assert_eq 2 "$?" "2-parity disk missing must refuse"
seed "z-parity /run/parity1/a.z,/not-mounted/b.z"
"$MAINT"
assert_eq 2 "$?" "second file of a split parity missing must refuse"

t "runner: nothing to do still scrubs, verdict NOTHING"
seed; : > /tmp/diff-out; echo 0 > /tmp/diff-rc
"$MAINT"
assert_eq 0 "$?"
assert_nomatch '^sync$' "$(cat $CALLS)"
assert_match '^scrub' "$(cat $CALLS)" "scrub rotation continues"
assert_match '^verdict=NOTHING$' "$(cat /mnt/nasdata/snapraid/state/last-run)"

t "runner: SCRUB_PERCENT=0 skips the scrub"
seed; diff_counts 1 0 0
printf 'SCRUB_PERCENT=0\n' > /etc/mountnas/snapraid-maint.conf
"$MAINT"
assert_eq 0 "$?"
assert_nomatch '^scrub' "$(cat $CALLS)"

t "runner: sync failure is exit 4 FAILED"
seed; diff_counts 1 0 0; echo 1 > /tmp/sync-rc
"$MAINT"
assert_eq 4 "$?"
assert_match '^verdict=FAILED$' "$(cat /mnt/nasdata/snapraid/state/last-run)"

t "runner: a garbage conf value falls back to the default"
seed; diff_counts 0 101 0
printf 'DEL_THRESHOLD=banana\n' > /etc/mountnas/snapraid-maint.conf
"$MAINT"
assert_eq 1 "$?" "101 deletions still blocked by the default 100"

t "runner: lock refuses a second concurrent run"
seed; diff_counts 1 0 0
mkdir -p /run/lock
( exec 9> /run/lock/mountnas-snapraid.lock; flock 9; sleep 2 ) &
lockpid=$!
sleep 0.3
"$MAINT"
assert_eq 3 "$?" "lock held = exit 3"
assert_nomatch '^sync$' "$(cat $CALLS 2>/dev/null || :)"
wait "$lockpid" 2>/dev/null || true

t "nas snapraid status: unconfigured box gets the setup steps, rc 0"
seed; rm -f /etc/snapraid.conf; : > /etc/snapraid.conf
run_nas snapraid status
assert_rc 0
assert_match 'SnapRAID not configured' "$OUT"
assert_match 'nas disks' "$OUT"

t "nas snapraid status: disk table shows roles, mounts, and counts"
seed '2-parity /run/parity1/snapraid.2-parity'
run_nas snapraid status
assert_rc 0
assert_match 'array configured.*1 data, 2 parity' "$OUT"
assert_match 'd1 +data +/run/disk1 +mounted' "$OUT"
assert_match '2-parity +parity' "$OUT"
assert_match 'disks mounted +\(3/3\)' "$OUT"

t "nas snapraid status: a missing disk rows as MISSING and FAILs the check"
seed 'data d2 /not-mounted/disk2'
run_nas snapraid status
assert_match 'd2 +data +/not-mounted/disk2 +MISSING' "$OUT"
assert_match '\[FAIL\] disks mounted +\(2/3' "$OUT"

t "nas snapraid status: cheap path never calls snapraid"
seed; rm -f "$CALLS"
run_nas snapraid status
[ ! -e "$CALLS" ] || fail "snapraid was invoked on the cheap path: $(cat $CALLS)"

t "nas snapraid status --deep calls snapraid status"
seed; rm -f "$CALLS"
run_nas snapraid status --deep
assert_match '^status$' "$(cat $CALLS)"
assert_match 'stub-status' "$OUT"

t "schedule: writes the marker line; status shows it; off removes it"
seed
run_nas snapraid schedule
assert_rc 0
assert_match 'scheduled at 02:00' "$OUT"
assert_match '^0 2 \* \* \* /usr/libexec/mountnas/snapraid-maint # mountnas-snapraid$' "$(crontab -l)"
run_nas snapraid status
assert_match 'scheduled' "$OUT"
run_nas snapraid schedule off
assert_rc 0
assert_eq "" "$(crontab -l 2>/dev/null | grep -F mountnas-snapraid)" "line removed"

t "schedule: idempotent — twice leaves ONE line"
seed
run_nas snapraid schedule 03:30
run_nas snapraid schedule 04:15
assert_eq 1 "$(crontab -l | grep -cF mountnas-snapraid)" "one marker line"
assert_match '^15 4 ' "$(crontab -l)" "latest time wins"

t "schedule: rejects a bad time"
seed
run_nas snapraid schedule 25:00
assert_rc 1
assert_match 'usage: nas snapraid schedule' "$OUT"
run_nas snapraid schedule 9:75
assert_rc 1

t "schedule: warns about a pre-existing hand-rolled snapraid cron line"
seed
printf '0 3 * * * snapraid sync\n' | crontab -
run_nas snapraid schedule
assert_match 'ANOTHER snapraid line' "$OUT"
assert_match 'parity runs twice' "$OUT"

t "schedule: warns when crond is not running"
seed
stub rc-service 'exit 1'
run_nas snapraid schedule
assert_match 'crond is NOT running' "$OUT"
stub rc-service 'exit 0'

t "schedule and run refuse on an unconfigured array"
seed; : > /etc/snapraid.conf
run_nas snapraid schedule
assert_rc 1
assert_match 'no array in /etc/snapraid.conf' "$OUT"
run_nas snapraid run
assert_rc 1
assert_match 'no array' "$OUT"

t "conf file is created with defaults when absent (upgrade path)"
seed
run_nas snapraid schedule
assert_match 'created /etc/mountnas/snapraid-maint.conf' "$OUT"
assert_match '^DEL_THRESHOLD=100' "$(cat /etc/mountnas/snapraid-maint.conf)"
run_nas snapraid schedule 05:00
assert_nomatch 'created /etc' "$OUT" "not recreated when present"

t "nas snapraid run --force-sync warns and forces; bad flag is usage"
seed; diff_counts 0 9999 0
run_nas snapraid run --force-sync
assert_rc 0
assert_match 'gate DISABLED' "$OUT"
run_nas snapraid run --bogus
assert_rc 1
assert_match 'usage: nas snapraid run' "$OUT"

t "status: last run verdicts render (SYNCED ok, BLOCKED warn + hint)"
seed; diff_counts 2 1 0
"$MAINT" >/dev/null 2>&1
run_nas snapraid status
assert_match '\[ OK \] last run .*SYNCED' "$OUT"
seed; diff_counts 0 500 0
"$MAINT" >/dev/null 2>&1
run_nas snapraid status
assert_match 'BLOCKED by the threshold gate' "$OUT"
assert_match 'force-sync' "$OUT"

t "add: data disks number dN, each with a content line"
seed
run_nas snapraid add /mnt/not-mounted-disk9
assert_rc 1
assert_match 'not a mountpoint' "$OUT"
run_nas snapraid add /run/disk2
assert_rc 1
assert_match 'live under /mnt' "$OUT" "a tmpfs mountpoint must not become an array disk"
mkdir -p /mnt/disk2
run_nas snapraid add /mnt/disk2/
assert_rc 0
assert_match '\+ data d2 /mnt/disk2/' "$OUT"
assert_match '^data d2 /mnt/disk2/$' "$(cat /etc/snapraid.conf)"
assert_match '^content /mnt/disk2/snapraid.content$' "$(cat /etc/snapraid.conf)"

t "add --parity escalates parity -> 2-parity, with content copies"
seed
mkdir -p /mnt/parity2
run_nas snapraid add /mnt/parity2 --parity
assert_rc 0
assert_match '^2-parity /mnt/parity2/snapraid.2-parity$' "$(cat /etc/snapraid.conf)"
assert_match '^content /mnt/parity2/snapraid.content$' "$(cat /etc/snapraid.conf)"

t "add --parity refuses a conf with a parity-level gap (hand-managed)"
seed
printf '2-parity /run/parity2/snapraid.2-parity\ndata d1 /run/disk1/\n' > /etc/snapraid.conf
mkdir -p /mnt/parity3
run_nas snapraid add /mnt/parity3 --parity
assert_rc 1
assert_match 'not contiguous' "$OUT" "count-based escalation would duplicate a level"

t "add refuses nasdata and duplicates"
seed
run_nas snapraid add /mnt/nasdata
assert_rc 1
assert_match 'stays OUT of the array' "$OUT"
printf 'data d9 /mnt/disk9/\n' >> /etc/snapraid.conf
mkdir -p /mnt/disk9
run_nas snapraid add /mnt/disk9
assert_rc 1
assert_match 'already in /etc/snapraid.conf' "$OUT"

t "add enforces the content minimum (nasdata copy offered; EOF/no decline)"
seed
printf 'data d1 /run/disk1/\n' > /etc/snapraid.conf   # ONE content short
mkdir -p /mnt/disk2
OUT=$(printf 'y\n' | /usr/sbin/nas snapraid add /mnt/disk2 2>&1); RC=$?
assert_rc 0
assert_match 'needs 2 content copies' "$OUT"
assert_match '^content /mnt/nasdata/snapraid.content$' "$(cat /etc/snapraid.conf)"
seed
printf 'data d1 /run/disk1/\n' > /etc/snapraid.conf
OUT=$(printf 'no\n' | /usr/sbin/nas snapraid add /mnt/disk2 2>&1)
assert_match 'content line on another disk before the first run' "$OUT"
assert_nomatch 'content /mnt/nasdata' "$(cat /etc/snapraid.conf)" "'no' must decline, not read as yes"

t "add: the content minimum follows the parity level count"
seed
# two parity levels (one via the old q- alias name) -> 3 copies required
printf 'parity /run/parity1/snapraid.parity\nq-parity /run/parity2/snapraid.q-parity\ncontent /run/disk1/snapraid.content\ndata d1 /run/disk1/\n' > /etc/snapraid.conf
mkdir -p /mnt/disk2
OUT=$(printf 'y\n' | /usr/sbin/nas snapraid add /mnt/disk2 2>&1); RC=$?
assert_rc 0
assert_match 'needs 3 content copies' "$OUT"

t "add: a mountpoint with a space is refused before any write"
seed
before=$(cat /etc/snapraid.conf)
run_nas snapraid add '/mnt/my disk'
assert_rc 1
assert_match 'spaces or shell metacharacters' "$OUT"
assert_eq "$before" "$(cat /etc/snapraid.conf)" "conf untouched"

t "unsaved schedule warns (runlevel-honesty pattern)"
seed
stub lbu 'echo "M var/spool/cron/crontabs/root"'
run_nas snapraid schedule
assert_match 'not saved' "$OUT"
run_nas snapraid status
assert_match 'NOT saved' "$OUT"
stub lbu ':'

finish
