# bash tab completion for the nas CLI (installed as /etc/profile.d/nas-completion.sh).
# busybox ash sources every /etc/profile.d/*.sh too and parses function bodies
# eagerly, so the bash-only array syntax hides inside eval: ash sees only a
# quoted string and returns before it would run. zsh users get the compdef in
# /usr/share/zsh/site-functions/_nas instead.
[ -n "${BASH_VERSION:-}" ] || return 0
eval '
_nas_complete() {
	local cur prev
	cur=${COMP_WORDS[COMP_CWORD]}
	prev=${COMP_WORDS[COMP_CWORD-1]}
	case "$prev" in
	# command list: keep in sync with the dispatcher in files/nas AND the zsh
	# compdef (files/zsh-nas-completion)
	nas)             COMPREPLY=($(compgen -W "about backup changed changes commit disks help history log logs notify reboot report restart rollback save setup shutdown snapraid status ttyd upgrade version web" -- "$cur")) ;;
	status)          COMPREPLY=($(compgen -W "--deep --json" -- "$cur")) ;;
	web|ttyd|snapraid) COMPREPLY=($(compgen -W "on off status" -- "$cur")) ;;
	history)         COMPREPLY=($(compgen -W "-n --all" -- "$cur")) ;;
	notify)          COMPREPLY=($(compgen -W "--test" -- "$cur")) ;;
	disks)           COMPREPLY=($(compgen -W "--json" -- "$cur")) ;;
	changes|changed) COMPREPLY=($(compgen -W "--diff" -- "$cur")) ;;
	commit|save)     COMPREPLY=($(compgen -W "-m" -- "$cur")) ;;
	rollback)        COMPREPLY=($(compgen -W "--list" -- "$cur")) ;;
	backup)          COMPREPLY=($(compgen -W "--to" -- "$cur")) ;;
	--to)            COMPREPLY=($(compgen -d -- "$cur")) ;;
	logs|log)        COMPREPLY=($(compgen -W "-f -n --persist" -- "$cur")) ;;
	--persist)       COMPREPLY=($(compgen -W "on off status" -- "$cur")) ;;
	upgrade)         COMPREPLY=($(compgen -W "--check --yes" -- "$cur") $(compgen -f -- "$cur")) ;;
	reboot|shutdown) COMPREPLY=($(compgen -W "--yes --save" -- "$cur")) ;;
	help)            COMPREPLY=($(compgen -W "setup status disks restart changes commit save rollback backup logs log web ttyd snapraid history notify report shutdown reboot upgrade version about" -- "$cur")) ;;
	esac
}
complete -F _nas_complete nas
'
