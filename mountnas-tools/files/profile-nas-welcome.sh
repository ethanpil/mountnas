[ -t 1 ] || return 0
ver=$(cat /usr/share/mountnas/version 2>/dev/null || echo "?")
printf '\n  MountNAS %s — changes live in RAM until: nas commit\n' "$ver"
case "$(cat /run/mountnas/data 2>/dev/null)" in
	fresh)        printf '  >> No data disk yet. Add it to /etc/fstab, then: nas commit\n' ;;
	disconnected) printf '  >> DATA DISK NOT FOUND. Services held. Run: nas status\n' ;;
	mountfail)    printf '  >> DATA DISK FAILED TO MOUNT. Services held. Run: nas status\n' ;;
esac
if command -v lbu >/dev/null 2>&1; then
	n=$(lbu status 2>/dev/null | grep -c .); [ "${n:-0}" -gt 0 ] && printf '  >> %s unsaved change(s): nas commit\n' "$n"
fi
printf '  Type `nas help` for commands and paths.\n\n'
