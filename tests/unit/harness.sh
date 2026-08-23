# shellcheck shell=sh
# harness.sh — sourced by every tests/unit/test_*.sh. Plain sh, no bats.
#
#   t "name"                 start a test case
#   stub <cmd> '<body>'      put a fake <cmd> on PATH (body is sh; "$@" are its args)
#   run_nas <args...>        run /usr/sbin/nas; sets OUT (stdout+stderr) and RC
#   run_nas_in <stdin> <args...>   same, with text on stdin (prompt answers)
#   src_nas                  source lib.sh + cmd/*.sh into THIS shell (use in a
#                            subshell: functions under test run in-process)
#   assert_eq <want> <got> [msg]      assert_match <regex> <text> [msg]
#   assert_nomatch <regex> <text>     assert_rc <want>   (checks $RC)
#   fail <msg>               mark the current case failed
#   finish                   print the summary; exit 1 if any case failed
#
# Every test file runs in its own process; stubs are per file. The root is
# throwaway (see run.sh), so tests write the real config paths directly.
set -u
STUBS=$(mktemp -d)
PATH="$STUBS:$PATH"; export PATH
export NO_COLOR=1 TERM=dumb
STATE=/run/mountnas; CFG=/cfg; DATA=/mnt/nasdata
mkdir -p "$STATE" "$CFG" "$DATA" /etc/apk/protected_paths.d /etc/conf.d /etc/mountnas
: > /etc/apk/protected_paths.d/lbu.list

_case=""; _pass=0; _fail=0
t() {
	_end_case
	_case=$1
}
# The marker FILE is the only record of a failure: a 'fail' inside a
# ( subshell ) cannot set a variable in this shell.
_end_case() {
	[ -n "$_case" ] || return 0
	if [ -e "$STUBS/.failed" ]; then
		rm -f "$STUBS/.failed"; _fail=$((_fail + 1)); printf '  FAIL %s\n' "$_case"
	else
		_pass=$((_pass + 1)); printf '  ok   %s\n' "$_case"
	fi
	_case=""
}
fail() { : > "$STUBS/.failed"; printf '       %s\n' "$*"; }

stub() {
	printf '#!/bin/sh\n%s\n' "$2" > "$STUBS/$1"; chmod 755 "$STUBS/$1"
}

run_nas() {
	OUT=$(/usr/sbin/nas "$@" 2>&1 </dev/null); RC=$?
	return 0
}
run_nas_in() {   # $1 = stdin text (a prompt answer), rest = nas args
	_in=$1; shift
	OUT=$(printf '%s\n' "$_in" | /usr/sbin/nas "$@" 2>&1); RC=$?
	return 0
}
src_nas() {
	. /usr/libexec/mountnas/lib.sh
	# shellcheck disable=SC1090  # the cmd files are linted by ci-lint
	for _f in /usr/libexec/mountnas/cmd/*.sh; do . "$_f"; done
}

assert_eq() {
	[ "$1" = "$2" ] || fail "${3:-assert_eq}: want [$1] got [$2]"
}
assert_match() {
	printf '%s\n' "$2" | grep -qE -- "$1" || fail "${3:-assert_match}: /$1/ not in:
$(printf '%s\n' "$2" | sed 's/^/         | /')"
}
assert_nomatch() {
	if printf '%s\n' "$2" | grep -qE -- "$1"; then
		fail "${3:-assert_nomatch}: /$1/ found in output"
	fi
}
assert_rc() {
	[ "$RC" = "$1" ] || fail "${2:-assert_rc}: want rc=$1 got rc=$RC
$(printf '%s\n' "$OUT" | sed 's/^/         | /')"
}
finish() {
	_end_case
	printf '  %d passed, %d failed\n' "$_pass" "$_fail"
	rm -rf "$STUBS"
	[ "$_fail" = 0 ]
}
