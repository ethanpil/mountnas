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
# bash-only, sourced (no shebang, so discovery skips it): lint as bash. The
# zsh completion (files/zsh-nas-completion) is zsh syntax — shellcheck cannot
# lint zsh; it ships as data.
shellcheck -s bash -S warning -e SC2034 mountnas-tools/files/bash-nas-completion.sh
echo "shellcheck: all shipped scripts pass ($(printf '%s\n' $files | wc -l | tr -d ' ') shebang scripts + profile.d + completion + scripts/)"

# Guard the CONTEXT.md §6 landmine (which shellcheck cannot see — it lives
# inside workflow YAML): the big build step runs inside a single-quoted
# `su … -c '…'` block, where ANY stray apostrophe — even a paired one in a
# comment like «'abuild checksum'» — terminates the quote early and the rest
# of the block runs as root with mangled quoting. The ONLY legitimate
# apostrophes in the block are the intentional '"$VAR"' injections; strip
# those, then flag any apostrophe that remains.
awk -v q="'" '
	index($0, "su build -s /bin/sh -c " q) { inblk=1; next }
	inblk && $0 ~ "^[[:space:]]*" q "$" { inblk=0; next }
	inblk {
		line=$0
		gsub(q "\"\\$[A-Za-z_][A-Za-z0-9_]*\"" q, "", line)
		if (index(line, q)) { printf "build.yml:%d: apostrophe inside the su -c block:\n  %s\n", FNR, $0; bad=1 }
	}
	END { exit bad+0 }
' .github/workflows/build.yml || { echo "FAIL: apostrophe inside the su -c block truncates it (see CONTEXT.md §6)"; exit 1; }
echo "build.yml su -c block: no stray apostrophes"
