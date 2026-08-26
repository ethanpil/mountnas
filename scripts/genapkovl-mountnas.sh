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
# The list comes from scripts/mkworld.sh — the single source shared with the
# world.base step in build.yml. Do not inline a package list here: world and
# world.base must stay identical or 'nas upgrade' injects unresolvable packages
# (see the NOTE in mkworld.sh about bare 'linux-firmware').
sh "$(dirname "$0")/mkworld.sh" | mk root:root 0644 "$tmp/etc/apk/world"

echo "$HOSTNAME" | mk root:root 0644 "$tmp/etc/hostname"

# ---- apk repositories: local on-media repo + pinned CDN repos ----
# The CDN repos are pinned to this build's CONCRETE Alpine version (e.g. v3.24),
# NOT latest-stable: that symlink moves on a new Alpine release and would
# silently mix next-release packages into this base. 'nas upgrade' re-pins the
# version from the new image's alpine.base marker. The local media repo stays
# first so the curated set resolves offline. With no detectable version
# (non-Alpine build host), ship the CDN lines commented out as before.
ALPINE_VER="${ALPINE_VER:-$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null || true)}"
if [ -n "$ALPINE_VER" ]; then
	mk root:root 0644 "$tmp/etc/apk/repositories" <<EOF
/run/mountnas/apks
https://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VER/main
https://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VER/community
EOF
else
	mk root:root 0644 "$tmp/etc/apk/repositories" <<'EOF'
/run/mountnas/apks
#https://dl-cdn.alpinelinux.org/alpine/latest-stable/main
#https://dl-cdn.alpinelinux.org/alpine/latest-stable/community
EOF
fi

# ---- apk cache on the config partition: user-added packages persist ----
# /cfg/cache sits next to the apkovl on MNASCFG (the standard Alpine diskless
# cache spot), so every .apk a user installs is kept across reboots. The
# mountnas service creates the directory once /cfg is mounted and re-syncs the
# installed set to /etc/apk/world from this cache at each boot.
mkdir -p "$tmp/etc/apk"
ln -sfn /cfg/cache "$tmp/etc/apk/cache"

# ---- fstab: config partition + commented data-disk guidance ----
mk root:root 0644 "$tmp/etc/fstab" <<'EOF'
# /etc/fstab — MountNAS
#
# Config partition (your saved settings live here). DO NOT REMOVE.
# Found by label, so it survives a reformat:  mkfs.ext4 -L MNASCFG ...
LABEL=MNASCFG  /cfg  ext4  rw,noatime,nofail  0 0
#
# ===================  YOUR DATA DISKS  ===================
# Storage is configured HERE, in fstab. Add disks, then run:  nas commit
# Always use  nofail  (a missing disk never hangs boot). MountNAS auto-creates
# each /mnt/* mountpoint before mounting — no need to mkdir the target first.
# Find UUIDs + a paste-ready line:  nas disks
#
# System disk (Docker data-root, appdata, backups) — REQUIRED for Docker:
# UUID=xxxxxxxx-xxxx  /mnt/nasdata  ext4  rw,noatime,nofail  0 2
#
# Or keep nasdata in a subdirectory of a mounted disk (bind mount; list the disk
# first, then: mkdir -p /mnt/disk1/nasdata). Use a bind mount, NOT a symlink.
# UUID=xxxxxxxx-xxxx  /mnt/disk1    ext4  rw,noatime,nofail  0 2
# /mnt/disk1/nasdata  /mnt/nasdata  none  bind,nofail        0 0
#
# SnapRAID data + parity (optional). Keep /mnt/nasdata OUT of the array.
# (The /mnt/disk1, /mnt/parity1 names are a convention — use any paths you like.)
# UUID=...  /mnt/disk1    xfs  rw,noatime,nofail  0 2
# UUID=...  /mnt/parity1  xfs  rw,noatime,nofail  0 2
#
# After editing, check it before rebooting:  nas status
EOF

# drivetemp: SATA disk temperatures via hwmon (read by 'nas disks' without
# waking drives — it checks the power state first). NVMe needs no module.
mk root:root 0644 "$tmp/etc/modules" <<'EOF'
fuse
ntfs3
drivetemp
EOF

mk root:root 0400 "$tmp/etc/doas.conf" <<'EOF'
permit persist :wheel
EOF

