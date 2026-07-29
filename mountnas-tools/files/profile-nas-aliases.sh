case $- in *i*)
	alias reboot='nas reboot'
	alias poweroff='nas shutdown'
	alias shutdown='nas shutdown'

	# Guard rc-update for the storage-gated data services. They sit in NO
	# runlevel (the mountnas supervisor starts them once /mnt/nasdata is
	# mounted), so 'rc-update del docker' is a no-op whose only answer is a
	# bare "service docker is not in the runlevel default" that points
	# nowhere, and 'rc-update add' is actively wrong (nas status flags it).
	# Say what to do instead. A function, not an alias: it must read args.
	#
	# The managed set is read from the supervisor itself, so a data service
	# added in a future release is covered here with no edit. Interactive
	# shells only — scripts, doas and 'command rc-update' are untouched.
	rc-update() {
		local ds hit a s
		ds=$(sed -n 's/.*DATA_SERVICES-\([^}]*\)}.*/\1/p' /etc/init.d/mountnas 2>/dev/null | head -n1)
		[ -n "$ds" ] || ds="docker samba nfs"
		hit=""
		# only add/del are wrong for these; 'show' and every other service
		# must pass straight through
		case " $* " in
			*" add "*|*" del "*|*" delete "*)
				for a in "$@"; do
					for s in $ds; do
						[ "$a" = "$s" ] && hit=$a
					done
				done ;;
		esac
		[ -n "$hit" ] || { command rc-update "$@"; return $?; }
		printf '\n  %s is managed by the mountnas supervisor, not by a runlevel.\n' "$hit"
		printf '  It starts on its own once /mnt/nasdata is mounted, so there is\n'
		printf '  nothing here for rc-update to add or remove.\n\n'
		printf '  To turn it off, list only the data services you KEEP in\n'
		printf '  /etc/conf.d/mountnas (an empty list disables all of them):\n\n'
		printf '      rc-service %s stop\n' "$hit"
		printf '      nano /etc/conf.d/mountnas       # set DATA_SERVICES=\n'
		printf '      nas restart && nas commit\n\n'
		printf '  Details: nas help  |  README "Disabling Unused Services"\n'
		printf '  Meant it anyway?  command rc-update %s\n\n' "$*"
		return 1
	}
;; esac
