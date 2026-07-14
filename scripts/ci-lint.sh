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
# a shebang is by definition LINE 1 — grep -rl would also match scripts whose
# CONTENT quotes a shebang (web-guide.html embeds "#!/bin/sh" in a code
# example, and shellcheck then chokes trying to parse HTML)
files=$(for f in mountnas-tools/files/*; do
	[ -f "$f" ] || continue
	# `|| :` so a non-matching last file cannot fail the $() under set -e
	head -n1 "$f" | grep -qE '^#!/(bin/sh|sbin/openrc-run)' && printf '%s\n' "$f" || :
done)
[ -n "$files" ] || { echo "FAIL: shebang discovery found no scripts"; exit 1; }
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

# Guard the command-set drift shellcheck cannot see: the nas subcommands are
# enumerated in the dispatcher AND both shell completions, and 'changed' once
# silently drifted out of the completions. Extract the set from the main
# dispatcher case and require both completion lists to match it exactly.
cmds=$(awk 'index($0,"case \"${1:-help}\" in"){f=1;next} f&&/^esac$/{f=0} f' \
	mountnas-tools/files/nas \
	| grep -oE '^	[a-z][a-z|-]*\)' | tr -d '\t)' | tr '|' '\n' \
	| grep -vxE -- '--help|-h' | sort -u)
[ -n "$cmds" ] || { echo "FAIL: could not extract the command set from files/nas"; exit 1; }
bashcmds=$(sed -n '/nas)/s/.*compgen -W "\([^"]*\)".*/\1/p' \
	mountnas-tools/files/bash-nas-completion.sh | head -n1 | tr ' ' '\n' | grep . | sort -u)
zshcmds=$(sed -n 's/^cmds=(\(.*\))$/\1/p' \
	mountnas-tools/files/zsh-nas-completion | tr ' ' '\n' | grep . | sort -u)
cd_="$(mktemp)"; cb_="$(mktemp)"; cz_="$(mktemp)"
printf '%s\n' "$cmds" > "$cd_"; printf '%s\n' "$bashcmds" > "$cb_"; printf '%s\n' "$zshcmds" > "$cz_"
sync_ok=1
if ! diff "$cd_" "$cb_" >/dev/null; then
	echo "FAIL: bash completion out of sync with the nas dispatcher (< dispatcher / > completion):"
	diff "$cd_" "$cb_" || true; sync_ok=0
fi
if ! diff "$cd_" "$cz_" >/dev/null; then
	echo "FAIL: zsh completion out of sync with the nas dispatcher (< dispatcher / > completion):"
	diff "$cd_" "$cz_" || true; sync_ok=0
fi
rm -f "$cd_" "$cb_" "$cz_"
[ "$sync_ok" = 1 ] || { echo "sync files/bash-nas-completion.sh and files/zsh-nas-completion"; exit 1; }
echo "nas completions: in sync with the dispatcher ($(printf '%s\n' "$cmds" | grep -c .) commands)"