# ---- zram: compressed swap in RAM, on by default ----
# Diskless means the whole OS unpacks into tmpfs; a zram swap device lets the
# kernel keep the cold pages (firmware blobs, idle binaries) compressed at
# ~3:1, which is what gives low-RAM boxes real headroom. conf.d is sourced as
# shell by OpenRC, so the size computes from the box's actual RAM at boot.
# zstd backend is built into Alpine's lts kernel (ZRAM_BACKEND_ZSTD=y).
mk root:root 0644 "$tmp/etc/conf.d/zram-init" <<'EOF'
# MountNAS zram swap — you own this file (edit, then: nas commit).
# One compressed-RAM swap device; cold pages compress ~3:1, so this ADDS
# usable memory rather than consuming it. Turn off with size0=0 (or
# rc-update del zram-init boot), then nas commit.
#
# Never stop this service at shutdown/reboot. The init script's stop() runs
# swapoff, which must decompress EVERY stored page back into RAM before the
# device can be released — on a box that is tight enough to have filled its
# zram (exactly the box this feature exists for) that either stalls the
# shutdown for a long time or invokes the OOM killer, and if the OOM killer
# takes openrc then mount-ro never runs and /cfg is left dirty for the next
# boot. Nothing is lost by skipping it: swap holds volatile pages of a
# RAM-resident OS that the power-off discards anyway. (OpenRC reads
# rc_keyword from conf.d — see _depend() in rc-functions.sh; '-shutdown' is
# documented in openrc-run(8). This does NOT affect a manual
# 'rc-service zram-init stop', which still tears the device down properly.)
rc_keyword="-shutdown"
load_on_start=yes
unload_on_stop=yes
num_devices=1
type0=swap
flag0=          # empty = top swap priority (16383); use "-" for the default (-1)
algo0=zstd
# half of physical RAM, computed at boot (value in MB)
size0=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 2048 ))
EOF

# ---- ufw: shipped DISABLED (the image is fully open — README "Firewall") ----
# The service lives in the boot runlevel permanently so that 'ufw enable' +
# 'nas commit' is ALL a user does: rules then load before networking at every
# boot, and there is no "enabled in config but never loads after reboot"
# trap. The init script (Gentoo lineage) treats the disabled state as a start
# FAILURE by default, which would paint every boot of the shipped-open image
# with a red openrc line — this flag makes disabled a quiet success instead.
mk root:root 0644 "$tmp/etc/conf.d/ufw" <<'EOF'
# MountNAS: a disabled firewall (the shipped default) is a quiet no-op at
# boot, not a service failure. You own this file (edit, then: nas commit).
ufw_nonfatal_if_disabled=yes
EOF

# ---- conf.d/mountnas: the data-service switch ----
# Ships with the setting COMMENTED OUT on purpose: the supervisor's built-in
# default then stays authoritative, so a future release that adds a data
# service still reaches boxes whose owner never edited this file. Seeding it
# at all is a DISCOVERABILITY fix — the variable was documented only in the
# README, the web guide and the init script's header, so anyone browsing
# /etc/conf.d/ (where ufw and zram-init do appear) found no trace of the one
# switch they were most likely looking for.
mk root:root 0644 "$tmp/etc/conf.d/mountnas" <<'EOF'
# MountNAS data services — you own this file (edit, then: nas commit).
#
# SCOPE: this setting governs ONLY the three storage-gated services —
# docker, samba and nfs. Those are the ones the 'mountnas' supervisor holds
# back until /mnt/nasdata is actually mounted, which is why they need a
# switch of their own: they sit in NO runlevel, so 'rc-update del' does
# nothing for them, and 'apk del' is undone by the next 'nas upgrade' (its
# world reconciliation restores the base package set).
#
# EVERY OTHER SERVICE (sshd, smartd, avahi-daemon, crond, chronyd, ufw,
# zram-init, ...) is an ordinary runlevel service — naming it below does
# NOTHING. Disable those the standard Alpine way instead:
#   rc-service <name> stop && rc-update del <name> default && nas commit
#
# Uncomment the line below and list ONLY the data services you KEEP.
#   "samba nfs" = no Docker      "samba" = Samba only      "" = none at all
#
#DATA_SERVICES="samba nfs"
#
# Then stop whatever you dropped and apply:
#   rc-service docker stop && nas restart && nas commit
# (stop it yourself first — the supervisor only manages what is listed, so
# it will not stop a service you just removed from the list. A reboot does
# the same job.)
#
# Commented out or unset = the built-in default: docker samba nfs
# An explicitly empty list means EMPTY — no data services start. If this
# file is unreadable or has a syntax error the built-in default applies
# instead, so a typo can never silently stop your shares.
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

