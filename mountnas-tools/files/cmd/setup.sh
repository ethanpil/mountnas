# shellcheck shell=sh
# nas setup — first-run wizard
# Sourced by /usr/sbin/nas (never run directly). Shared helpers: lib.sh.

cmd_setup() {
	# One wizard at a time: on first boot BOTH consoles auto-start it (tty1 +
	# ttyS0 — on Proxmox noVNC and 'qm terminal' are commonly open together),
	# and two interleaved passwd/commit runs corrupt each other. mkdir is the
	# atomic test-and-set; /run is tmpfs, so a crash-stale lock clears at boot,
	# and the traps clear it on every normal or interrupted exit.
	mkdir -p "$STATE"
	if ! mkdir "$STATE/setup.lock" 2>/dev/null; then
		bad "another 'nas setup' is already running (on another console?)"
		hint "finish it there, or remove a stale lock: rmdir $STATE/setup.lock"
		return 1
	fi
	trap 'rmdir "$STATE/setup.lock" 2>/dev/null' EXIT
	trap 'rmdir "$STATE/setup.lock" 2>/dev/null; trap - EXIT HUP INT TERM; exit 130' HUP INT TERM

	hdr "MountNAS first-run setup"

	cur=$(hostname 2>/dev/null || echo mountnas)
	# bold wraps ONLY the [n/5] markers: the CI wizard drives a real tty, and
	# its expect patterns (Hostname [ / Timezone / HCP) must stay contiguous
	printf '%s[1/5]%s Hostname [%s]: ' "$C_B" "$C_NO" "$cur"; read -r hn
	[ -n "$hn" ] || hn="$cur"
	case "$hn" in
		*[!A-Za-z0-9-]*|-*|*-) warn "invalid hostname '$hn' (letters/digits/hyphens, no leading or trailing hyphen) — kept $cur"; hn="$cur" ;;
	esac
	printf '%s\n' "$hn" > /etc/hostname; hostname "$hn" 2>/dev/null; ok "hostname set to $hn"
	# make mDNS (<name>.local) and the console banner track the new name now,
	# not only after the next reboot
	rc-service --ifexists avahi-daemon restart >/dev/null 2>&1 || true
	/usr/libexec/mountnas/gen-issue 2>/dev/null || true

	printf '%s[2/5]%s Root password\n' "$C_B" "$C_NO"
	pw_ok=0; passwd && pw_ok=1
	# Set the timezone directly from the baked-in tzdata. We deliberately do NOT use
	# setup-timezone: it runs 'apk add tzdata', which fails offline (this appliance
	# has no internet repo and the on-media repo is not always mounted). tzdata ships
	# in the image, so /usr/share/zoneinfo/<tz> already exists.
	printf '%s[3/5]%s Timezone (e.g. America/New_York), blank to skip: ' "$C_B" "$C_NO"; read -r tz
	if [ -n "$tz" ]; then
		if [ -f "/usr/share/zoneinfo/$tz" ]; then
			cp "/usr/share/zoneinfo/$tz" /etc/localtime && printf '%s\n' "$tz" > /etc/timezone
			ok "timezone set to $tz"
		else
			warn "unknown timezone '$tz' — skipped (list them with: ls /usr/share/zoneinfo)"
		fi
	fi
	# Network: DHCP (default) leaves the mountnas-net first-boot handler to configure
	# the wired NIC. Static rewrites /etc/network/interfaces (lo + a static stanza),
	# which makes mountnas-net stand down (it only acts when no non-lo iface exists).
	printf '%s[4/5]%s Network: [D]HCP (default) / [S]tatic: ' "$C_B" "$C_NO"; read -r net
	case "$net" in
		S|s)
			# shared wired-NIC picker (same selection mountnas-net uses at boot)
			nic=$(/usr/libexec/mountnas/pick-nic 2>/dev/null) || nic=""
			[ -n "$nic" ] || nic=eth0
			printf '  Interface [%s]: ' "$nic"; read -r i; [ -n "$i" ] && nic="$i"
			printf '  IP address with prefix (e.g. 192.168.1.50/24): '; read -r addr
			printf '  Gateway (e.g. 192.168.1.1): '; read -r gw
			printf '  DNS server(s), space-separated (e.g. 1.1.1.1 8.8.8.8): '; read -r dns
			# shape-check before writing: a typo'd address written verbatim to
			# /etc/network/interfaces only surfaces when networking restarts —
			# potentially as a headless box that dropped off the network. Same
			# validate-or-keep-the-safe-default pattern as the hostname step.
			if [ -n "$addr" ] && ! printf '%s\n' "$addr" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; then
				warn "invalid address '$addr' (expected e.g. 192.168.1.50/24) — left networking on DHCP"
				addr=""
			fi
			if [ -n "$gw" ] && ! printf '%s\n' "$gw" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
				warn "invalid gateway '$gw' — skipped (add it to /etc/network/interfaces later)"
				gw=""
			fi
			if [ -n "$addr" ]; then
				{
					printf 'auto lo\niface lo inet loopback\n'
					printf '\nauto %s\n' "$nic"
					printf 'iface %s inet static\n' "$nic"
					printf '    address %s\n' "$addr"
					[ -n "$gw" ] && printf '    gateway %s\n' "$gw"
				} > /etc/network/interfaces
				if [ -n "$dns" ]; then
					: > /etc/resolv.conf
					for d in $dns; do printf 'nameserver %s\n' "$d" >> /etc/resolv.conf; done
				fi
				ok "static network set on $nic ($addr)"
				if confirm "  Apply it now? (restarts networking — an SSH session may drop)"; then
					rc-service networking restart >/dev/null 2>&1 \
						&& ok "networking restarted with the new address" \
						|| warn "networking restart failed — settings apply on next reboot"
				else
					echo "  It will apply on the next reboot."
				fi
			else
				warn "no IP entered — left networking on DHCP"
			fi
			;;
		*) ok "using DHCP (auto-configured at boot)" ;;
	esac

	# With a root password now set, close the shipped passwordless-SSH hole
	# (PermitEmptyPasswords yes exists only so a fresh headless box is reachable).
	# Touch the directive only while it is still the shipped default — a
	# user-edited sshd_config is never modified. PasswordAuthentication is left
	# alone on purpose: disabling it without a confirmed key would strand a
	# headless box.
	if [ "$pw_ok" = 1 ] && grep -q '^PermitEmptyPasswords yes$' /etc/ssh/sshd_config 2>/dev/null; then
		sed -i 's/^PermitEmptyPasswords yes$/PermitEmptyPasswords no/' /etc/ssh/sshd_config
		rc-service sshd restart >/dev/null 2>&1 || true
		ok "SSH empty-password login disabled (a root password is set now)"
	fi

	# Mark setup as completed so the first-login auto-run (profile.d/nas-welcome.sh)
	# stops offering the wizard. Written before the commit so it persists with it.
	mkdir -p /etc/mountnas
	date '+%Y-%m-%d %H:%M' > /etc/mountnas/setup-done
	_ops_log setup "wizard completed (hostname: $(hostname))"

	printf '%s[5/5]%s Saving...\n' "$C_B" "$C_NO"; cmd_commit --no-ask
	# "Setup complete" stays a contiguous literal (CI expects it)
	hdr "Setup complete"
	cat <<EOF
NEXT: add your data disk(s).
  1) nas disks                              (find your disk + its UUID)
  2) (blank disk?) mkfs.ext4 -L nasdata /dev/sdX
  3) edit /etc/fstab, add the system disk:
       UUID=<uuid>  /mnt/nasdata  ext4  rw,noatime,nofail  0 2
  4) nas status          (check it)
  5) rc-service mountnas restart    (mounts + starts services, no reboot)
  6) nas commit
EOF
}

# help page for 'nas setup --help' / 'nas help setup'
help_setup() {
	cat <<EOF
nas setup
  Guided first-run wizard: hostname, root password, timezone, network.
  Auto-runs at first login until completed once; safe to re-run any time.
EOF
}
