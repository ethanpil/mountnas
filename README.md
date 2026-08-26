# MountNAS

A diskless Alpine NAS that runs from RAM off a USB stick. Includes useful nas utilities and software baked into the image. The stick holds the OS and your configuration; your data lives on mounted drives. Includes a tool `nas` to help manage the system.

## Quick Start for Power Users

MountNAS is intended for power users, comfortable around a Linux system and commandline. If you read this quick start and are uncomfortable or unsure about what these commands do, or why they are needed, MountNAS is probably not for you. Perhaps [OMV](https://www.openmediavault.org/) or [Unraid](https://unraid.net/) are a better solution for you.

Get your system running by following these steps:

* Hardware: any x86_64 box with **4 GB+ RAM — this is a floor, not a suggestion.** The OS and every package unpack into a RAM filesystem at each boot, and that filesystem is capped at half your RAM, so a 2 GB box cannot fit the system no matter how much swap it has. Compressed zram swap (on by default) buys headroom *above* the floor — it keeps a 4 GB box comfortable under Docker load — but it cannot lower it. The console warns at boot when RAM is below 4 GB.
* Download a MountNAS release from GitHub:`mountnas-<tag>.img.gz`
* Write the image to a flash drive (min. 4 GB) using `gunzip -c mountnas-<tag>.img.gz | sudo dd of=/dev/sdX bs=4M status=progress` or a graphical utility like [Etcher](https://etcher.balena.io/).
* Boot your hardware from the flash drive and log in to the console as the `root` user with no password.
* Complete the automatic `nas setup` wizard (it starts by itself at your first login) to set the hostname, root password, timezone, and network.
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
- A power cut discards everything you have not committed (changes live in RAM). Commit early and often; if unplanned power loss is a real risk for you, add a UPS — NUT is baked in (see below).

## First boot

Log in as root (no password yet) — at the console or over SSH. `nas setup` starts automatically at your first login (and keeps offering until completed once): hostname, root password, timezone, network, then it saves. When it finishes you can start configuring your disks. SSH keys are installed separately — drop an `authorized_keys` file on the BOOT partition (below) or manage `/root/.ssh/authorized_keys` yourself.

**Finding the box.** The console login screen shows the machine's current IP address and its `mountnas.local` name *before* you log in, so a monitor is all you need to find it. On networks with mDNS (most home/LAN setups) you can also just reach it at `mountnas.local` without knowing the IP — Avahi is on by default.

**Reaching a headless box on first boot (no monitor).** Two options, both work out of the box:

- **Passwordless SSH (default).** The shipped image permits root login over SSH with no password, so you can `ssh root@<ip>` (or `ssh root@mountnas.local`) and just press Enter at the password prompt. ⚠️ **This is insecure on an untrusted network.** Run `nas setup` — once it sets a root password it automatically disables empty-password SSH logins (`PermitEmptyPasswords no`). Tighten further in `/etc/ssh/sshd_config` if you use keys (e.g. `PermitRootLogin prohibit-password`, `PasswordAuthentication no`) and `nas commit`.
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

**Network filesystems (NFS/CIFS) in fstab are not mounted at boot.** MountNAS ships no `netmount` service, and the storage supervisor deliberately never mounts network filesystems (and refuses one as `/mnt/nasdata`) — a dead remote must never be able to hang the boot. If you need to consume remote storage, mount it manually (or from cron `@reboot`) once the box is up, or run the consumer inside Docker. Local disks are the supported storage path.

## Keeping nasdata in a subdirectory of a mounted disk instead of its own dedicated disk
You can also have `/mnt/nasdata` live on a subdirectory of a mounted disk instead of a dedicated disk with a bind mount. In `/etc/fstab` with the real disk listed first:

```text
UUID=<disk1-uuid>   /mnt/disk1    ext4  rw,noatime,nofail  0 2
/mnt/disk1/nasdata  /mnt/nasdata  none  bind,nofail        0 0
```

Don't forget the one-time prep after `/mnt/disk1` is mounted:` mkdir -p /mnt/disk1/nasdata` (the `/mnt/nasdata` mountpoint itself is created for you).

## Installing extra packages

`apk add <pkg>` works out of the box: the image ships with the Alpine **main** and
**community** repositories enabled (pinned to this release's Alpine version, so a
future Alpine release can't silently mix in newer packages) alongside the on-USB
package snapshot. After installing, run `nas commit` — the downloaded packages are
cached on the config partition and reinstall automatically at every boot, even with
no network. `nas upgrade` preserves your added packages and re-pins the repository
version to match the new release.

### Adding firmware for other hardware

The image ships GPU / wifi / Bluetooth / wired-NIC firmware for typical consumer
hardware of the last ~15 years (see [Baked in Packages](#baked-in-packages)) — but not
firmware for server NICs, ARM boards, or genuinely exotic devices. If something in your
box needs a blob that isn't included:

1. **Identify the missing file** — the kernel names it at boot:
   `dmesg | grep -iE 'firmware|failed to load'`
2. **Find the package that ships it** — `apk search linux-firmware` lists every vendor
   package, or search the file name at [pkgs.alpinelinux.org](https://pkgs.alpinelinux.org/contents).
3. **Install and persist it:** `apk add linux-firmware-<vendor>`, then `nas commit`,
   then reboot.

Added firmware is cached on the config partition and reinstalled **early** in every
boot — before devices are probed (verified) — so after that one reboot the device
simply works, network or not. Kernel *drivers* are a different thing and are already
all included with the kernel; it's only these device-firmware blobs that are curated.

## Parity

[SnapRAID](https://www.snapraid.it/) is baked into the image and simply needs to be configured.

* Mount your parity disks in `/etc/fstab` just like any other disk.
* Configure `/etc/snapraid.conf`
  * Keep `/mnt/nasdata` out of the array
* Run the first sync, then schedule nightly maintenance:

```text
nas snapraid run          # first sync (hours on a full array; use tmux)
nas snapraid schedule     # nightly gated sync + scrub at 02:00
nas commit
```

`nas snapraid` is more than a cron line. Before each sync it checks that
every array disk is mounted (an unmounted disk reads as "all files
deleted") and REFUSES to sync when the diff shows more than 100 deleted
or 200 updated files — the pattern of ransomware or a fat-fingered `rm`.
A blocked sync leaves parity holding yesterday's state, so `snapraid fix`
can still restore the files; if the change was intentional, run
`nas snapraid run --force-sync` once. After each clean sync it scrubs the
oldest 7% of parity blocks, so silent bit rot is found early. Blocked or
failed runs alert through your `nas notify` sinks. Thresholds live in
`/etc/mountnas/snapraid-maint.conf`; `nas snapraid status` shows the
array per disk, the schedule and the last run (`--deep` adds snapraid's
own statistics). Run history: `/mnt/nasdata/snapraid/logs`.

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
| `nas setup` | Guided first-run setup (starts automatically at first login until completed once): hostname, root password, timezone, network, then saves. |
| `nas status` | Health + storage-config check (fast, no disk spin-up): IP + `hostname.local`, RAM, sensors (CPU/disk temps, fans), config/data mount state, key services, firewall state, unsaved-change count, whether disk-loss email alerts are configured, plus fstab checks (UUIDs resolve, `nofail` present, nothing resolves to the boot USB, no data path tracked by `lbu`, share/export paths land on real mounts). **Exits 1 if any `[FAIL]` fired** (2 if check tracking itself was unavailable) — usable as a cron/monitoring probe. Tags are color-coded on a terminal. |
| `nas status --deep` | Everything `nas status` does **plus** SMART, SnapRAID status, fstab verify, and time-sync. Kept opt-in because SMART can wake sleeping disks and SnapRAID status is slow. |
| `nas status --json` | The same checks, machine-readable (state facts, per-service flags, ok/warn/fail counts and lines) for Uptime Kuma/Zabbix/Homepage integrations. Same exit-code contract. |
| `nas disks` | Hardware + partition inventory in a compact two-line-per-item layout that fits a serial console: a dashed header per disk (name, size, bus, HDD/SSD, temperature — read without waking sleeping drives), identity beneath (vendor, model, serial, firmware), then each partition with fstype/label/mount/free space and its UUID on its own line. Marks the boot USB, shows the fstab mapping, and prints a paste-ready fstab line per unconfigured partition, ending in a comment with the drive's model + serial. `--json` emits the same inventory machine-readable. |
| `nas restart` | Re-mounts data disks and (re)starts Docker/Samba/NFS without rebooting (runs `rc-service mountnas restart`). Run it after editing `/etc/fstab`. |
| `nas changes` | Lists exactly what `nas commit` would save (added/modified/deleted files); `--diff` shows the actual unified diffs against the committed overlay. Alias: `nas changed`. |
| `nas commit` | Saves your in-RAM `/etc` changes to the USB config partition. Run interactively it prompts for a note (Enter skips); `-m "note"` still works for scripts. Notes label the snapshots in `nas rollback --list`. Alias: `nas save`. |
| `nas rollback` | The config time machine: `--list` shows the previous committed overlays lbu keeps on `/cfg` (with the notes from `nas commit -m`); `nas rollback <n>` restores one (crash-safe swap, applies at the next boot, the replaced config stays available for rolling forward). |
| `nas logs` | View the system log (`-f` follows). `nas logs --persist on` moves syslog onto `/mnt/nasdata/logs` so a crash or power cut leaves history behind; rotation is automatic (1 MB × 10 files via syslogd — nothing to manage). Opt-in because periodic writes keep that disk awake. |
| `nas web` | The read-only LAN status dashboard + built-in user guide (off by default). `on [port]` enables it (default 8080), `off` disables, `status` reports the URL and whether the setting is saved. **Run `nas commit` after `on`/`off`** — like every setting it lives in RAM until committed, and the command warns when the current state wouldn't survive a reboot. Static files only — a background job re-renders the page into RAM every ~2 minutes and busybox httpd (as `nobody`) serves it: no request-time code, no disk writes. `/guide.html` is the full user guide baked into the release; `/status.json` feeds integrations. |
| `nas ttyd` | Browser-based terminal (off by default). `on [port]` enables it (default 22222), `off` disables, `status` reports the URL — same `nas commit` rule and warnings as `nas web`. Serves a **real login prompt** (never a bare shell) over plain HTTP on your trusted LAN — the password transits in cleartext, so treat it like Samba. Root login works: `on` adds `pts/*` entries to `/etc/securetty` once (busybox `login` refuses root on unlisted ttys otherwise). The dashboard links to it when running. |
| `nas snapraid` | Gated SnapRAID maintenance. `run` syncs + scrubs now and REFUSES past the delete/change thresholds (the ransomware guard — `--force-sync` overrides once); `schedule [HH:MM\|off]` manages the nightly cron line; `status [--deep]` shows the array per disk, the schedule and the last run's verdict. Settings in `/etc/mountnas/snapraid-maint.conf`; run history on the data disk; blocked/failed runs alert through your `nas notify` sinks. See [Parity](#parity). |
| `nas notify` | Notification sinks: with no arguments lists what's configured in `/etc/mountnas/notify.conf` (email, ntfy, webhook, Slack, Discord, gotify — one `type:target` per line); `--test` sends a test message to every sink; `nas notify "subject" [body]` sends ad-hoc messages from scripts/cron (body can be piped in). Disk-loss alerts, SMART trouble, and health digests fan out to all sinks. |
| `nas backup` | Images the **whole boot USB** (OS + saved config) to a gzip file for upgrade/dead-USB recovery — default `/mnt/nasdata/backups`, or `--to <dir\|file>`. Copy it OFF this box. Does **not** include your data disks. |
| `nas upgrade` | Rewrites the OS on the USB **in place** from a release image — a local `mountnas-<tag>.img.gz` or an `https://` release URL (verified against the release's `SHA256SUMS` when present) — then reboot. Requires a `nas backup` first (see `UPGRADE.md`). `nas upgrade --check` asks GitHub whether a newer release is published and prints the exact upgrade command. |
| `nas history` | The append-only operations log: every setup, commit (with its note), rollback, backup, upgrade, and shutdown/reboot — UTC timestamp, who ran it, outcome. Nothing to configure: it records silently to `/cfg/mountnas-ops.log` (the config partition), persists **without** `nas commit`, and self-trims. `-n N` / `--all` control how much you see. When you're wondering "what changed on this box?", start here. |
| `nas report` | Writes a diagnostics bundle (`/tmp/mountnas-report-*.tar.gz`) with status, logs, storage/service config, and the operations log for bug reports. No secrets (no shadow, ssh keys, or samba passwords) — but review before sharing. |
| `nas shutdown` | Powers off, warning first if you have unsaved changes. `--save` commits first; `--yes` skips the prompt (scripted use). |
| `nas reboot` | Reboots, with the same unsaved-changes gate and `--save`/`--yes` flags. |
| `nas version` | Shows the MountNAS release (and the build id). |
| `nas help` | Command overview and important paths; `nas <command> --help` gives focused usage + examples. Tab completion ships for bash and zsh. |

## Included Services

These start automatically (unless noted). Docker, Samba, and NFS are held by the `mountnas` supervisor until `/mnt/nasdata` is mounted, so a missing disk can never fill RAM.

- **SSH** (`sshd`, on): see [First boot](#first-boot) for first-login access. Manage keys in `/root/.ssh/authorized_keys`, harden `/etc/ssh/sshd_config`, then `nas commit`.
- **mDNS / discovery** (`avahi`, on): reach the box at `mountnas.local` without knowing its IP. The shipped `/etc/avahi/avahi-daemon.conf` denies the Docker bridge (`docker0`) so `.local` resolves to your LAN address, not the unreachable `172.17.x`; add custom docker network bridges (`br-…`) to the `deny-interfaces` line if you create them.
- **Time sync** (`chronyd`, on): on an isolated LAN, point it at a local source in `/etc/chrony/chrony.conf`, then `nas commit`.
- **Network UPS Tools (NUT)** (`nut`, off by default): [Determine the UPS USB params](https://wiki.alpinelinux.org/wiki/Nut-ups) and update in `/etc/nut/`: `nut.conf`,`ups.conf`,`upsd.conf`, then `rc-update add nut-upsd` then nas commit`.
- **Docker** (started once `/mnt/nasdata` is up): data-root is `/mnt/nasdata/docker`. Put compose files and appdata under `/mnt/nasdata` so they survive a dead USB and travel with the data.
- **Samba** (started once `/mnt/nasdata` is up): edit `/etc/samba/smb.conf`, `smbpasswd -a <user>`, `rc-service samba restart`, `nas commit`.
- **NFS** (started once `/mnt/nasdata` is up): edit `/etc/exports`, `rc-service nfs restart`, `nas commit`.
- **Browser terminal (ttyd)** (off by default): `nas ttyd on && nas commit` — a real login prompt at `http://<box>:22222/` (root works; `on` whitelists ptys in `/etc/securetty` once). Handy when SSH is awkward — a tablet, a borrowed machine, a quick look from the couch.
- **Mesh VPNs are not baked in** — install the one you use like any package; it persists across reboots and upgrades, and starts at every boot:
  - **Tailscale**: `apk add tailscale tailscale-openrc && rc-update add tailscale default && rc-service tailscale start && tailscale up && nas commit`
  - **ZeroTier**: not in Alpine's v3.24 repos — install from the testing repository: `apk add zerotier-one --repository=https://dl-cdn.alpinelinux.org/alpine/edge/testing`, then `rc-update add zerotier-one default && rc-service zerotier-one start && zerotier-cli join <network-id> && nas commit` (node identity in `/var/lib/zerotier-one` is saved)
  - **NetBird**: `apk add netbird netbird-openrc && rc-update add netbird default && rc-service netbird start && netbird up && nas commit`
- **Firewall (ufw)** (off by default): the image ships fully open. `ufw allow SSH && ufw enable && nas commit` to turn it on — see [Firewall](#firewall) first.
- **New admin user**: `adduser -s /bin/bash <name>`, then `adduser <name> wheel` (so `doas` works), then `nas commit`. (bash is the MountNAS default shell — root gets it automatically.)

## Disabling Unused Services

Every service can be turned off permanently — a NAS that only serves Samba doesn't need Docker's RAM, and every listener you stop shrinks the attack surface. Two mechanisms, depending on how the service is started:

**Data services (Docker, Samba, NFS)** are started by the `mountnas` supervisor, not a runlevel, so `rc-update del` does nothing for them. `/etc/conf.d/mountnas` ships on every box with the switch commented out and explained — uncomment `DATA_SERVICES` there and list **only what you keep**:

```sh
rc-service docker stop     # stop it now — see the note below
```

```sh
sed -i 's/^#DATA_SERVICES=/DATA_SERVICES=/' /etc/conf.d/mountnas   # or just edit the file
```

```sh
nas status                 # verify: docker now listed as disabled
```

```sh
nas commit                 # REQUIRED — the setting is RAM-only until committed
```

Some common values:

| Goal | Line |
| --- | --- |
| Keep Samba + NFS (no Docker) | `DATA_SERVICES="samba nfs"` |
| Keep Docker + NFS (no Samba) | `DATA_SERVICES="docker nfs"` |
| Keep Samba only | `DATA_SERVICES="samba"` |
| No data services at all | `DATA_SERVICES=""` |

**This switch covers only Docker, Samba, and NFS** — the three services the supervisor holds back until `/mnt/nasdata` is mounted. Everything else (`sshd`, `smartd`, `avahi-daemon`, `crond`, …) is an ordinary runlevel service and naming it here does nothing; disable those with `rc-update del` as described below.

**You do not need `rc-update del` for these three** — they're in no runlevel, so there's nothing to remove. If you try it anyway, MountNAS notices and prints this recipe instead of letting OpenRC answer with a bare "service is not in the runlevel" (that guard is interactive-shell only; scripts and `command rc-update` are untouched). The one-time `rc-service docker stop` above is only to stop what's *already running*: the supervisor manages what's *currently* listed, so once Docker is off the list `nas restart` won't stop a running Docker, it just stops managing it. A reboot does the same job. After that the supervisor simply never starts it again.

`nas status` (and the web dashboard) know about the override and won't warn about services you deliberately disabled — it lists them as disabled instead. Re-enable by adding the service back to the list, then `nas restart` **and `nas commit`** again. The file is yours: upgrades never overwrite it. If it ever has a syntax error, the built-in default applies rather than silently stopping your shares.

**Runlevel services** (everything else) use the standard Alpine pattern — stop it, remove it from the runlevel, commit:

```sh
rc-service <name> stop && rc-update del <name> default && nas commit
```

Most services live in the `default` runlevel, as above. A few start earlier and live in `boot` (`zram-init`, `ufw`) — for those, say `boot` instead of `default`; `rc-status boot` lists them. `nas upgrade` preserves whatever you decide here: a service you remove stays removed across upgrades.

What each one costs you if disabled:

| Service | Safe to disable if… | You lose |
| --- | --- | --- |
| `avahi-daemon` | you use IPs or DNS instead of `mountnas.local` | mDNS discovery (also stop `dbus` if nothing else needs it) |
| `chronyd` | never recommended | time sync — clock drift breaks SnapRAID timestamps, TLS, logs |
| `crond` | ⚠️ **think twice** | scheduled jobs **including the 15-minute disk-loss watcher and your SnapRAID syncs** — alerting goes blind |
| `smartd` | you accept no disk-failure early warning | SMART monitoring + alerts |
| `rpcbind` | you don't serve NFS | nothing else uses it |
| `acpid` | headless box you never power-button | clean shutdown on the power button |
| `zram-init` (**boot** runlevel — use `rc-update del zram-init boot`) | you have RAM to spare and prefer zero swap | compressed-RAM swap — you lose the headroom that keeps the OS + Docker comfortable |
| `sshd` | ⚠️ console-only administration | **all remote access — be sure you have a monitor/keyboard** |

**Optional services** (NUT, the web dashboard, the browser terminal, the ufw firewall) ship off. If you enabled one and want it gone: the same stop + `rc-update del` + commit (`nas web off` / `nas ttyd off` + `nas commit` for the web pair; `ufw disable` + `nas commit` for the firewall — its service stays in the boot runlevel as a no-op by design; WireGuard has no service — `wg-quick down <iface>` and remove your local.d/cron hook).

**Don't `apk del` baked-in packages to disable a service** — the base package set is restored by `nas upgrade`'s world reconciliation, so the binaries come back (deliberately). Disabling the *service* is the supported, upgrade-proof way; the idle binaries on disk cost nothing since the whole OS lives in RAM anyway.

## Web dashboard & built-in user guide

MountNAS stays CLI-first, but a glanceable **read-only** status page is one command away:

```sh
nas web on        # default port 8080; or: nas web on 9090
nas commit        # REQUIRED to keep it across reboots (RAM-only until committed)
```

Then browse to `http://mountnas.local:8080/` — hardware, health checks (every check, pass and fail), storage and per-disk temps, network (gateway/DNS/traffic), protection (backups, parity verdict, rollback points, SSH posture, UPS), a SnapRAID card (array per disk, last maintenance, safety limits), Docker (per-container state, IP, CPU, RAM), firewall, packages you added, cron, recent operations and a syslog tail. The page auto-refreshes every 2 minutes and never wakes a sleeping disk. The header links the **user guide** (`/guide.html`, baked into your release — philosophy, how-tos, the complete `nas` manual, troubleshooting) and shows whether the browser terminal (`nas ttyd`) is running — a click away when it is. `/status.json` feeds integrations.

By design it can't manage anything: a root-run job renders **static files into RAM** every ~2 minutes and busybox httpd — dropped to `nobody` — serves only those. No request-time code, no forms, no auth to get wrong, no disk writes (nothing spins up a sleeping drive). Plain HTTP on your trusted LAN, same posture as Samba. Management stays on SSH with the `nas` CLI. Off by default; `nas web off` removes it entirely.

## Disk health (smartd), alerts & notifications, and UPS (nut)

**smartd** runs out of the box and never wakes spun-down disks (`-n standby,q` in the shipped `/etc/smartd.conf`).

**Notification sinks** — one config, every alert. List your sinks in `/etc/mountnas/notify.conf` (one `type:target` per line), test with `nas notify --test`, then `nas commit`:

```text
ntfy:https://ntfy.sh/your-secret-topic
email:you@example.com
webhook:https://example.com/hook
```

Supported: `email` (via msmtp), `ntfy`, generic `webhook` (JSON POST), `slack` (also Mattermost-compatible), `discord`, `gotify`. Push sinks like ntfy need **no mail relay at all** — the fastest path from zero to phone notifications. Everything that alerts (the disk-loss watcher, SMART via the wrapper below, failed upgrades, health digests, your own `nas notify` calls) fans out to *all* configured sinks. No sinks configured = silently off; nothing to tend.

**Email specifically** still needs msmtp pointed at your SMTP relay:

1. Edit `/etc/msmtprc` (a commented template ships; keep it mode 0600 — it holds a password).
2. Test it: `echo test | mail -s "MountNAS test" you@example.com`
3. `nas commit`

**SMART failure alerts**: wired to your notification sinks **out of the box** — the shipped `/etc/smartd.conf` already routes smartd trouble through `notify.conf`, so alerts start working the moment you configure a sink (and cost nothing before that). Prefer classic direct mail instead? Replace the line in `/etc/smartd.conf`:

```text
DEVICESCAN -n standby,q -m you@example.com
```

then `rc-service smartd restart && nas commit`. (Boxes seeded before 1.0rc2 shipped without the sink routing — add `-m root -M exec /usr/libexec/mountnas/smartd-notify` to the `DEVICESCAN` line to get it.)

**Disk-loss alerts** (detachment, dead mount, filesystem gone read-only): fire automatically through your sinks — the 15-minute watcher notifies on the transition, once, and tells you the recovery command. (The old `/etc/mountnas/alert-email` file keeps working as one more email sink.) SMART covers a disk *warning* it will fail; this covers a disk that already *vanished*.

From cron, pipe anything into a notification: `snapraid sync 2>&1 | nas notify "snapraid sync"`.

**Health digest (optional):** a periodic summary — overall status, warnings, recent operations — through the same sinks. Schedule it yourself: `crontab -e` → `0 8 * * 1  /usr/libexec/mountnas/health-digest` (then `nas commit`). With no sinks configured it's a silent no-op, so it's always safe to leave scheduled.

**UPS:** nut is installed; configure `/etc/nut/*`, enable nut-upsd + nut-upsmon, set `SHUTDOWNCMD "/sbin/poweroff"`, then `nas commit`.

## Firewall

**ufw ships in the image but is OFF by default** — the box comes up fully open, on the
usual NAS assumption that the LAN is trusted and your router is the perimeter. If your
LAN isn't that (shared housing, IoT devices, a lab), enabling it is one command — but
allow your services **first** so you don't lock yourself out:

```sh
ufw allow SSH             # do this FIRST (port 22)
ufw allow CIFS            # samba — 'ufw app list' shows the shipped profiles (NFS, ...)
ufw allow 8080/tcp        # only if you use 'nas web'   (22222 for 'nas ttyd')
ufw enable                # takes effect now AND loads at every boot (before networking)
nas commit                # REQUIRED — rules + the enable flag live in /etc/ufw
```

* Defaults once enabled: incoming **deny**, outgoing allow; IPv6 is covered by the same commands (ufw drives iptables *and* ip6tables).
* `nas status` shows the firewall state — including the one dangerous case, an enabled config whose rules aren't actually loaded. The web dashboard shows the full ruleset (`ufw status verbose`).
* ⚠️ **If you reached 1.0rc3 by `nas upgrade` rather than by flashing it**, ufw was installed but never added to a runlevel, so its rules load when you run `ufw enable` and then silently *don't* load after a reboot. Check with `rc-status boot | grep ufw`; fix with `rc-update add ufw boot && nas commit`. Later releases repair this automatically at the first boot.
* **Docker-published ports bypass ufw** — Docker programs its own iptables rules ahead of ufw's. Publish to `127.0.0.1:` or use internal Docker networks for containers that must not be exposed; your router remains the real perimeter.
* Turn it back off: `ufw disable && nas commit`.

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

MountNAS upgrades the OS **in place** on the boot USB (single-slot): the kernel modules
are copied to RAM and the loopback detached so the running system's files can be safely
swapped, then a reboot. Because a bad
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
- added a custom `/etc/init.d` service and it vanished after reboot -> Alpine's `lbu` deliberately does not track `/etc/init.d` (init scripts belong to packages), so `nas commit` never saved it — the telltale is a surviving `rc-update` symlink in `/etc/runlevels` pointing at a missing script. Track yours explicitly once: `lbu include /etc/init.d/<name>`, then `nas commit`.
- `nas commit` fails with `tar: empty archive` -> the RAM root is full (check `df -h /`). Free space — or just reboot, which resets RAM — and commit again.
- two clones in one machine -> don't; both answer to the config label (`MNASCFG`) by design.

## What's different from stock Alpine

A terse inventory of everything MountNAS changes or adds compared to a stock Alpine (diskless) image.

__Custom tooling & services (shipped by the `mountnas-tools` apk)__

* `nas` management tool baked in and installed at `/usr/sbin/nas` (setup wizard, status/disks, commit/rollback, upgrade, backup, notify, web, ttyd, logs, history, report) — bash completion at `/etc/profile.d/nas-completion.sh`, zsh at `/usr/share/zsh/site-functions/_nas`
* `mountnas` storage supervisor at `/etc/init.d/mountnas` — Docker/Samba/NFS are removed from runlevels and started only once `/mnt/nasdata` is mounted; a failed disk gets a read-only placeholder mount so nothing can fill RAM
* Boot helpers in `/etc/init.d/`: `mountnas-mkdirs` (creates fstab mountpoints before `localmount`), `mountnas-net` (dynamic wired DHCP), `mountnas-sshkey` (installs `authorized_keys` dropped on the BOOT partition), `mountnas-issue` (live IP + hostname on the pre-login console, re-run on link changes via `/etc/network/if-up.d/mountnas-issue`)
* Helper scripts in `/usr/libexec/mountnas/`: `notify` (sink fan-out), `smartd-notify`, `data-watch` (disk-loss watcher, run from `/etc/periodic/15min/mountnas-datawatch`), `health-digest`, `gen-issue`, `gen-webstatus`, `web-refresh`, `pick-nic`, `write-bootcfg`, `release-string`
* Optional web dashboard + built-in user guide (`/etc/init.d/mountnas-web`, guide at `/usr/share/mountnas/web/guide.html`) and browser terminal (`/etc/init.d/mountnas-ttyd`) — both off by default
* Notification fan-out configured in `/etc/mountnas/notify.conf` (email, ntfy, webhook, Slack, Discord, gotify) — wired to smartd, the disk-loss watcher, failed upgrades, health digests, and `nas notify`
* Login-shell snippets in `/etc/profile.d/`: `nas-welcome.sh`, `nas-prompt.sh`, `nas-aliases.sh`, `nas-resize.sh` (serial-console terminal size fix)

__Additional packages baked in__

* The curated NAS package set — Docker, Samba, NFS, SnapRAID, mergerfs, smartmontools, NUT, restic/rclone, WireGuard, filesystem tools, diagnostics, consumer-x86 firmware, and more. See the full list in [Baked in Packages](#baked-in-packages).

__Run-from-RAM model & persistence__

* Entire OS runs from RAM off the USB stick; nothing persists until `nas commit` (Alpine's `lbu`, overlay on the `MNASCFG` config partition, 3 previous overlays kept for `nas rollback`)
* On-USB apk snapshot repo (`/run/mountnas/apks`) listed first in `/etc/apk/repositories`, plus CDN main+community repos pinned to this release's concrete Alpine version (never `latest-stable`)
* apk cache symlinked to `/cfg/cache` so user-added packages persist and reinstall at every boot, even offline
* Custom lbu include/exclude list (`/etc/apk/protected_paths.d/lbu.list`): persists `/root`, Samba/Tailscale/ZeroTier state, crontabs, and `/usr/local/bin`; excludes boot-generated files
* Append-only operations log at `/cfg/mountnas-ops.log` (`nas history`) — persists without `nas commit`
* Single-image in-place upgrades (`nas upgrade`) with a mandatory full-USB `nas backup` first — every boot payload is staged to `.new` names and committed with back-to-back renames, and the `mountnas` service heals a power cut inside the rename window at the next boot

__Shipped config that differs from stock__

* `/etc/ssh/sshd_config`: passwordless root login permitted on a fresh image (headless first boot); `nas setup` flips `PermitEmptyPasswords` to `no` once a root password is set
* `/etc/smartd.conf`: `-n standby,q` (never wakes spun-down disks) and SMART trouble routed through the notification sinks via `-M exec`
* `/etc/avahi/avahi-daemon.conf`: mDNS on by default with `deny-interfaces=docker0` so `.local` resolves to the LAN address
* `/etc/docker/daemon.json`: data-root on `/mnt/nasdata/docker`, `live-restore`, capped json-file logs
* Pre-seeded templates you own: `/etc/fstab` (config partition + commented data-disk guidance), `/etc/samba/smb.conf`, `/etc/snapraid.conf`, `/etc/msmtprc`, `/etc/mail.rc` (wires `mail(1)` to msmtp), `/etc/mountnas/notify.conf`
* `/etc/modules` preloads `fuse`, `ntfs3` (in-kernel NTFS), and `drivetemp` (disk temps without waking drives)
* Compressed zram swap on by default (`zram-init` in the boot runlevel; `/etc/conf.d/zram-init` sizes it to half of RAM, zstd) — cold pages of the RAM-resident OS compress well, so a box keeps headroom under load
* Upgrades reconcile more than packages: releases ship an `rc.base` runlevel table and `confd.base` defaults next to `world.base`, so a newly enabled service or config default reaches boxes that upgrade — via a three-way merge that never undoes a service you disabled, and never overwrites a `conf.d` file you own
* `/etc/inittab`: gettys on tty1–6 **and** ttyS0, so serial consoles (IPMI SoL, Proxmox `qm terminal`) get a login prompt out of the box
* `/etc/doas.conf` pre-configured (`permit persist :wheel`)
* bash is the default login shell: root is switched off busybox ash once at boot (a deliberate later `chsh` is never overridden), and new users are documented with `adduser -s /bin/bash`. `/bin/sh` stays busybox ash for scripts.
* Empty `/etc/motd` and a MountNAS `/etc/issue` banner instead of Alpine's defaults; eudev instead of busybox mdev; chronyd, smartd, crond, acpid, dbus, rpcbind enabled by default

__Boot / image level__

* Kernel cmdline includes disk-bus drivers (ahci/nvme/virtio) so the image also boots as a VM disk, not just a USB stick; the config overlay is found by partition label
* AMD + Intel early CPU microcode shipped as boot addons
* The `linux-lts` apk is deliberately absent from the on-media repo — kernel updates arrive only via `nas upgrade` replacing `/boot`
* ufw baked in but shipped **disabled** — its service idles in the boot runlevel as a quiet no-op (`/etc/conf.d/ufw`) until `ufw enable`, then rules load before networking at every boot (see [Firewall](#firewall))

## Baked in Packages

MountNAS includes a curated list of packages helpful to NAS users in the core OS image. 

__MountNAS Helper Utilities__

* mountnas-tools

__Core Shell / Base Utilities__
* bash
* zsh (alternate login shell — `chsh -s /bin/zsh`, then `nas commit`)
* busybox-extras (the httpd applet behind `nas web`)
* coreutils
* findutils
* util-linux
* less
* file
* tree
* pv
* mc
* tmux
* byobu (friendlier tmux front-end — persistent sessions with status bars; `byobu-doc` included)
* nano
* lsof
* psmisc
* jq
* yq
* tzdata
* musl-locales + musl-locales-lang (real locale support on musl; default `LANG=en_US.UTF-8` seeded in `/etc/profile.d/locale.sh` — edit and `nas commit` to change)
* chrony
* acpid
* doas

__Disk Partitioning__

* parted
* gptfdisk
* sgdisk (scriptable GPT partitioning)
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
* testdisk (partition recovery + PhotoRec undelete)
* f3 (counterfeit/failing flash detection)
* fio

__File Integrity / Dedup / Compression__

* xxhash (fast checksums for verifying large copies)
* fdupes (duplicate-file finder)
* zstd, lz4, xz (busybox only decompresses these)
* 7zip (`7z` — .7z and Windows-made archives)

__Device Manager__

* eudev
* udev-init-scripts
* udev-init-scripts-openrc

__Networking / Transfer__

* curl
* wget
* rsync
* rclone
* restic (encrypted, deduplicated, versioned backups — to local disks, SFTP, S3, or any rclone remote)
* borgbackup (same job as restic, different repo format/ecosystem — for users already on Borg/borgmatic/Vorta)
* openssh
* openssh-client
* openssh-sftp-server
* ttyd (browser-based terminal serving a real login prompt — off by default; `nas ttyd on`, port 22222)

__Overlay / Mesh VPN (services OFF by default)__

* wireguard-tools (plain kernel WireGuard: wg + wg-quick)

__Host Firewall (OFF by default — see [Firewall](#firewall))__

* ufw (+ ufw-openrc; drives the iptables/ip6tables already present as a Docker dependency)

__Name Resolution / Discovery__

* avahi
* avahi-tools (`avahi-resolve`/`avahi-browse` — verify and debug `.local` discovery)
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
* ntfs-3g-progs (NTFS: mount with the in-kernel `ntfs3` driver — fstype `ntfs3` in fstab — which is preloaded via `/etc/modules`; these are the userspace tools `mkfs.ntfs`/`ntfsfix`/`ntfsresize`. The slower FUSE `ntfs-3g` driver is not installed.)
* hfsprogs
* udftools
* fuse
* fuse3
* fuse-overlayfs

__Hardware Identification__

* pciutils
* usbutils
* cyme (modern `lsusb` replacement — readable USB tree with power/speed detail)
* dmidecode
* lshw
* lm-sensors

__Network Diagnostics__

* ethtool
* iperf3
* tcpdump
* mtr
* bind-tools

__System Monitoring__

* btop
* bottom (`btm` — btop-alternative system monitor with per-process I/O)
* iotop
* ncdu
* sysstat
* fastfetch

__Containers__

* docker-engine + docker-cli (the Docker daemon and CLI)
* docker-cli-buildx (`docker build` / BuildKit)
* docker-cli-compose (`docker compose`)

__Memory__

* zram-init (compressed zram swap, on by default — sized to half of RAM in `/etc/conf.d/zram-init`; it lives in the `boot` runlevel)

__UPS monitoring (NUT)__

* nut
* nut-openrc
* nut-udev

__Outbound Email (alerts)__

* msmtp (send-only SMTP client; configure `/etc/msmtprc`)
* mailx (provides `mail(1)`, pre-wired to msmtp — see [email alerts](#disk-health-smartd-email-alerts-and-ups-nut))

__Device Firmware__ (curated consumer-x86 set — repurposed laptops/desktops/NUCs/mini-PCs; anything else: see [Adding firmware for other hardware](#adding-firmware-for-other-hardware))

* GPU / display: linux-firmware-i915, -xe, -amdgpu, -radeon, -nvidia
* Wifi: linux-firmware-intel (Intel wifi + Bluetooth), -mediatek, -ath10k, -ath11k, -ath12k, -ath6k, -ath9k_htc, -brcm, -cypress, -rtw88, -rtw89, -rtlwifi
* Bluetooth: linux-firmware-qca, -rtl_bt, -ar3k
* Wired NICs: linux-firmware-rtl_nic, -tigon, -bnx2, -e100
* Laptop platform: linux-firmware-cirrus, -amd, -amdnpu, -dell, -hp, -lenovo, -synaptics