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
* Test your configuration logic by running `nas validate` to ensure no errors exist in your file system definitions.
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
UUID=example-uuid-string  /mnt/nasdata  ext4  rw,noatime,nofail,x-mount.mkdir  0 2

```
**IMPORTANT:** You *must* include the `nofail` and `x-mount.mkdir` options on all data volume entries within `/etc/fstab`. If a storage volume fails to initialize or is physically disconnected, the system will continue booting safely to a command prompt rather than hanging indefinitely during initialization.

Additional notes:

* Use the `nas disks` command to list attached disks + UUIDs.
* Add your disks to `/etc/fstab`
  * Recommended: Mount each disk inside `/mnt`
* A mountpoint called `/mnt/nasdata` must exist to hold application data, Docker config / containers, and backups.
  * Recommended: A dedicated SSD disk
* Use the `nas validate` command  to verify your configuration 
* Use `nas restart` to mount the disks and starts services, no reboot
 * Verify everything work and run `nas commit` to save the changes.

Always use nofail,x-mount.mkdir. Until /mnt/nasdata is mounted, Docker/Samba/NFS stay OFF on purpose, so a missing disk can never fill RAM. `nas status` shows the state; `nas validate` is your pre-flight check after editing fstab.

## Keeping nasdata in a subdirectory of a mounted disk instead of its own dedicated disk
You can also have `/mnt/nasdata` live on a subdirectory of a mounted disk instead of a dedicated disk with a bind mount. In `/etc/fstab` with the real disk listed first:

```text
UUID=<disk1-uuid>   /mnt/disk1    ext4  rw,noatime,nofail,x-mount.mkdir  0 2
/mnt/disk1/nasdata  /mnt/nasdata  none  bind,nofail,x-mount.mkdir        0 0
```

Don't forget the one-time prep after `/mnt/disk1` is mounted:` mkdir -p /mnt/disk1/nasdata`

## Parity

[SnapRAID](https://www.snapraid.it/) is baked into the image and simply needs to be configured.

* Mount your parity disks in `/etc/fstab` just like any other disk.
* Configure `/etc/snapraid.conf`
  * Keep `/mnt/nasdata` out of the array
* Schedule sync/scrub with `crontab -e`, then `nas commit`

**Unified pool (mergerfs):** [mergerfs](https://github.com/trapexit/mergerfs) IS included (as upstream's static binary). To pool several data disks into one mount, add a line like the following to `/etc/fstab` (after the member disks), then `nas validate` and `nas commit`:

```text
/mnt/disk1:/mnt/disk2  /mnt/pool  fuse.mergerfs  nofail,allow_other,use_ino,category.create=mfs,x-mount.mkdir  0 0
```

SnapRAID and mergerfs complement each other: SnapRAID gives you parity, mergerfs gives you a single namespace. Keep `/mnt/nasdata` (the system disk) out of both.

## The MountNAS swiss army knife: `nas`

The `nas` tool has been designed to help you manage the system.

### Command Reference

| Command | Description |
| --- | --- |
| `nas setup` | Guided first-run setup: sets the root password and timezone, installs an optional SSH public key, then saves. |
| `nas status` | Quick health glance: running slot, IP, RAM, config/data mount state, key services, and the unsaved-change count. |
| `nas disks` | Lists every detected disk and shows how `/etc/fstab` maps it. |
| `nas validate` | Pre-flight check of your storage config: UUIDs resolve, `nofail`/`x-mount.mkdir` present, no data path tracked by `lbu`, share/export paths land on real mounts. |
| `nas checkup` | Deep health: runs `validate` plus SMART, RAM, SnapRAID status, and time-sync. |
| `nas restart` | Re-mounts data disks and (re)starts Docker/Samba/NFS without rebooting (runs `rc-service mountnas restart`). Run it after editing `/etc/fstab`. |
| `nas commit` | Saves your in-RAM `/etc` changes to the USB config partition and copies a backup to the data disk. Alias: `nas save`. |
| `nas backup` | Copies the saved config to `/mnt/nasdata/backups`; add `--to <dest>` to also copy it off-box. |
| `nas restore` | Scans attached disks for config backups and restores the one you pick (dead-USB recovery); your fstab returns with it. |
| `nas upgrade` | Stages a new OS image into the inactive A/B slot, then `--finish` to finalize or `--rollback` to revert (see `UPGRADE.md`). |
| `nas shutdown` | Powers off, warning first if you have unsaved changes. |
| `nas reboot` | Reboots, warning first if you have unsaved changes. |
| `nas version` | Shows the MountNAS version and the running slot. |
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
- **Tailscale** (off by default): e.g. `rc-update add tailscale default && rc-service tailscale start && tailscale up && nas commit`. (ZeroTier isn't packaged in Alpine; Tailscale covers the same need.)
- **New admin user**: `adduser <name> wheel` (so `doas` works), then `nas commit`.

## Disk health (smartd) and UPS (nut)

smartd runs; add a notifier in /etc/smartd.conf then nas commit. nut is installed;
configure /etc/nut/*, enable nut-upsd + nut-upsmon, set SHUTDOWNCMD "/sbin/poweroff", nas commit.

## Firewall

None included as it is out of scope for this project. Secure at your router/LAN. Docker-published ports bypass host firewalls anyway.

## Recovery from a dead USB

The system duplicates your active settings file to the directory `/mnt/nasdata/backups` as part of the `nas commit` process.

If your boot drive experiences a hardware failure:

* Write a fresh image to a new stick and boot it.
* Make sure the disk holding your backups is attached.
* Run `nas restore`. You don't need to mount anything first — it scans every attached block device (mounting each read-only), lists the config backups it finds newest-first, and restores the one you pick. Your fstab comes back with it.
* `nas reboot` to apply.

Your data disks are untouched throughout.

## Upgrading 

MountNAS updates utilize an isolated dual-slot layout to protect against boot failures. 

For complete instructions regarding upgrade stages, validation steps, and system downgrades, please consult the  instructions inside `UPGRADE.md`.

## Lost Root Password Recovery

Recovering a forgotten root password:

1. Pull the stick, plug into another Linux machine.
2. Mount the config partition: `mount LABEL=MNASCFG /mnt/x`
3. Unpack the overlay: `mkdir /tmp/ovl && tar -xzf /mnt/x/mountnas.apkovl.tar.gz -C /tmp/ovl`
4. Edit `/tmp/ovl/etc/shadow`  blank the root hash (turn `root:$6$...:...` into `root::...`), which restores the no-password console login you had on first boot.
5. Re-pack in place (as root, to keep perms): `tar -c -C /tmp/ovl etc | gzip -9n > /mnt/x/mountnas.apkovl.tar.gz`
6. umount `/mnt/x`, boot the stick, log in with no password, run `passwd` to set a new password, run `nas commit`.

## Troubleshooting

- Docker/Samba/NFS won't start -> `nas status` (almost always the data disk isn't mounted). Fix `/etc/fstab`, `nas validate`, `nas restart`.
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

* snapraid
* mergerfs
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