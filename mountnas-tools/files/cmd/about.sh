# shellcheck shell=sh
# nas version / nas about
# Sourced by /usr/sbin/nas (never run directly). Shared helpers: lib.sh.

cmd_version() {
	if [ "$RELEASE" != "$VERSION" ]; then echo "MountNAS $RELEASE (build $VERSION)"
	else echo "MountNAS $VERSION"; fi
}

cmd_about() {
	[ -f /usr/share/mountnas/logo ] && cat /usr/share/mountnas/logo
	printf '\n                      %s\n\n' "$RELEASE"
	printf 'Diskless Alpine based NAS that runs from RAM off a USB stick.\n\n'
	printf 'http://mountnas.com\n'
}

# help page for 'nas version --help' / 'nas help version'
help_version() {
	echo "nas version — print the MountNAS release (and build id). No flags."
}

# help page for 'nas about --help' / 'nas help about'
help_about() {
	echo "nas about — logo, release, and project info. No flags."
}
