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
reset() { rm -f /cfg/*.tar.gz /cfg/*.tar.gz.* /cfg/.mountnas-notes /cfg/mountnas-ops.log; rm -rf /mnt/nasdata/config-backups; : > /etc/apk/protected_paths.d/lbu.list; : > /tmp/lbu-status; }

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

t "commit carries the overlay to a NEW hostname instead of failing"
# THE wizard bug: lbu names the overlay after the current hostname and refuses
# to commit while /cfg holds one under a different name ("Please use -d to
# replace"), so changing the hostname — the wizard's FIRST prompt — made its
# own closing save fail. Setup then claimed success while the root password
# and hostname were never written, and the next boot reverted everything.
reset
printf 'seed overlay\n' > /cfg/oldname.apkovl.tar.gz
run_nas commit -m renamed
assert_rc 0
[ -f "$act" ] || fail "overlay was not carried to $host.apkovl.tar.gz"
[ ! -f /cfg/oldname.apkovl.tar.gz ] || fail "the stale overlay is still there — lbu would refuse"
assert_match 'overlay renamed for the new hostname' "$OUT"

t "commit leaves TWO overlays alone — that is lbu's refusal to make"
# more than one apkovl is a genuine security concern (the diskless init cannot
# tell which to load), so the rename must not silently pick one
reset
printf 'a\n' > /cfg/one.apkovl.tar.gz; printf 'b\n' > /cfg/two.apkovl.tar.gz
run_nas commit -m twoovl
[ -f /cfg/one.apkovl.tar.gz ] && [ -f /cfg/two.apkovl.tar.gz ] \
	|| fail "a stale overlay was removed while two were present"
assert_nomatch 'overlay renamed' "$OUT"
reset

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

t "commit mirrors the overlay to the data disk (0700 dir, 0600 file)"
reset
stub mountpoint 'exit 0'          # cfg AND nasdata mounted for the mirror trio
rm -rf /mnt/nasdata/config-backups
run_nas commit -m note
assert_rc 0
assert_match 'mirrored to /mnt/nasdata/config-backups \(1 kept\)' "$OUT"
m=$(find /mnt/nasdata/config-backups -name '*.apkovl.tar.gz' | head -n1)
[ -n "$m" ] || fail "no mirror file written"
assert_eq 700 "$(stat -c %a /mnt/nasdata/config-backups)" "dir mode"
assert_eq 600 "$(stat -c %a "$m")" "file mode"
cmp -s "$m" "/cfg/$(hostname).apkovl.tar.gz" || fail "mirror differs from the overlay"

t "mirror retention keeps the newest 30"
reset
stub mountpoint 'exit 0'          # self-contained: not reliant on the case above
mkdir -p /mnt/nasdata/config-backups
i=0; while [ $i -lt 34 ]; do
	i=$((i + 1))
	f=/mnt/nasdata/config-backups/mountnas-2020010100$(printf '%04d' $i).apkovl.tar.gz
	: > "$f"; touch -d "@$(( 1600000000 + i * 60 ))" "$f"
done
run_nas commit -m note
assert_rc 0
assert_match '\(30 kept\)' "$OUT"
assert_eq 30 "$(find /mnt/nasdata/config-backups -name '*.apkovl.tar.gz' | grep -c .)" "pruned to 30"
[ ! -e /mnt/nasdata/config-backups/mountnas-20200101000001.apkovl.tar.gz ] \
	|| fail "the oldest mirror survived the prune"

t "mirror skips with a hint when the data disk is absent — commit still succeeds"
reset
# mountpoint: /cfg mounted, /mnt/nasdata NOT (the stub answers per path)
stub mountpoint 'case "$2" in /mnt/nasdata) exit 1 ;; *) exit 0 ;; esac'
run_nas commit -m note
assert_rc 0 "a missing data disk must never fail the commit"
assert_match 'mirror skipped \(data disk not mounted\)' "$OUT"
# a HINT by contract: rendering it [WARN]/[FAIL] would nag every commit on a
# box that legitimately runs without nasdata (mutation-checked)
assert_nomatch '\[(WARN|FAIL)\].*mirror skipped' "$OUT" "the skip must stay a hint"
assert_match 'saved to /cfg' "$OUT"
t "an encrypted overlay skips the mirror quietly, never a warning"
reset
stub mountpoint 'exit 0'
run_nas commit -m note
mv "/cfg/$(hostname).apkovl.tar.gz" "/cfg/$(hostname).apkovl.tar.gz.aes-256-cbc"
rm -rf /mnt/nasdata/config-backups
# the lbu stub recreates the plain overlay on commit, so simulate the
# encrypted-box shape by pointing hostname elsewhere for one run
stub hostname 'echo encbox'
run_nas commit -m note
assert_rc 0
assert_match 'mirror skipped \(no plain overlay' "$OUT"
assert_nomatch '\[WARN\].*mirror' "$OUT" "an encrypted setup must not warn every commit"
rm -f "$STUBS/hostname" /cfg/*.aes-256-cbc
stub mountpoint 'case "$2" in /|/cfg) exit 0 ;; esac; exit 1'   # the file default

t "rollback refreshes the mirror to the restored config"
reset
stub mountpoint 'exit 0'
run_nas commit -m first
run_nas commit -m second
run_nas_in y rollback 1
assert_rc 0
m=$(ls -1t /mnt/nasdata/config-backups/*.apkovl.tar.gz | head -n1)
cmp -s "$m" "/cfg/$(hostname).apkovl.tar.gz" \
	|| fail "newest mirror is not the ROLLED-BACK overlay — a dead stick would restore the config the user escaped"
stub mountpoint 'case "$2" in /|/cfg) exit 0 ;; esac; exit 1'   # the file default

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

t "rollback lists and restores snapshots taken under an OLD hostname"
# Renaming the box does not rename its history. The lister was pinned to the
# current hostname while 'nas commit' retention was not, so after a rename
# the time machine went blank while the snapshots it hid were still being
# counted and deleted -- and a rename is exactly the kind of change a user
# wants to be able to undo.
reset
run_nas commit -m "before the rename"
run_nas commit -m "also before"
# rename every file on /cfg to the old name, as a real rename leaves it
for f in /cfg/"$host".*; do mv "$f" "/cfg/oldbox.${f#/cfg/"$host".}"; done
run_nas rollback --list
assert_rc 0
assert_match '\[1\] .*oldbox\.' "$OUT" "an old-hostname snapshot must still be listed"
assert_nomatch 'no snapshots yet' "$OUT"
# and restoring one must work: the overlay is carried to the new name first
want=$(cat "$(ls -1t /cfg/oldbox.[0-9]*.tar.gz | sed -n 1p)")
run_nas_in y rollback 1
assert_rc 0
[ -f "$act" ] || fail "restore did not create the overlay under the NEW hostname"
assert_eq "$want" "$(cat "$act")" "restored content"

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
