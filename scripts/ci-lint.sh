#!/bin/sh
# ci-lint.sh — shellcheck every shipped shell script (run from any cwd).
#
# The file list is DISCOVERED, not hand-maintained, so a newly added script can
# never be silently unlinted: everything under mountnas-tools/files/ with a
# sh/openrc-run shebang, every profile.d snippet (sourced, so shebang-less, hence
# the explicit glob), and scripts/*.sh (including this file).
#
# -s sh: every script must parse as POSIX sh (busybox ash on the device;
# CONTEXT.md §6 documents recurring ash-strictness bugs). -S warning: SC2015-style
# style notes are accepted idiom here. Excludes: SC2034 (openrc-run vars like
# description= look unused), SC3043 ('local' — supported by busybox ash),
# SC3045 ('read -s' — supported by busybox ash).
set -eu
cd "$(dirname "$0")/.."
files=$(grep -rlE '^#!/(bin/sh|sbin/openrc-run)' mountnas-tools/files)
# shellcheck disable=SC2086  # $files is a newline list of repo paths (no spaces)
shellcheck -s sh -S warning -e SC2034,SC3043,SC3045 \
	$files mountnas-tools/files/profile-*.sh scripts/*.sh
echo "shellcheck: all shipped scripts pass ($(printf '%s\n' $files | wc -l | tr -d ' ') shebang scripts + profile.d + scripts/)"