# ---- snapraid-maint: gated nightly sync + scrub (SPEC-snapraid-maint.md) ----
# 'nas snapraid schedule' turns it on. The runner also writes this file with
# these same defaults when it is absent (upgraded boxes never see this seed).
mk root:root 0644 "$tmp/etc/mountnas/snapraid-maint.conf" <<'EOF'
# snapraid-maint — you own this file (edit, then: nas commit).
DEL_THRESHOLD=100       # block sync above this many deleted files (0 = no gate)
UPD_THRESHOLD=200       # block sync above this many updated files (0 = no gate)
SCRUB_PERCENT=7         # scrub the oldest N% of blocks after a clean sync (0 = off)
SCRUB_OLDER_DAYS=10     # scrub only blocks not checked in N days
NOTIFY=problems         # problems | always | never
EOF

# ---- smartd: monitor all disks WITHOUT waking spun-down drives ----
# The stock smartmontools DEVICESCAN polls every 30 min with no power-state
# check, which keeps NAS data disks spinning 24/7. '-n standby,q' skips the
# poll while a disk is spun down ('q' silences the skip messages) — matching
# the care 'nas status' takes to never wake disks.
# Trouble is routed through the notification sinks BY DEFAULT (-M exec): the
# notify helper is a silent no-op with no sinks configured, so this costs an
# unconfigured box nothing — and once a user adds a sink to notify.conf,
# SMART pre-failure alerts (the single most valuable alert a NAS sends) work
# without a second config step in a different file.
mk root:root 0644 "$tmp/etc/smartd.conf" <<'EOF'
# MountNAS smartd defaults — you own this file (edit, then: nas commit).
# -n standby,q : never wake a spun-down disk just to poll SMART.
# -M exec routes SMART trouble through your notification sinks
#   (/etc/mountnas/notify.conf) — a silent no-op until a sink is configured
#   there. The -m address is required by smartd's syntax whenever -M exec is
#   used; it is ignored (delivery happens through the sinks).
# For classic direct email instead: configure /etc/msmtprc (README "Email
# alerts"), then replace the line with:
#   DEVICESCAN -n standby,q -m you@example.com
DEVICESCAN -n standby,q -m root -M exec /usr/libexec/mountnas/smartd-notify
EOF

# smartd's DEFAULT is to EXIT when DEVICESCAN finds no SMART-capable device —
# OpenRC then reports "crashed", and every status check logs a daemon.err
# line. A box on USB enclosures (or a VM) has exactly zero such devices, so
# ship '-q never': smartd stays up, idle, and picks devices up on reload.
mk root:root 0644 "$tmp/etc/conf.d/smartd" <<'EOF'
# MountNAS: keep smartd RUNNING when no SMART-capable device exists (USB
# enclosures, VMs). Without this smartd exits and OpenRC reports "crashed".
command_args="-q never"
EOF

# ---- outbound mail: mail(1) -> msmtp -> your SMTP relay ----
# smartd's warning script (and anything else) calls mail(1); /etc/mail.rc
# points it at msmtp. Both spellings are set because mailx flavors differ on
# the variable name — unknown 'set' variables are ignored harmlessly.
mk root:root 0644 "$tmp/etc/mail.rc" <<'EOF'
# Wire mail(1) to msmtp (send-only SMTP; configure /etc/msmtprc first).
set sendmail=/usr/bin/msmtp
set mta=/usr/bin/msmtp
EOF

# Disk-loss alert recipient: when this file holds an address (and msmtprc is
# configured), the 15-minute data-watch emails on data-disk disconnect/dead
# mount/read-only transitions. SMART pre-failure alerts are separate: the -m
# address in /etc/smartd.conf. (Kept for compatibility — notify.conf below is
# the richer mechanism; this address is treated as one more email sink.)
mk root:root 0644 "$tmp/etc/mountnas/alert-email" <<'EOF'
# MountNAS disk-loss alerts — you own this file (edit, then: nas commit).
# Put ONE email address on a line by itself to enable alert mails from the
# data-disk watcher (requires /etc/msmtprc to be configured first).
# Prefer /etc/mountnas/notify.conf — it takes email AND push sinks; an
# address here keeps working as one more email sink.
# you@example.com
EOF

