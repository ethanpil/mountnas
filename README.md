# MountNAS

A diskless Alpine NAS that runs from RAM off a USB stick. Includes useful nas utilities and software baked into the image. The stick holds the OS and your configuration; your data lives on mounted drives. Includes a tool `nas` to help manage the system.

## Quick Start for Power Users

MountNAS is intended for power users, comfortable around a Linux system and commandline. If you read this quick start and are uncomfortable or unsure about what these commands do, or why they are needed, MountNAS is probably not for you. Perhaps [OMV](https://www.openmediavault.org/) or [Unraid](https://unraid.net/) are a better solution for you.

Get your system running by following these steps:

* Download a MountNAS release from GitHub:`mountnas-<tag>.img.gz`
* Write the image to a flash drive (min. 8 GB) using `gunzip -c mountnas-<tag>.img.gz | sudo dd of=/dev/sdX bs=4M status=progress` or a graphical utility like [Etcher](https://etcher.balena.io/).
* Boot your hardware from the flash drive and log in to the console as the `root` user with no password.
* Complete the automatic `nas setup` wizard to setup the root password, configure system timezone, and install your SSH public key.
* Identify your attached storage volumes and their respective identifiers by running `nas disks`.
* Partition and format blank data disks using tools such as `cfdisk` or `mkfs` or other [baked in tools](#baked-in-packages).
* Register your primary storage disk in `/etc/fstab` mapping to the explicit path `/mnt/nasdata` where application data, Docker structures, and configuration backups will live.
* Register any other storage in `/etc/fstab` as well.
* Test your configuration logic by running `nas status` to ensure no errors exist in your file system definitions.
* Initialize your storage attachment and start dependent services without a system restart by executing `rc-service mountnas restart`.
* Save your layout permanently back to the flash drive hardware by running `nas commit`.

## Critical Information

MountNAS runs entirely from RAM. Changes will not persist after reboot. This includes changes to configuration files, mount points, new packages, even changes to your password.
**To save changes, commit them to the USB with the `nas commit` command. (also aliased as `nas save`)** The `nas status` command attempts to track critical unsaved changes.

To prevent unexpected failures, the internal `mountnas` service supervises application states. Docker engine processes, Samba shares, and NFS exports are intentionally blocked from launching until the system verifies that your primary disk layout at `/mnt/nasdata` is successfully mounted.

If a drive is disconnected or fails to initialize, the supervisor mounts a read-only virtual system over the empty folder. This preventative measure guarantees that automated container workflows or remote transfers write metadata to a safe dead-end rather than filling up system memory and crashing the server.

- Mounted disks are intended to be mounted within `/mnt`
- You *must* create a mountpoint called `/mnt/nasdata` to hold application data, Docker config / containers, and backups.
- Never connect multiple USB keys with MountNAS simultaneously to the same machine.
- The `nas` is an easy and intuitive helper tool, built to help you manage MountNAS. Try `nas help` from the shell.
- The .img is for FIRST INSTALL ONLY. To update later use `nas upgrade` (see UPGRADE.md).
  - **Never re-write the image over a running NAS or you erase its config.**

## First boot

Log in as root (no password yet) — at the console or over SSH. `nas setup` runs automatically: root password, timezone, SSH key, then it saves. When it finishes you can start configuring your disks.

**Finding the box.** The console login screen shows the machine's current IP address and its `mountnas.local` name *before* you log in, so a monitor is all you need to find it. On networks with mDNS (most home/LAN setups) you can also just reach it at `mountnas.local` without knowing the IP — Avahi is on by default.

**Reaching a headless box on first boot (no monitor).** Two options, both work out of the box:

- **Passwordless SSH (default).** The shipped image permits root login over SSH with no password, so you can `ssh root@<ip>` (or `ssh root@mountnas.local`) and just press Enter at the password prompt. ⚠️ **This is insecure on an untrusted network.** Run `nas setup` to set a password and/or add a key, then tighten `/etc/ssh/sshd_config` (e.g. `PermitRootLogin prohibit-password`, `PasswordAuthentication no`, `PermitEmptyPasswords no`) and `nas commit`.
- **Pre-seed an SSH key (headless, recommended).** After flashing, drop your public key in a file named `authorized_keys` onto the FAT **BOOT** partition (readable from any OS). On every boot MountNAS installs those keys into `/root/.ssh`, so you can key in immediately. Once you've committed, you can delete the file and disable passwordless SSH as above.

## Adding your disks (TL;DR: Use /etc/fstab - like normal Linux)

Mounted disks are managed via the [fstab](https://en.wikipedia.org/wiki/Fstab) file located in `/etc/fstab`.

An example:

```text
UUID=example-uuid-string  /mnt/nasdata  ext4  rw,noatime,nofail  0 2

```
> **Getting the UUID:** a blank disk has no UUID until it's formatted. Partition and `mkfs` the disk first (e.g. `mkfs.ext4 -L nasdata /dev/sdX1`) — that creates the UUID — then read it with `blkid /dev/sdX1` (or `nas disks`) and paste it into the line above.

**IMPORTANT:** You *must* include the `nofail` option on all data volume entries within `/etc/fstab`. If a storage volume fails to initialize or is physically disconnected, the system will continue booting safely to a command prompt rather than hanging indefinitely during initialization. The `mountnas` service creates each `/mnt/*` mountpoint for you before mounting, so you do **not** need to `mkdir` the target first. (Do **not** use `x-mount.mkdir` — it is a util-linux option that busybox `mount` rejects at early boot.)

Additional notes:

* Use the `nas disks` command to list attached disks + UUIDs — it also prints a paste-ready fstab line for each unconfigured disk.
* Add your disks to `/etc/fstab`
  * Recommended: Mount each disk inside `/mnt`
* A mountpoint called `/mnt/nasdata` must exist to hold application data, Docker config / containers, and backups.
  * Recommended: A dedicated SSD disk
* Use the `nas status` command  to verify your configuration 
* Use `nas restart` to mount the disks and starts services, no reboot
 * Verify everything work and run `nas commit` to save the changes.

Always include `nofail`. Until /mnt/nasdata is mounted, Docker/Samba/NFS stay OFF on purpose, so a missing disk can never fill RAM. `nas status` shows the state and doubles as your pre-flight check after editing fstab.

## Keeping nasdata in a subdirectory of a mounted disk instead of its own dedicated disk
You can also have `/mnt/nasdata` live on a subdirectory of a mounted disk instead of a dedicated disk with a bind mount. In `/etc/fstab` with the real disk listed first:

```text
UUID=<disk1-uuid>   /mnt/disk1    ext4  rw,noatime,nofail  0 2
/mnt/disk1/nasdata  /mnt/nasdata  none  bind,nofail        0 0
```

Don't forget the one-time prep after `/mnt/disk1` is mounted:` mkdir -p /mnt/disk1/nasdata` (the `/mnt/nasdata` mountpoint itself is created for you).

## Parity

[SnapRAID](https://www.snapraid.it/) is baked into the image and simply needs to be configured.

* Mount your parity disks in `/etc/fstab` just like any other disk.
* Configure `/etc/snapraid.conf`
  * Keep `/mnt/nasdata` out of the array
* Schedule sync/scrub with `crontab -e`, then `nas commit`

**Unified pool (mergerfs):** [mergerfs](https://github.com/trapexit/mergerfs) IS included (as upstream's static binary). To pool several data disks into one mount, add a line like the following to `/etc/fstab` (after the member disks), then `nas status` and `nas commit`:

```text
/mnt/disk1:/mnt/disk2  /mnt/pool  fuse.mergerfs  nofail,allow_other,use_ino,category.create=mfs  0 0
```

SnapRAID and mergerfs complement each other: SnapRAID gives you parity, mergerfs gives you a single namespace. Keep `/mnt/nasdata` (the system disk) out of both.

## The MountNAS swiss army knife: `nas`

The `nas` tool has been designed to help you manage the system.

### Command Reference

| Command | Description |
| --- | --- |
| `nas setup` | Guided first-run setup: sets the root password and timezone, installs an optional SSH public key, then saves. |
| `nas status` | Health + storage-config check (fast, no disk spin-up): IP, RAM, config/data mount state, key services, unsaved-change count, plus fstab checks (UUIDs resolve, `nofail` present, no data path tracked by `lbu`, share/export paths land on real mounts). |
| `nas status --deep` | Everything `nas status` does **plus** SMART, SnapRAID status, and time-sync. Kept opt-in because SMART can wake sleeping disks and SnapRAID status is slow. (Alias: `nas checkup`.) |
| `nas disks` | Lists every detected disk with its UUID and mount state, marks the boot USB, shows how `/etc/fstab` maps it, and prints a paste-ready fstab line for each unconfigured data partition. |
| `nas validate` | Alias for `nas status` (the storage-config check). |
| `nas restart` | Re-mounts data disks and (re)starts Docker/Samba/NFS without rebooting (runs `rc-service mountnas restart`). Run it after editing `/etc/fstab`. |
| `nas commit` | Saves your in-RAM `/etc` changes to the USB config partition. Alias: `nas save`. |
| `nas backup` | Images the **whole boot USB** (OS + saved config) to a gzip file for upgrade/dead-USB recovery — default `/mnt/nasdata/backups`, or `--to <dir\|file>`. Copy it OFF this box. Does **not** include your data disks. |
| `nas upgrade` | Rewrites the OS on the USB **in place** from a release image (`mountnas-<tag>.img.gz`), then reboot. Requires a `nas backup` first (see `UPGRADE.md`). |
| `nas shutdown` | Powers off, warning first if you have unsaved changes. |
| `nas reboot` | Reboots, warning first if you have unsaved changes. |
| `nas version` | Shows the MountNAS version. |
| `nas help` | Command overview and important paths. |

## Included Services

These start automatically (unless noted). Docker, Samba, and NFS are held by the `mountnas` supervisor until `/mnt/nasdata` is mounted, so a missing disk can never fill RAM.

- **SSH** (`sshd`, on): see [First boot](#first-boot) for first-login access. Manage keys in `/root/.ssh/authorized_keys`, harden `/etc/ssh/sshd_config`, then `nas commit`.
- **mDNS / discovery** (`avahi`, on): reach the box at `mountnas.local` without knowing its IP.
- **Time sync** (`chronyd`, on): on an isolated LAN, point it at a local source in `/etc/chrony/chrony.conf`, then `nas commit`.
- **Network UPS Tools (NUT)** (`nut`, off by default): [Determine the UPS USB params](https://wiki.alpinelinux.org/wiki/Nut-ups) and update in `/etc/nut/`: `nut.conf`,`ups.conf`,`upsd.conf`, then `rc-update add nut-upsd` then nas commit`.
- **Docker** (started once `/mnt/nasdata` is up): data-root is `/mnt/nasdata/docker`. Put compose files and appdata under `/mnt/nasdata` so they survive a dead USB and travel with the data.
- **Samba** (started once `/mnt/nasdata` is up): edit `/etc/samba/smb.conf`, `smbpasswd -a <user>`, `rc-service samba restart`, `nas commit`.
- **NFS** (started once `/mnt/nasdata` is up): edit `/etc/exports`, `rc-service nfs restart`, `nas commit`.
- **Tailscale** (off by default): e.g. `rc-update add tailscale default && rc-service tailscale start && tailscale up && nas commit`.
- **ZeroTier** (off by default): baked in as a static build from [ethanpil/ZeroTierOne-AlpineLinux-Binaries](https://github.com/ethanpil/ZeroTierOne-AlpineLinux-Binaries). Enable with `rc-update add zerotier-one default && rc-service zerotier-one start`, then `zerotier-cli join <network-id>` and `nas commit` (node identity in `/var/lib/zerotier-one` is saved).
- **New admin user**: `adduser <name> wheel` (so `doas` works), then `nas commit`.

## Design Principles & Justifications

MountNAS is a *diskless, run-from-RAM* Alpine system: every boot the OS is rebuilt in RAM from packages plus a small config overlay on the USB. That single fact drives the unusual design below — each custom service/tool exists to work *with* that model, not against it.

- **Nothing persists until `nas commit`.** The root filesystem is tmpfs, so runtime changes vanish on reboot. `nas commit` (Alpine's `lbu`) saves `/etc` plus a short include list back to the USB. This is why every "…then `nas commit`" reminder exists.
- **Code ships in the apk; editable config ships in the overlay.** The overlay is applied *before* packages install, so your config files (`fstab`, `smb.conf`, `sshd_config`, …) are user-owned and survive, while the `nas` tools and services are shipped read-only by the `mountnas-tools` package. An apk can't persist your config — only the overlay can.
- **`mountnas` supervises data services.** Docker/Samba/NFS are deliberately *not* in any runlevel; the `mountnas` service starts them only once `/mnt/nasdata` is mounted, and drops a read-only placeholder over any disk that fails — so a missing disk can never silently fill RAM.
- **`mountnas-mkdirs` creates mountpoints before mounting.** fstab's `x-mount.mkdir` auto-create option is a util-linux feature that the busybox `mount` used at early boot rejects (`ext4: Unknown parameter 'x-mount.mkdir'`). Instead this service `mkdir`s every `/cfg` and `/mnt/*` target from fstab just before `localmount`. You *can't* simply `mkdir` + `nas commit` empty dirs: `/mnt` is kept out of `lbu` on purpose (committing it would tar your entire data disk into the tiny overlay), so mountpoints must be recreated from fstab each boot.
- **Small boot helpers.** `mountnas-net` brings up wired DHCP dynamically; `mountnas-sshkey` installs an `authorized_keys` file dropped on the BOOT partition (headless first login); `mountnas-issue` shows the live IP + hostname on the console *before* login; and the `nas-resize` profile snippet fixes terminal size on serial consoles (`qm terminal`, IPMI serial-over-LAN).
- **One image, in-place upgrades.** A single `.img.gz` is both the installer and the upgrade payload: `nas upgrade` rewrites the OS partition in place and `nas backup` images the whole USB as the rollback net — no A/B slots to reason about.

## Disk health (smartd) and UPS (nut)

smartd runs; add a notifier in /etc/smartd.conf then nas commit. nut is installed;
configure /etc/nut/*, enable nut-upsd + nut-upsmon, set SHUTDOWNCMD "/sbin/poweroff", nas commit.

## Firewall

None included as it is out of scope for this project. Secure at your router/LAN. Docker-published ports bypass host firewalls anyway.

## Recovery from a dead USB

MountNAS runs from RAM, so the USB is only read at boot — but if the stick itself fails,
you restore from a **full-image backup** made earlier with `nas backup`. Keep one off the
box (you're required to make one before every upgrade anyway — see [Upgrading](#upgrading)).

If your boot drive fails:

* Write your latest `nas backup` image (`mountnas-backup-*.img.gz`) to a new stick with
  Etcher or `dd` — it restores the OS **and** your saved config exactly as they were.
* Boot the new stick. **Do not** leave the failed stick attached — two MountNAS drives
  share the same disk labels and will collide.

No backup image yet? Write a fresh release image (`mountnas-<tag>.img.gz`) to a new stick
and reconfigure. Your data disks are untouched either way.

## Upgrading

MountNAS upgrades the OS **in place** on the boot USB (single-slot), using Alpine's
`copy-modloop` to safely swap the running system's files, then a reboot. Because a bad
upgrade on a headless box can leave it unbootable, `nas upgrade` **requires** a full-image
`nas backup` first — copied off the box.

See `UPGRADE.md` for the full step-by-step process, warnings, and recovery.

## Lost Root Password Recovery

Recovering a forgotten root password:

1. Pull the stick, plug into another Linux machine.
2. Mount the config partition: `mount LABEL=MNASCFG /mnt/x`
3. Unpack the overlay: `mkdir /tmp/ovl && tar -xzf /mnt/x/mountnas.apkovl.tar.gz -C /tmp/ovl`
4. Edit `/tmp/ovl/etc/shadow`  blank the root hash (turn `root:$6$...:...` into `root::...`), which restores the no-password console login you had on first boot.
5. Re-pack in place (as root, to keep perms): `tar -c -C /tmp/ovl etc | gzip -9n > /mnt/x/mountnas.apkovl.tar.gz`
6. umount `/mnt/x`, boot the stick, log in with no password, run `passwd` to set a new password, run `nas commit`.

## Troubleshooting

- Docker/Samba/NFS won't start -> `nas status` (almost always the data disk isn't mounted). Fix `/etc/fstab`, re-check with `nas status`, then `nas restart`.
- settings missing after reboot -> confirm `/cfg` is mounted (`nas status`) before `nas commit`.
- can't find the box -> try `mountnas.local` (mDNS/Avahi), or attach a monitor — the console shows the IP address above the login prompt before you log in.
- not reachable on the network -> on first boot MountNAS auto-writes a DHCP line for your wired NIC; check the cable/link. To customize (static IP, bond, bridge, VLAN) edit `/etc/network/interfaces` normally, `rc-service networking restart`, `nas commit` — MountNAS won't touch your config once you've set it.
- two clones in one machine -> don't; both answer to the config label (`MNASCFG`) by design.

## Baked in Packages

MountNAS includes a curated list of packages helpful to NAS users in the core OS image. 

__MountNAS Helper Utilities__

* mountnas-tools

__Core Shell / Base Utilities__
* bash
* coreutils
* findutils
* util-linux
* less
* file
* tree
* pv
* mc
* tmux
* nano
* lsof
* psmisc
* jq
* yq
* tzdata
* chrony
* acpid
* doas

__Disk Partitioning__

* parted
* gptfdisk
* cfdisk
* sfdisk

__Parity / Volume Management__

* snapraid (Built from source, not Alpine repo)
* mergerfs (Download static binary from GitHub release page)
* mdadm
* lvm2

__Disk Health / Recovery / Benchmarking__

* smartmontools
* nvme-cli
* hdparm
* lsscsi
* sg3_utils
* ddrescue
* fio

__Device Manager__

* eudev
* udev-init-scripts
* udev-init-scripts-openrc

__Networking / Transfer__

* curl
* wget
* rsync
* rclone
* openssh
* openssh-client
* openssh-sftp-server

__Overlay / Mesh VPN (services OFF by default)__

* tailscale
* zerotier-one

__Name Resolution / Discovery__

* avahi
* dbus

__File Sharing Servers__

* samba
* samba-client
* samba-common-tools
* nfs-utils

__Filesystems__

* e2fsprogs
* xfsprogs
* btrfs-progs
* f2fs-tools
* exfatprogs
* dosfstools
* ntfs-3g
* ntfs-3g-progs
* hfsprogs
* udftools
* fuse
* fuse3
* fuse-overlayfs

__Hardware Identification__

* pciutils
* usbutils
* dmidecode
* lshw
* lm-sensors
* lm-sensors-detect

__Network Diagnostics__

* ethtool
* iperf3
* tcpdump
* mtr
* bind-tools

__System Monitoring__

* btop
* iotop
* ncdu
* sysstat
* fastfetch

__Containers__

* docker
* docker-cli-compose

__UPS monitoring (NUT)__

* nut
* nut-openrc
* nut-udev

__Device Firmware__

* linux-firmware-amd
* linux-firmware-amdgpu
* linux-firmware-intel
* linux-firmware-realtek
* linux-firmware-mediatek
* linux-firmware-ath10k
* linux-firmware-ath11k
* linux-firmware-brcm
* linux-firmware-nvidia