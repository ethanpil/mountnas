#!/bin/sh
# nas upgrade: the argument gates, --check against a stubbed GitHub API, and
# the stage/commit file helpers. Nothing here touches a boot partition:
# every path stops before _mount_boot_rw.
# shellcheck disable=SC2089,SC2090  # GH_BODY holds literal JSON for the curl stub
. "$(dirname "$0")/harness.sh"
stub lbu ':'
stub mountpoint 'exit 1'

t "argument gates"
run_nas upgrade; assert_rc 1; assert_match 'usage: nas upgrade' "$OUT"
run_nas upgrade --bogus; assert_rc 1; assert_match 'usage: nas upgrade' "$OUT"
run_nas upgrade /nonexistent.img.gz; assert_rc 1; assert_match 'not found: /nonexistent.img.gz' "$OUT"

t "the YES gate: anything but uppercase YES aborts before any change"
: > /tmp/fake.img.gz
run_nas_in yes upgrade /tmp/fake.img.gz
assert_rc 1
assert_match 'UPGRADE WARNING' "$OUT"
assert_match 'Aborted — no changes made' "$OUT"
run_nas_in "" upgrade /tmp/fake.img.gz
assert_rc 1; assert_match 'Aborted' "$OUT"

t "an old recorded backup is called out"
printf '%s 2020-01-01 00:00\n' "$(( $(date +%s) - 200 * 86400 ))" > /etc/mountnas/last-backup
run_nas_in no upgrade /tmp/fake.img.gz
assert_match 'earlier session\): 2020-01-01 00:00  \(200 day\(s\) ago\)' "$OUT"
assert_match 'over 3 months old' "$OUT"
rm -f /etc/mountnas/last-backup /tmp/fake.img.gz

# --check: curl -w '%{http_code}' -o <file> ... — the stub writes the body
# from $GH_BODY to the -o target and prints $GH_CODE. The JSON in GH_BODY is
# data for the stub, so its quotes are meant literally (SC2089/SC2090 are
# disabled for the whole file, at the top).
stub curl 'out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
	[ -n "$out" ] && printf "%s" "$GH_BODY" > "$out"; printf "%s" "$GH_CODE"'

t "--check: up to date"
export GH_CODE=200 GH_BODY='{"tag_name":"unit-test","assets":[{"browser_download_url":"https://x/mountnas-unit-test.img.gz"}]}'
run_nas upgrade --check
assert_rc 0
assert_match '\[ OK \] up to date: MountNAS unit-test is the latest release' "$OUT"

t "--check: a newer release prints the exact upgrade command"
export GH_BODY='{"tag_name":"v2.0","assets":[{"name":"SHA256SUMS","browser_download_url":"https://x/SHA256SUMS"},{"browser_download_url":"https://x/mountnas-v2.0.img.gz"}]}'
run_nas upgrade --check
assert_rc 0
assert_match '\[WARN\] a different release is published: v2.0 \(running: unit-test\)' "$OUT"
assert_match '^    nas upgrade https://x/mountnas-v2.0.img.gz$' "$OUT"

t "--check: v-prefixed tag equal to the running release is up to date"
export GH_BODY='{"tag_name":"vunit-test","assets":[]}'
run_nas upgrade --check
assert_rc 0; assert_match 'up to date' "$OUT"

t "--check: API failures are distinct and non-zero"
export GH_CODE=404 GH_BODY=''
run_nas upgrade --check; assert_rc 1; assert_match 'repository is PRIVATE or has no releases' "$OUT"
export GH_CODE=403
run_nas upgrade --check; assert_rc 1; assert_match 'rate limit' "$OUT"
export GH_CODE=000
run_nas upgrade --check; assert_rc 1; assert_match 'cannot reach the GitHub API' "$OUT"
export GH_CODE=500
run_nas upgrade --check; assert_rc 1; assert_match 'GitHub API returned HTTP 500' "$OUT"
export GH_CODE=200 GH_BODY='{"message":"oops"}'
run_nas upgrade --check; assert_rc 1; assert_match 'no release found' "$OUT"

t "_stage_dir/_commit_dir: swap by rename, drop .old, restore on failure"
(
	src_nas
	w=$(mktemp -d); mkdir -p "$w/new/sub"; echo n > "$w/new/sub/f"; echo n2 > "$w/new/g"
	mkdir -p "$w/live"; echo o > "$w/live/old"
	_stage_dir "$w/new" "$w/live" || fail "_stage_dir failed"
	[ -f "$w/live.new/sub/f" ] || fail "staged tree missing"
	[ -f "$w/live/old" ] || fail "live tree touched during staging"
	_commit_dir "$w/live" || fail "_commit_dir failed"
	[ -f "$w/live/sub/f" ] && [ -f "$w/live/g" ] || fail "new tree not live"
	[ ! -e "$w/live/old" ] || fail "old content survived"
	[ ! -e "$w/live.old" ] && [ ! -e "$w/live.new" ] || fail ".old/.new left behind"
	# a missing source fails and leaves nothing staged
	_stage_dir "$w/absent" "$w/live" && fail "_stage_dir succeeded on a missing source"
	[ ! -e "$w/live.new" ] || fail "partial .new left after failure"
	_stage_file "$w/live/g" "$w/target"; _commit_file "$w/target"
	assert_eq n2 "$(cat "$w/target")"
	rm -rf "$w"
)

t "_free_modloop is a no-op when /lib/modules is not on the modloop"
(
	src_nas
	_free_modloop || fail "returned non-zero on a plain /lib/modules"
)

finish
