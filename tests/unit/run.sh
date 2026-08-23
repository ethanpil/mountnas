#!/bin/sh
# run.sh — unit tests for the nas CLI, run under busybox ash on Alpine.
#
# The tests install the repo's mountnas-tools files at their REAL paths
# (/usr/sbin/nas, /usr/libexec/mountnas/...) and write real config files
# (/etc/fstab, /cfg/...). They must therefore run in a THROWAWAY root:
#
#   in a container (the Lint workflow runs this command):
#     docker run --rm -v "$PWD:/repo" alpine:3.24 sh /repo/tests/unit/run.sh
#
#   on any Alpine host with apk and network (no docker needed):
#     sh tests/unit/run.sh --chroot        # builds a root under /tmp, chroots
#
# Without --chroot the script refuses to run unless it can see that it is
# inside a container. It looks for the marker file that docker (/.dockerenv)
# or podman (/run/.containerenv) creates. MOUNTNAS_UNIT_THROWAWAY=1 skips
# that marker check only. The script ALWAYS refuses a root that has MountNAS
# installed, runs from a modloop, or has /cfg mounted.
#
# Hardware and the Alpine services are replaced by stubs on PATH (see
# harness.sh); the shell, awk, jq and the file logic are real.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)

if [ "${1:-}" = "--chroot" ]; then
	[ "$(id -u)" = 0 ] || { echo "--chroot needs root"; exit 1; }
	command -v apk >/dev/null || { echo "--chroot needs apk (an Alpine host)"; exit 1; }
	ver=$(cut -d. -f1,2 /etc/alpine-release)
	# -P: /proc/mounts records the RESOLVED path. With a symlinked component
	# the guard below would compare two different strings and find no match.
	root=$(mktemp -d /tmp/nas-unit.XXXXXX)
	root=$(cd "$root" && pwd -P)
	cleanup() {
		# '|| :' on each: under 'set -e' a failed command in a trap stops the
		# REST of the trap, so an expected umount failure (nothing mounted yet)
		# used to skip the delete and keep the root.
		umount "$root/dev" 2>/dev/null || :
		umount "$root/proc" 2>/dev/null || :
		# Fail CLOSED. A delete that walks into a live mount destroys what the
		# mount points at, so "no evidence of a mount" is not good enough: we
		# delete only when we could READ the mount table and saw none.
		_m=$(cat /proc/mounts 2>/dev/null) || {
			echo "WARNING: cannot read /proc/mounts — not deleting $root" >&2
			return 0
		}
		case "$_m" in *" $root/"*)
			echo "WARNING: $root still has mounts — not deleting it" >&2
			return 0 ;;
		esac
		rm -rf "$root"
	}
	trap cleanup EXIT
	# busybox ash does NOT run an EXIT trap for an untrapped signal. Without
	# this line a cancelled CI job or a Ctrl-C leaves the mounts below in
	# place. Same pattern as cmd/upgrade.sh.
	trap 'cleanup; trap - EXIT HUP INT TERM; exit 130' HUP INT TERM
	echo "building a throwaway Alpine v$ver root in $root ..."
	# --keys-dir, NOT --allow-untrusted: the packages below run as root in the
	# chroot, so apk must verify their signatures. The host is Alpine (checked
	# above), so its keys are the correct trust anchor. apk copies them into
	# the new root with alpine-keys, and the in-chroot 'apk add' is verified too.
	apk -q -X "https://dl-cdn.alpinelinux.org/alpine/v$ver/main" -U \
		--keys-dir /etc/apk/keys \
		--root "$root" --initdb add alpine-base busybox jq
	mkdir -p "$root/repo" "$root/proc" "$root/dev"
	cp -a "$repo/mountnas-tools" "$repo/tests" "$root/repo/"
	mount -t proc proc "$root/proc"
	# A PRIVATE /dev, never a bind of the host's. 'apk --initdb' makes no
	# device nodes at all, and without /dev/null the first '>/dev/null'
	# CREATES a regular file: every later '2>/dev/null' fills it with error
	# text and every '</dev/null' reads that text back as stdin.
	#
	# A tmpfs is the right backing store. /tmp is usually 'nodev', which makes
	# a node created there unusable, but a fresh tmpfs mounts without nodev.
	# Binding the host's /dev would work too and is what this script did
	# first — but then a delete of the root that outlives a failed umount
	# destroys the HOST's device nodes. A private tmpfs cannot.
	mount -t tmpfs none "$root/dev"
	mknod -m 666 "$root/dev/null"    c 1 3
	mknod -m 666 "$root/dev/zero"    c 1 5
	mknod -m 666 "$root/dev/random"  c 1 8
	mknod -m 666 "$root/dev/urandom" c 1 9
	mknod -m 666 "$root/dev/tty"     c 5 0
	# the APKBUILD writes two files with 'install -Dm644 /dev/stdin'
	ln -s /proc/self/fd   "$root/dev/fd"
	ln -s /proc/self/fd/0 "$root/dev/stdin"
	ln -s /proc/self/fd/1 "$root/dev/stdout"
	ln -s /proc/self/fd/2 "$root/dev/stderr"
	MOUNTNAS_UNIT_THROWAWAY=1 chroot "$root" /bin/sh /repo/tests/unit/run.sh
	exit $?
