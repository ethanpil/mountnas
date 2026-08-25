# shellcheck shell=sh
# nas help — the two-page overview
# Sourced by /usr/sbin/nas (never run directly). Shared helpers: lib.sh.

# nas help — two pages, each fitting an 80x24 serial console. Page 1: the
# commands, grouped by task. Page 2: the files you edit + recipes. On an
# interactive tty a 'more'-style any-key pause sits between them (q skips);
# pipes/CI get both pages flat so nothing ever hangs on a keypress.
_help_page1() {
	cat <<EOF
${C_B}MountNAS $RELEASE — control CLI${C_NO}
Subcommands — run as:  ${C_B}nas <command>${C_NO}      (e.g. nas status, nas disks)

${C_HD}Everyday${C_NO}
  ${C_B}status${C_NO}    Health + storage checks; exit 1 on failure   [--deep|--json]
  ${C_B}disks${C_NO}     Every disk: identity, partitions, fstab state       [--json]
  ${C_B}changes${C_NO}   List unsaved changes; --diff shows content  (alias: changed)
  ${C_B}commit${C_NO}    Save changes to the USB; label: -m "note"     (alias: save)
  ${C_B}logs${C_NO}      View the system log  [-n N | -f | --persist on|off|status]
  ${C_B}web${C_NO} / ${C_B}ttyd${C_NO} Dashboard + guide / browser terminal  [on [port]|off|status]

${C_HD}Recover${C_NO}
  ${C_B}rollback${C_NO}  Revert to a previous committed config        [--list | <n>]
  ${C_B}backup${C_NO}    Image the boot USB to a file (see UPGRADE.md)  [--to <dir>]
  ${C_B}restart${C_NO}   Re-mount disks + (re)start services (no reboot)
  ${C_B}history${C_NO}   Operations log: setups/commits/backups/upgrades   [-n N]

${C_HD}Maintain${C_NO}
  ${C_B}upgrade${C_NO}   Upgrade the OS from a release file/URL      [--check|--yes]
  ${C_B}notify${C_NO}    List/test alert sinks; send a message     [--test|<subject>]
  ${C_B}report${C_NO}    Diagnostics bundle for bug reports (status+logs, no secrets)
  ${C_B}setup${C_NO}     Guided setup (hostname, network, password, timezone)
${C_HD}Power${C_NO}  ${C_B}shutdown${C_NO} / ${C_B}reboot${C_NO} [--yes|--save]    ${C_HD}Info${C_NO}  ${C_B}about${C_NO} / ${C_B}version${C_NO} / ${C_B}help${C_NO}
${C_D}Per-command help: nas <command> --help${C_NO}  ${C_WA}Nothing persists until: nas commit${C_NO}
EOF
}
_help_page2() {
	cat <<EOF
${C_HD}Important files & paths${C_NO} (edit, then: nas commit)
  ${C_B}/etc/fstab${C_NO}               WHERE YOU CONFIGURE DISKS (add data disks here)
  ${C_B}/mnt/*${C_NO}                   Data-disk mountpoints ($DATA = system)
  ${C_B}/cfg${C_NO}                     Config partition — saved overlays live here
  ${C_B}/etc/samba/smb.conf${C_NO}      Samba shares    (add users: smbpasswd -a <user>)
  ${C_B}/etc/exports${C_NO}             NFS exports
  ${C_B}/etc/snapraid.conf${C_NO}       SnapRAID parity; mergerfs = fstab mount options
  ${C_B}/etc/docker/daemon.json${C_NO}  Docker   (data-root = $DATA/docker)
  ${C_B}/etc/conf.d/mountnas${C_NO}     DATA_SERVICES= — turn docker/samba/nfs off
  ${C_B}/etc/nut/${C_NO}                UPS: nut.conf, ups.conf, upsd.conf, upsmon.conf
  ${C_B}/etc/smartd.conf${C_NO}         SMART alerts;  /etc/chrony/chrony.conf time sync
  ${C_B}/etc/ssh/sshd_config${C_NO}     SSH;  /root/.ssh/authorized_keys = your keys
  ${C_B}/etc/ufw/${C_NO}                Firewall — OFF by default (README "Firewall")
  ${C_B}/var/lib/zerotier-one${C_NO}    ZeroTier;  /var/lib/tailscale  Tailscale state
  ${C_B}crontab -e${C_NO}               Scheduled jobs (e.g. SnapRAID sync/scrub)

${C_HD}Add a disk${C_NO}  (disk/parity names are a convention; snapraid.conf decides)
  1) nas disks             find the disk + copy its paste-ready fstab line
  2) edit /etc/fstab: UUID=<uuid> $DATA ext4 rw,noatime,nofail 0 2
  3) nas status   check it      4) nas restart   mount + start (no reboot)
  5) nas commit   persist it

  Install packages: apk add <pkg>   then: nas commit   (cached, offline)
  Grant admin rights: adduser <user> wheel        (then: nas commit)
EOF
}
cmd_help() {
	local k
	_help_page1
	if [ -t 0 ] && [ -t 1 ]; then
		printf '%s-- More: any key for files & guides (q to quit) --%s' "$C_D" "$C_NO"
		# -s so the keypress is not echoed (an echoed newline would move the
		# cursor off the pause line before the erase below could blank it)
		k=""; read -rs -n 1 k 2>/dev/null || k=""
		# blank the pause line so page 2 starts clean on the same row
		printf '\r%*s\r' 60 ''
		case "$k" in q|Q) return 0 ;; esac
	fi
	_help_page2
}
