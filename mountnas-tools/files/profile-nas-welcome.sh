[ -t 1 ] || return 0
ver=$(/usr/libexec/mountnas/release-string 2>/dev/null || echo "?")
[ -n "$ver" ] || ver="?"
# same palette + gating as the `nas` CLI (this file already returned unless
# stdout is a tty); sourced by ash and bash, so vars are unset at the end
if [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then
	_wb=$(printf '\033[1m'); _wy=$(printf '\033[33m'); _wr=$(printf '\033[1;31m')
	_wd=$(printf '\033[2m'); _wn=$(printf '\033[0m')
else
	_wb=""; _wy=""; _wr=""; _wd=""; _wn=""
fi
printf '\n  %sMountNAS %s%s — changes live in RAM until: nas commit\n' "$_wb" "$ver" "$_wn"
case "$(cat /run/mountnas/data 2>/dev/null)" in
	fresh)        printf '  %s>> No data disk yet. Add it to /etc/fstab, then: nas commit%s\n' "$_wy" "$_wn" ;;
	disconnected) printf '  %s>> DATA DISK NOT FOUND. Services held. Run: nas status%s\n' "$_wr" "$_wn" ;;
	mountfail)    printf '  %s>> DATA DISK FAILED TO MOUNT. Services held. Run: nas status%s\n' "$_wr" "$_wn" ;;
	netfs)        printf '  %s>> DATA DISK IS A NETWORK FS (unsupported). Services held. Run: nas status%s\n' "$_wr" "$_wn" ;;
esac
if command -v lbu >/dev/null 2>&1; then
	n=$(lbu status 2>/dev/null | grep -c .); [ "${n:-0}" -gt 0 ] && printf '  %s>> %s unsaved change(s): nas commit%s\n' "$_wy" "$n" "$_wn"
fi
printf '  %sType `nas help` for commands and paths.%s\n\n' "$_wd" "$_wn"
# First boot: start the setup wizard automatically until it has completed once
# (root, interactive terminal, no root password set yet, no setup-done marker).
# Aborting (Ctrl-C) just returns to the shell; it offers again at the next login,
# and 'nas setup' stays manually re-runnable at any time.
if [ "$(id -u 2>/dev/null)" = 0 ] && [ ! -e /etc/mountnas/setup-done ] && [ -t 0 ] \
	&& awk -F: '$1=="root"{exit ($2!="")}' /etc/shadow 2>/dev/null; then
	printf '  %sFirst boot detected — starting the setup wizard (Ctrl-C to skip).%s\n\n' "$_wb" "$_wn"
	nas setup
fi
unset _wb _wy _wr _wd _wn