fi

# These refusals are NOT overridable. They mark a root that someone works on
# or boots from, and this script installs a package over it and lets the tests
# write /etc/fstab, /etc/samba/smb.conf and /cfg. On a MountNAS box the tests
# would delete the active config overlay and every rollback snapshot.
[ ! -e /usr/sbin/nas ] || {
	echo "refusing: MountNAS is installed here — this is not a throwaway root."; exit 1; }
[ ! -d /.modloop ] || {
	echo "refusing: this root runs from a modloop (a live MountNAS/Alpine boot)."; exit 1; }
# /proc/mounts, not mountpoint(1): busybox has the applet but this must not
# depend on it, and an 'if' keeps the test clear of 'set -e'.
if grep -q ' /cfg ' /proc/mounts 2>/dev/null; then
	echo "refusing: /cfg is mounted — this looks like a MountNAS config partition."; exit 1
fi
# /.dockerenv = docker, /run/.containerenv = podman (which never writes the
# docker marker, not even through the podman-docker shim). MOUNTNAS_UNIT_THROWAWAY
# skips ONLY this marker check, never the three refusals above.
[ -f /.dockerenv ] || [ -f /run/.containerenv ] \
	|| [ "${MOUNTNAS_UNIT_THROWAWAY:-0}" = 1 ] || {
	echo "refusing: this installs files under /usr and /etc. Run in a container,"
	echo "or 'run.sh --chroot' on an Alpine host."
	exit 1
}
# Real device nodes, not regular files: a plain file at /dev/null silently
# turns every '2>/dev/null' into a log and every '</dev/null' into a replay
# of it. /dev/stdin is what the APKBUILD's version files are written through.
[ -c /dev/null ] || { echo "refusing: /dev/null is not a device node"; exit 1; }
[ -e /dev/stdin ] || { echo "refusing: /dev/stdin is missing"; exit 1; }
[ -f /etc/alpine-release ] || { echo "refusing: the tests need busybox ash on Alpine"; exit 1; }
command -v jq >/dev/null || apk add -q jq

# ---- install exactly what the apk installs ----
# The APKBUILD's package() is plain sh, so we RUN it instead of copying its
# install lines. A hand-copied list drifts: the first one already missed
# write-bootcfg, pick-nic and gen-issue, which the CLI calls by absolute
# path. pkgdir="" installs to this throwaway root. pkgver and _reltag must
# be set AFTER the source (which resets them) — the tests assert both
# strings. The extra files package() installs (init.d, profile.d, cron,
# web assets) are inert here: nothing starts a service or reads a profile.
startdir="$repo/mountnas-tools"
pkgdir=""
# package() installs file by file, so a cmd/<name>.sh the repo has since
# renamed would stay behind and the dispatcher's cmd/*.sh glob would source
# BOTH definitions. apk removes dropped files; this shim must do it too.
rm -rf /usr/libexec/mountnas/cmd
# shellcheck disable=SC1090  # path is computed; the APKBUILD is linted by ci-lint
. "$startdir/APKBUILD"
pkgver=9.9.9
_reltag=unit-test
package

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
