#!/bin/sh
# run.sh — unit tests for the nas CLI, run under busybox ash on Alpine.
#
# The tests install the repo's mountnas-tools files at their REAL paths
# (/usr/sbin/nas, /usr/libexec/mountnas/...) and write real config files
# (/etc/fstab, /cfg/...). They must therefore run in a THROWAWAY root:
#
#   in a container (CI does this with the Actions 'container:' key):
#     docker run --rm -v "$PWD:/repo" alpine:3.24 sh /repo/tests/unit/run.sh
#
#   on any Alpine host with apk and network (no docker needed):
#     sh tests/unit/run.sh --chroot        # builds a root under /tmp, chroots
#
# Without --chroot the script refuses to run unless it can see that it is
# inside a container (/.dockerenv, or MOUNTNAS_UNIT_THROWAWAY=1 to override
# when you know the root is disposable).
#
# Hardware and the Alpine services are replaced by stubs on PATH (see
# harness.sh); the shell, awk, jq and the file logic are real.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
files="$repo/mountnas-tools/files"

if [ "${1:-}" = "--chroot" ]; then
	[ "$(id -u)" = 0 ] || { echo "--chroot needs root"; exit 1; }
	command -v apk >/dev/null || { echo "--chroot needs apk (an Alpine host)"; exit 1; }
	ver=$(cut -d. -f1,2 /etc/alpine-release)
	root=$(mktemp -d /tmp/nas-unit.XXXXXX)
	trap 'umount "$root/proc" 2>/dev/null; rm -rf "$root"' EXIT
	echo "building a throwaway Alpine v$ver root in $root ..."
	apk -q -X "https://dl-cdn.alpinelinux.org/alpine/v$ver/main" -U --allow-untrusted \
		--root "$root" --initdb add alpine-base busybox jq util-linux
	mkdir -p "$root/repo" "$root/proc"
	cp -a "$repo/mountnas-tools" "$repo/tests" "$root/repo/"
	mount -t proc proc "$root/proc"
	MOUNTNAS_UNIT_THROWAWAY=1 chroot "$root" /bin/sh /repo/tests/unit/run.sh
	exit $?
fi

[ -f /.dockerenv ] || [ "${MOUNTNAS_UNIT_THROWAWAY:-0}" = 1 ] || {
	echo "refusing: this installs files under /usr and /etc. Run in a container,"
	echo "or 'run.sh --chroot' on an Alpine host, or set MOUNTNAS_UNIT_THROWAWAY=1."
	exit 1
}
[ -f /etc/alpine-release ] || { echo "refusing: the tests need busybox ash on Alpine"; exit 1; }
command -v jq >/dev/null || apk add -q jq util-linux

# ---- install the CLI tree exactly as the APKBUILD does ----
install -Dm755 "$files/nas" /usr/sbin/nas
install -Dm644 "$files/lib.sh" /usr/libexec/mountnas/lib.sh
for c in "$files"/cmd/*.sh; do
	install -Dm644 "$c" "/usr/libexec/mountnas/cmd/$(basename "$c")"
done
for h in notify release-string data-watch smartd-notify health-digest; do
	install -Dm755 "$files/$h" "/usr/libexec/mountnas/$h"
done
install -Dm644 "$files/logo" /usr/share/mountnas/logo
mkdir -p /usr/share/mountnas
echo 9.9.9 > /usr/share/mountnas/version
echo unit-test > /usr/share/mountnas/release

# ---- run every test file in its own shell ----
pass=0; fail=0; failed=""
for t in "$here"/test_*.sh; do
	name=$(basename "$t" .sh)
	if out=$(sh "$t" 2>&1); then
		pass=$((pass + 1)); printf 'ok   %s\n' "$name"
		printf '%s\n' "$out" | grep -E '^  (ok|FAIL) ' || true
	else
		fail=$((fail + 1)); failed="$failed $name"; printf 'FAIL %s\n' "$name"
		printf '%s\n' "$out" | sed 's/^/     /'
	fi
done
echo "unit tests: $pass file(s) passed, $fail failed${failed:+ ($failed )}"
[ "$fail" = 0 ]
