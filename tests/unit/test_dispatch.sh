#!/bin/sh
# The dispatcher: help interception, unknown commands, usage errors.
. "$(dirname "$0")/harness.sh"
stub lbu ':'

t "nas with no args prints the overview"
run_nas
assert_rc 0
assert_match '^Subcommands' "$OUT"
assert_match 'Per-command help: nas <command> --help' "$OUT"

t "nas <cmd> --help never runs the command"
# a stub that would be called if 'status' ran for real
stub rc-service 'echo RAN >> /tmp/ran; exit 0'
rm -f /tmp/ran
run_nas status --help
assert_rc 0
assert_match '^nas status \[--deep\|--json\]' "$OUT"
[ ! -e /tmp/ran ] || fail "status ran despite --help"

t "every mapped topic has a page (nas help <topic>)"
# EVERY alias belongs in this list. 'disk' and 'shares' were missing, and both
# were broken: _cmd_help_for kept a second, partial alias map for its existence
# re-check, so those two printed their page and THEN returned 1 — the caller
# read that as an unknown topic and dumped the whole overview underneath.
for topic in status disks disk mount changes changed rollback backup logs log upgrade shutdown \
	reboot setup version about commit save restart report web ttyd snapraid share shares history notify; do
	run_nas help "$topic"
	[ "$RC" = 0 ] || fail "help $topic: rc=$RC"
	case "$topic" in
		disk) want=disks ;; changed) want=changes ;; log) want=logs ;;
		save) want=commit ;; shares) want=share ;; *) want=$topic ;;
	esac
	assert_match "^nas $want" "$OUT" "help $topic"
	# the page ALONE — never the overview printed on top of it
	assert_nomatch '^Everyday' "$OUT" "help $topic printed the overview too"
done

t "an aliased <cmd> --help prints the page only, and exits 0"
for topic in disk shares changed log save reboot; do
	run_nas "$topic" --help
	[ "$RC" = 0 ] || fail "$topic --help: rc=$RC"
	assert_nomatch '^Everyday' "$OUT" "$topic --help printed the overview too"
done

t "nas help <typo> fails with the command list"
run_nas help bogus
assert_rc 1
assert_match "^no help for 'bogus'" "$OUT"
assert_match '^Everyday' "$OUT"

t "unknown command fails with the command list"
run_nas nonsense
assert_rc 1
assert_match '^unknown command: nonsense' "$OUT"

t "nas status rejects an unknown flag"
run_nas status --bogus
assert_rc 1
assert_match 'usage: nas status' "$OUT"

t "nas version shows release and build"
run_nas version
assert_rc 0
assert_eq "MountNAS unit-test (build 9.9.9)" "$OUT"

t "the prompt cache is refreshed after a command"
# Clear it first: the test files share one root, and an earlier file leaves
# its own count here. Without this the case passes on stale state — removing
# the dispatcher's _refresh_unsaved call kept the whole suite green.
rm -f /run/mountnas/unsaved
stub lbu 'printf "A etc/x\nM etc/y\nD etc/z\n"'
run_nas version
assert_eq 3 "$(cat /run/mountnas/unsaved)" "unsaved count"

finish
