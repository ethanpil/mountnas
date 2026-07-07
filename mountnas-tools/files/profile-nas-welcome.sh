[ -t 1 ] || return 0
ver=$(/usr/libexec/mountnas/release-string 2>/dev/null || echo "?")
[ -n "$ver" ] || ver="?"
printf '\n  MountNAS %s — changes live in RAM until: nas commit\n' "$ver"
case "$(cat /run/mountnas/data 2>/dev/null)" in
	fresh)        printf '  >> No data disk yet. Add it to /etc/fstab, then: nas commit\n' ;;
	disconnected) printf '  >> DATA DISK NOT FOUND. Services held. Run: nas status\n' ;;
	mountfail)    printf '  >> DATA DISK FAILED TO MOUNT. Services held. Run: nas status\n' ;;
	netfs)        printf '  >> DATA DISK IS A NETWORK FS (unsupported). Services held. Run: nas status\n' ;;
esac
if command -v lbu >/dev/null 2>&1; then
	n=$(lbu status 2>/dev/null | grep -c .); [ "${n:-0}" -gt 0 ] && printf '  >> %s unsaved change(s): nas commit\n' "$n"
fi
printf '  Type `nas help` for commands and paths.\n\n'
# First boot: start the setup wizard automatically until it has completed once
# (root, interactive terminal, no root password set yet, no setup-done marker).
# Aborting (Ctrl-C) just returns to the shell; it offers again at the next login,
# and 'nas setup' stays manually re-runnable at any time.
if [ "$(id -u 2>/dev/null)" = 0 ] && [ ! -e /etc/mountnas/setup-done ] && [ -t 0 ] \
	&& awk -F: '$1=="root"{exit ($2!="")}' /etc/shadow 2>/dev/null; then
	printf '  First boot detected — starting the setup wizard (Ctrl-C to skip).\n\n'
	nas setup
fi
