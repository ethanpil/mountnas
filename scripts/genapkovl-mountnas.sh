#!/bin/sh -e
# genapkovl-mountnas.sh <hostname>
# env: PACKAGES_LIST=/abs/packages.list

HOSTNAME="${1:-mountnas}"
: "${PACKAGES_LIST:?}"

cleanup() { rm -rf "$tmp"; }
mk() { mkdir -p "$(dirname "$3")"; cat > "$3"; chown "$1" "$3"; chmod "$2" "$3"; }
rc_add() { mkdir -p "$tmp/etc/runlevels/$2"; ln -sf "/etc/init.d/$1" "$tmp/etc/runlevels/$2/$1"; }
tmp="$(mktemp -d)"; trap cleanup EXIT

# ---- world (incl. our local apk) ----
{ echo alpine-base; sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$PACKAGES_LIST"; echo linux-firmware mkinitfs; } \
	| tr ' ' '\n' | sort -u | mk root:root 0644 "$tmp/etc/apk/world"

echo "$HOSTNAME" | mk root:root 0644 "$tmp/etc/hostname"

# ---- apk repositories: local on-media repo (bound by the mountnas service) ----
mk root:root 0644 "$tmp/etc/apk/repositories" <<'EOF'
/run/mountnas/apks
#https://dl-cdn.alpinelinux.org/alpine/latest-stable/main
#https://dl-cdn.alpinelinux.org/alpine/latest-stable/community
EOF

# ---- fstab: config partition + commented data-disk guidance ----
mk root:root 0644 "$tmp/etc/fstab" <<'EOF'
# /etc/fstab — MountNAS
#
# Config partition (your saved settings live here). DO NOT REMOVE.
# Found by label, so it survives a reformat:  mkfs.ext4 -L MNASCFG ...
LABEL=MNASCFG  /cfg  ext4  rw,noatime,nofail,x-mount.mkdir  0 0
#
# ===================  YOUR DATA DISKS  ===================
# Storage is configured HERE, in fstab. Add disks, then run:  nas commit
# Always use  nofail,x-mount.mkdir  (missing disk never hangs boot; dir auto-made).
# Find UUIDs:  nas disks   (or:  lsblk -o NAME,UUID,SIZE)
#
# System disk (Docker data-root, appdata, backups) — REQUIRED for Docker:
# UUID=xxxxxxxx-xxxx  /mnt/nasdata  ext4  rw,noatime,nofail,x-mount.mkdir  0 2
#
# SnapRAID data + parity (optional). Keep /mnt/nasdata OUT of the array.
# UUID=...  /mnt/disk1    xfs  rw,noatime,nofail,x-mount.mkdir  0 2
# UUID=...  /mnt/parity1  xfs  rw,noatime,nofail,x-mount.mkdir  0 2
#
# After editing, check it before rebooting:  nas validate
EOF

mk root:root 0644 "$tmp/etc/modules" <<'EOF'
fuse
EOF

mk root:root 0400 "$tmp/etc/doas.conf" <<'EOF'
permit persist :wheel
EOF

mk root:root 0644 "$tmp/etc/docker/daemon.json" <<'EOF'
{
  "data-root": "/mnt/nasdata/docker",
  "live-restore": true,
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF

mk root:root 0644 "$tmp/etc/samba/smb.conf" <<'EOF'
[global]
   workgroup = WORKGROUP
   server string = MountNAS
   security = user
   map to guest = bad user
   fruit:metadata = stream
   vfs objects = catia fruit streams_xattr

# [media]
#    path = /mnt/disk1/media
#    browseable = yes
#    writable = yes
#    valid users = @users
EOF

mk root:root 0644 "$tmp/etc/snapraid.conf" <<'EOF'
# You configure SnapRAID. Keep /mnt/nasdata (system disk) OUT of the array.
# parity /mnt/parity1/snapraid.parity
# content /mnt/nasdata/snapraid.content
# content /mnt/disk1/snapraid.content
# data d1 /mnt/disk1
# exclude *.unrecoverable
# exclude /tmp/
EOF

# ---- sshd: reachable on a fresh, headless box (you own this file) ----
# The default image PERMITS PASSWORDLESS ROOT LOGIN so a just-flashed box is
# reachable over SSH before 'nas setup' sets a password. This is INSECURE on an
# untrusted network: after first boot set a password and/or add a key, then
# tighten the directives below and run 'nas commit'. (Headless alternative: drop
# an 'authorized_keys' file on the BOOT partition — mountnas-sshkey installs it.)
mk root:root 0644 "$tmp/etc/ssh/sshd_config" <<'EOF'
# MountNAS sshd configuration — you own this file (edit, then: nas commit).
# Drop-in overrides may be placed in /etc/ssh/sshd_config.d/*.conf
Include /etc/ssh/sshd_config.d/*.conf

# Default: passwordless root login so a fresh headless box is reachable. INSECURE
# on untrusted networks — tighten after first boot, e.g.:
#   PermitRootLogin prohibit-password
#   PasswordAuthentication no
#   PermitEmptyPasswords no
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords yes

Subsystem sftp /usr/lib/ssh/sftp-server
EOF

# ---- network: lo only; mountnas-net handles wired DHCP dynamically ----
mk root:root 0644 "$tmp/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback
EOF

mk root:root 0644 "$tmp/etc/lbu/lbu.conf" <<'EOF'
LBU_BACKUPDIR=/cfg
BACKUP_LIMIT=3
DEFAULT_CIPHER=aes-256-cbc
# ENCRYPTION=$DEFAULT_CIPHER
EOF

mk root:root 0644 "$tmp/etc/lbu/include" <<'EOF'
usr/local/bin
root
var/lib/samba
var/lib/tailscale
var/spool/cron/crontabs
EOF

mk root:root 0644 "$tmp/etc/lbu/exclude" <<'EOF'
etc/profile.d/nas-welcome.sh
etc/profile.d/nas-aliases.sh
etc/profile.d/nas-prompt.sh
etc/issue
etc/network/if-up.d/mountnas-issue
EOF

# =====================  service enablement  =====================
rc_add devfs sysinit
rc_add dmesg sysinit
rc_add udev sysinit
rc_add udev-trigger sysinit
rc_add udev-settle sysinit
rc_add modloop sysinit

rc_add hwclock boot
rc_add modules boot
rc_add sysctl boot
rc_add hostname boot
rc_add bootmisc boot
rc_add syslog boot
rc_add localmount boot
rc_add networking boot
rc_add mountnas-net boot         # dynamic wired DHCP (from mountnas-tools)
rc_add mountnas-sshkey boot     # install SSH key from BOOT partition (before sshd)
rc_add seedrng boot
rc_add cgroups boot

rc_add udev-postmount default
rc_add dbus default
rc_add avahi-daemon default
rc_add sshd default
rc_add chronyd default
rc_add acpid default
rc_add crond default
rc_add rpcbind default          # for NFS server deps; harmless otherwise
rc_add smartd default
rc_add local default
rc_add mountnas-issue default    # console /etc/issue banner with the live IP
rc_add mountnas default         # storage guard + starts docker/samba/nfs when ready
# Data services are NOT in any runlevel — 'mountnas' starts them when storage is up.
# OFF by default (enable per host, then nas commit):
# rc_add tailscale default
# rc_add nut-upsd default
# rc_add nut-upsmon default

rc_add mount-ro shutdown
rc_add killprocs shutdown
rc_add savecache shutdown

tar -c -C "$tmp" etc | gzip -9n > "$HOSTNAME.apkovl.tar.gz"
echo "wrote $HOSTNAME.apkovl.tar.gz"
