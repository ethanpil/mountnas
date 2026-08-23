# shellcheck shell=sh
# nas shutdown / nas reboot
# Sourced by /usr/sbin/nas (never run directly). Shared helpers: lib.sh.

_power() {
	local act word mode a n
	act="$1"; word="$2"; shift 2
	mode=ask
	for a in "$@"; do
		case "$a" in
			--yes)  mode=yes ;;    # scripted: proceed; unsaved changes are lost
			--save) mode=save ;;   # scripted: commit first, then proceed
			*) usage "nas $word [--yes|--save]"; return 1 ;;
		esac
	done
	case "$mode" in
	save)
		cmd_commit --no-ask || return 1 ;;
	yes)
		n=$(lbu status 2>/dev/null | grep -c .)
		[ "${n:-0}" -gt 0 ] && warn "$n unsaved change(s) will be LOST (use --save to commit first)" ;;
	*)
		n=$(lbu status 2>/dev/null | grep -c .)
		if [ "${n:-0}" -gt 0 ]; then
			echo "You have $n unsaved change(s)."
			printf 'Before %s: [S]ave / [D]iscard / [C]ancel: ' "$word"; read -r a
			case "$a" in S|s) cmd_commit --no-ask || return 1 ;; D|d) : ;; *) echo "Cancelled."; return 1 ;; esac
		fi ;;
	esac
	_ops_log "$word" "requested (mode: $mode)"
	# $act is always an absolute path (/sbin/poweroff|/sbin/reboot). exec of a
	# pathname bypasses shell aliases/functions, and this script is non-interactive
	# (never sources /etc/profile), so the reboot/poweroff aliases don't exist here
	# anyway — no recursion back into 'nas'. Quoted for hygiene.
	exec "$act"
}
cmd_shutdown() { _power "/sbin/poweroff" "shutdown" "$@"; }
cmd_reboot()   { _power "/sbin/reboot"   "reboot"   "$@"; }

# help page for 'nas shutdown' / 'nas reboot --help' / 'nas help shutdown'
help_shutdown() {
	cat <<EOF
nas $1 [--yes|--save]
  Power off / reboot. Interactive default warns about unsaved changes.
  --save   commit first, then proceed (fails if the commit fails)
  --yes    proceed without asking; unsaved changes are LOST
EOF
}