# ---- notification sinks: alerts beyond email (ntfy/webhook/slack/...) ----
# Every alert (disk loss, SMART trouble via smartd-notify, failed upgrades,
# health digests, 'nas notify') fans out to ALL sinks listed here — the
# /usr/libexec/mountnas/notify helper is the single delivery path. No sinks
# configured = alerts silently off; nothing to tend.
mk root:root 0644 "$tmp/etc/mountnas/notify.conf" <<'EOF'
# MountNAS notification sinks — you own this file (edit, then: nas commit).
# One sink per line as  type:target  — every alert goes to ALL active sinks.
# Test your setup with:  nas notify --test
#
#   email:you@example.com                        (needs /etc/msmtprc configured)
#   ntfy:https://ntfy.sh/your-secret-topic
#   webhook:https://example.com/hook             (generic JSON POST: title/message/host)
#   slack:https://hooks.slack.com/services/...   (Slack/Mattermost-compatible)
#   discord:https://discord.com/api/webhooks/...
#   gotify:https://gotify.example.com/message?token=...
EOF

# msmtprc holds an SMTP password once configured -> mode 0600, root-owned.
mk root:root 0600 "$tmp/etc/msmtprc" <<'EOF'
# MountNAS outbound mail (msmtp) — you own this file (edit, then: nas commit).
# Fill in your SMTP relay below, then test with:
#   echo test | mail -s "MountNAS test" you@example.com
# Keep this file mode 0600 — it holds a password.
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

# account        default
# host           smtp.example.com
# port           587
# from           nas@example.com
# user           nas@example.com
# password       CHANGE-ME
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
# on untrusted networks. 'nas setup' flips PermitEmptyPasswords to 'no'
# automatically once a root password is set (only while the line below is still
# the shipped default). Tighten further yourself, e.g.:
#   PermitRootLogin prohibit-password
#   PasswordAuthentication no
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

# ---- avahi: publish <hostname>.local on the LAN, NOT the docker bridge ----
# By default avahi advertises the hostname's A record on EVERY interface,
# including docker0 (172.17.0.1) once Docker is running — so a LAN client
# resolving <host>.local can get an address only reachable on the box itself
# (verified: avahi-browse published docker0, eth0 AND lo; avahi-resolve
# returned the docker0 address first). Deny the default docker bridge so
# discovery returns the real LAN address. A minimal file is enough — avahi
# defaults every other setting.
mk root:root 0644 "$tmp/etc/avahi/avahi-daemon.conf" <<'EOF'
[server]
# Do not advertise <hostname>.local on the Docker bridge (unreachable off the
# box). Add custom docker network bridges (br-xxxxxxxx) here, comma-separated,
# if you create them and see .local resolving to the wrong address.
deny-interfaces=docker0
EOF

# ---- motd: drop Alpine's stock 'setup-alpine' recommendation ----
# Post-login guidance comes from /etc/profile.d/nas-welcome.sh, so keep motd empty.
mk root:root 0644 "$tmp/etc/motd" <<'EOF'
EOF

# ---- default locale (musl-locales) ----
# /etc/profile is alpine-baselayout's file; it sources /etc/profile.d/*.sh,
# and a locale.sh here is the Alpine-documented way to set the default.
# Seed config (user-owned, lbu-persisted) — edit and 'nas commit' to change.
mk root:root 0644 "$tmp/etc/profile.d/locale.sh" <<'EOF'
# Default locale (musl-locales provides the translations).
# Edit to taste, then: nas commit
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
EOF

# ---- issue: MountNAS placeholder so the very first pre-login screen is not
# Alpine's default. The mountnas-issue service runs gen-issue at boot, which
# repaints this with the ASCII logo + live IP. (/etc/issue is lbu-excluded.)
mk root:root 0644 "$tmp/etc/issue" <<'EOF'

  MountNAS - starting up...

  Log in as root, then run: nas setup

EOF

