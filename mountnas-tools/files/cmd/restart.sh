# shellcheck shell=sh
# nas restart
# Sourced by /usr/sbin/nas (never run directly). Shared helpers: lib.sh.

cmd_restart() {
	# Re-run the storage supervisor: re-mount data disks and (re)start
	# docker/samba/nfs, without rebooting. Handy after editing /etc/fstab.
	rc-service mountnas restart
	# OpenRC's `restart` restores the data services its own stop() stopped
	# mid-transition, so if the supervisor parked the data disk as an
	# unsupported network fs, it comes back with docker/samba still running.
	# Enforce "services held" out here — a stop in the CLI context (outside the
	# restart transition) sticks. (disconnected/mountfail deliberately leave
	# services up: those can be transient blips; a netfs system disk is a config
	# error, so its data services must be OFF.)
	if [ "$(cat "$STATE/data" 2>/dev/null)" = netfs ]; then
		# The restart restores these services ASYNCHRONOUSLY, so when it returns
		# a daemon may still be mid-start — a stop issued that early is missed and
		# it ends up running. For each, wait (bounded ~5s) for it to finish coming
		# up, THEN stop it. A service that never comes up (wasn't restored) just
		# waits out the loop and the stop is a harmless no-op.
		# Hold only what the supervisor manages: a service removed from
		# DATA_SERVICES (the supported disable/opt-out) is the user's to run —
		# stopping it here would kill a service mountnas does not own.
		rs_ds=$(_data_services)
		for s in $rs_ds; do
			i=0
			while ! rc-service "$s" status >/dev/null 2>&1 && [ "$i" -lt 20 ]; do
				sleep 0.25; i=$((i+1))
			done
			rc-service "$s" stop >/dev/null 2>&1 || true
		done
	fi
}

# help page for 'nas restart --help' / 'nas help restart'
help_restart() {
	cat <<EOF
nas restart
  Re-run the storage supervisor: mounts fstab data disks and (re)starts
  Docker/Samba/NFS without a reboot. Use after editing /etc/fstab.
EOF
}
