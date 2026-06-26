case $- in *i*) ;; *) return 0 ;; esac
# Read-only: just print the cached count. No lbu, no subshell per prompt.
_nas_unsaved() {
	n=$(cat /run/mountnas/unsaved 2>/dev/null || echo 0)
	[ "${n:-0}" -gt 0 ] && printf '[unsaved:%s] ' "$n"
}
PS1='$(_nas_unsaved)\h:\w\$ '