# ---- inittab: explicit gettys so BOTH consoles get a login prompt ----
# The kernel cmdline is `console=tty1 console=ttyS0`. We ship this so the Proxmox
# GRAPHICAL (noVNC / VGA) console gets a getty on tty1 AND the serial console
# (qm terminal / ttyS0) gets one too — the packaged default is not guaranteed to
# cover both. tty2-6 kept for bare-metal Alt-F2..F6.
# IMPORTANT: the console= devices MUST match the getty ids here (tty1, ttyS0). The
# diskless initramfs auto-appends a getty for any console= that has no inittab entry;
# a mismatch (e.g. console=tty0) appends a SECOND getty on the same VGA screen as the
# tty1 getty, and the two fight over input so login is impossible (see mkimg.nas.sh).
mk root:root 0644 "$tmp/etc/inittab" <<'EOF'
# /etc/inittab — MountNAS
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

# Virtual consoles (VGA / Proxmox noVNC / physical monitor)
tty1::respawn:/sbin/getty 38400 tty1
tty2::respawn:/sbin/getty 38400 tty2
tty3::respawn:/sbin/getty 38400 tty3
tty4::respawn:/sbin/getty 38400 tty4
tty5::respawn:/sbin/getty 38400 tty5
tty6::respawn:/sbin/getty 38400 tty6

# Serial console (qm terminal, IPMI SoL) — matches console=ttyS0,115200
ttyS0::respawn:/sbin/getty -L 0 ttyS0 vt100

::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF

mk root:root 0644 "$tmp/etc/lbu/lbu.conf" <<'EOF'
LBU_BACKUPDIR=/cfg
BACKUP_LIMIT=3
DEFAULT_CIPHER=aes-256-cbc
# ENCRYPTION=$DEFAULT_CIPHER
EOF

# ---- lbu include/exclude: the REAL mechanism ----
# lbu reads /etc/apk/protected_paths.d/lbu.list ("+path" = include in the
# committed overlay, "-path" = exclude/unprotect) — the same file 'lbu
# include'/'lbu exclude' maintain and apk audit honors natively. The plain
# /etc/lbu/{include,exclude} files shipped from alpha-1 through beta-2 were
# NEVER read by anything: /root, samba passwords, crontabs and VPN identities
# silently did not persist, and the excluded boot-generated files (/etc/issue)
# showed as unsaved changes forever. The mountnas service migrates old boxes.
mk root:root 0644 "$tmp/etc/apk/protected_paths.d/lbu.list" <<'EOF'
+usr/local/bin
+root
+var/lib/samba
+var/lib/zerotier-one
+var/lib/tailscale
+var/lib/netbird
+var/spool/cron/crontabs
-etc/profile.d/nas-welcome.sh
-etc/profile.d/nas-aliases.sh
-etc/profile.d/nas-prompt.sh
-etc/profile.d/nas-resize.sh
-etc/profile.d/nas-completion.sh
-etc/issue
-etc/network/if-up.d/mountnas-issue
-etc/periodic/15min/mountnas-datawatch
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
rc_add mountnas-mkdirs boot      # mkdir fstab mountpoints BEFORE localmount (no x-mount.mkdir)
rc_add localmount boot
rc_add networking boot
rc_add mountnas-net boot         # dynamic wired DHCP (from mountnas-tools)
rc_add ufw boot                  # firewall — quiet no-op until 'ufw enable' (conf.d/ufw); 'before net' loads rules pre-networking
rc_add mountnas-sshkey boot     # install SSH key from BOOT partition (before sshd)
rc_add zram-init boot            # compressed RAM swap (sized in conf.d/zram-init)
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
# Mesh VPNs are NOT baked in (prerelease decision, CONTEXT §12): install
# the one you use, then commit — it persists and now auto-starts at boot:
#   apk add tailscale tailscale-openrc   (or zerotier-one, or netbird netbird-openrc)
#   rc-update add tailscale default && rc-service tailscale start
#   tailscale up && nas commit
# rc_add nut-upsd default
# rc_add nut-upsmon default

rc_add mount-ro shutdown
rc_add killprocs shutdown
rc_add savecache shutdown

tar -c -C "$tmp" etc | gzip -9n > "$HOSTNAME.apkovl.tar.gz"
echo "wrote $HOSTNAME.apkovl.tar.gz"
