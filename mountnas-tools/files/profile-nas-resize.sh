# Serial consoles (qm terminal, IPMI serial-over-LAN) cannot tell the shell the
# window size, so it defaults to 80x24 and full-screen apps (mc, btop, nano) wrap
# wrong. Ask the terminal for its real size (cursor-position report) and apply it.
# bash-only (needs the raw single-key read) and only on a real serial line — a
# no-op on the VGA/noVNC console and over SSH, where the size is already known.
case $- in *i*) ;; *) return 0 ;; esac
[ -n "$BASH_VERSION" ] || return 0
[ -t 0 ] && [ -t 1 ] || return 0

case "$(tty 2>/dev/null)" in
	/dev/ttyS*|/dev/ttyUSB*) ;;
	*) return 0 ;;
esac

_nas_resize() {
	local row col
	# save cursor, jump far bottom-right, ask where we landed, restore cursor.
	printf '\033[s\033[9999;9999H\033[6n\033[u'
	# reply is: ESC [ rows ; cols R  — split on [ ; R, stop reading at R (2s guard).
	IFS='[;R' read -rsd R -t 2 _ row col 2>/dev/null || return 0
	case "$row$col" in ''|*[!0-9]*) return 0 ;; esac
	[ "$row" -gt 0 ] 2>/dev/null && [ "$col" -gt 0 ] 2>/dev/null \
		&& stty rows "$row" cols "$col" 2>/dev/null
}
_nas_resize
unset -f _nas_resize 2>/dev/null
