#!/bin/sh
# nas commit / nas rollback / nas changes: the refusal gates and the overlay
# bookkeeping on /cfg. lbu is a stub that writes a fake overlay.
. "$(dirname "$0")/harness.sh"
host=$(hostname)
act="/cfg/$host.apkovl.tar.gz"
stub mountpoint 'case "$2" in /|/cfg) exit 0 ;; esac; exit 1'
# 'lbu commit' rotates like the real one: the old active overlay becomes
# <host>.<stamp>.tar.gz, then a new active overlay is written
# A COUNTER, not the clock. Snapshot names and note keys are whole-second
# mtimes, and busybox 'date' drops %N, so the stub used to 'sleep 1' after
# every commit to make successive overlays differ in both mtime and content.
# That cost 7 s of a 12 s suite. The counter gives each overlay a distinct
# mtime (touch -d @epoch) and distinct content, with no clock dependency.
: > /tmp/lbu-n
stub lbu "case \"\$1\" in
	commit) n=\$(( \$(cat /tmp/lbu-n 2>/dev/null || echo 0) + 1 )); echo \"\$n\" > /tmp/lbu-n
	        [ -f '$act' ] && mv '$act' \"/cfg/$host.\$(date -u -r '$act' +%Y%m%d%H%M%S).tar.gz\"
	        echo \"ovl \$n\" > '$act'; touch -d \"@\$(( 1700000000 + n * 60 ))\" '$act' ;;
	status) cat /tmp/lbu-status 2>/dev/null ;;
	esac"
reset() { rm -f /cfg/*.tar.gz /cfg/*.tar.gz.* /cfg/.mountnas-notes /cfg/mountnas-ops.log; : > /etc/apk/protected_paths.d/lbu.list; : > /tmp/lbu-status; }

t "commit refuses when /cfg is not mounted"
reset; stub mountpoint 'exit 1'
run_nas commit -m x
assert_rc 1
assert_match 'config partition \(/cfg\) not mounted — refusing' "$OUT"
[ ! -f "$act" ] || fail "overlay written anyway"
stub mountpoint 'case "$2" in /|/cfg) exit 0 ;; esac; exit 1'

t "commit refuses when a data path is in the lbu include list"
reset; echo '+mnt/disk1' > /etc/apk/protected_paths.d/lbu.list
run_nas commit -m x
assert_rc 1
assert_match 'a data path is in the lbu include list — refusing' "$OUT"

t "commit -m needs a note; extra args are a usage error"
reset
run_nas commit -m; assert_rc 1; assert_match 'usage: nas commit' "$OUT"
run_nas commit bogus; assert_rc 1; assert_match 'usage: nas commit' "$OUT"

t "commit saves, records the note by overlay mtime, logs the operation"
reset
run_nas commit -m "first	note
two lines"
assert_rc 0
assert_match '\[ OK \] saved to /cfg  \(note: first note two lines\)' "$OUT"
[ -f "$act" ] || fail "no active overlay"
stamp=$(date -u -r "$act" +%Y%m%d%H%M%S)
assert_eq "$stamp	first note two lines" "$(cat /cfg/.mountnas-notes)"
assert_match '	commit	.*	first note two lines$' "$(tail -n1 /cfg/mountnas-ops.log)"

t "commit prints the DELTA it saves, never the whole archive"
reset
printf 'M etc/fstab
A etc/exports
' > /tmp/lbu-status
run_nas commit -m note
assert_rc 0
assert_match 'Saving 2 change' "$OUT"
assert_match 'M etc/fstab' "$OUT"
assert_nomatch 'etc/passwd|etc/runlevels' "$OUT" "steady-state members must not print"
assert_match 'full overlay re-packed' "$OUT"
assert_match 'nas commit -v' "$OUT" "points at the full listing"

t "commit with no pending changes says so and still re-packs"
reset
run_nas commit -m note
assert_rc 0
assert_match 'No new changes' "$OUT"
assert_match 'saved to /cfg' "$OUT"

t "non-tty commit without -m never prompts (no note)"
reset; run_nas save
assert_rc 0
assert_match '\[ OK \] saved to /cfg$' "$OUT"
[ ! -s /cfg/.mountnas-notes ] || fail "a note was recorded: $(cat /cfg/.mountnas-notes)"

t "rollback --list: nothing, then the rotated snapshots with their notes"
reset; run_nas rollback --list
assert_rc 0
assert_match 'no snapshots yet' "$OUT"
run_nas commit -m "one"; run_nas commit -m "two"; run_nas commit -m "three"
run_nas rollback --list
assert_rc 0
assert_match 'ACTIVE \(applies at next boot\)  — three' "$OUT"
assert_match '\[1\] .*— two' "$OUT"
assert_match '\[2\] .*— one' "$OUT"
assert_nomatch '\[3\]' "$OUT"

t "rollback <n>: validates the number, swaps the overlay, keeps the current one"
run_nas rollback x; assert_rc 1; assert_match 'usage: nas rollback' "$OUT"
run_nas rollback 9; assert_rc 1; assert_match 'no snapshot number 9' "$OUT"
sel=$(ls -1t /cfg/"$host".[0-9]*.tar.gz | sed -n 2p)   # [2] = "one"
before_active=$(cat "$act")
want=$(cat "$sel")
run_nas_in y rollback 2
assert_rc 0
assert_match "restored $(basename "$sel") as the active saved config" "$OUT"
assert_eq "$want" "$(cat "$act")" "active overlay content"
grep -qxF "$before_active" /cfg/"$host".[0-9]*.tar.gz || fail "the replaced overlay was not kept as a snapshot"
assert_match '	rollback	' "$(tail -n1 /cfg/mountnas-ops.log)"

t "rollback: a stale .new is cleared, an encrypted overlay is refused"
reset; run_nas commit -m a; run_nas commit -m b
: > "$act.new"
run_nas rollback --list
assert_rc 0
[ ! -e "$act.new" ] || fail "stale .new left behind"
: > "$act.gpg"
run_nas rollback --list
assert_rc 1
assert_match 'encrypted overlay detected' "$OUT"
rm -f "$act.gpg"

t "changes lists lbu status; --diff without an overlay warns"
reset; run_nas changes
assert_rc 0; assert_match 'no unsaved changes' "$OUT"
printf 'M etc/fstab\nA etc/unit-new\n' > /tmp/lbu-status
echo new > /etc/unit-new
run_nas changes
assert_rc 0
assert_match '^2 unsaved change\(s\)' "$OUT"
assert_match 'M etc/fstab' "$OUT"
run_nas changes --diff
assert_rc 0
assert_match 'no committed overlay yet' "$OUT"
assert_match '\+new' "$OUT"
rm -f /etc/unit-new

finish
