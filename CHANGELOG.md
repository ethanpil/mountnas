# Changelog

## [Unreleased]

### Fixed
- **`nas web on <port>` no longer clobbers `/etc/conf.d/mountnas-web`.** Setting a port rewrote the entire file, wiping a hand-set `WEB_REFRESH_SEC=` (documented in that same file). Only the `PORT=` line is rewritten now, every other line preserved — the same never-clobber contract `nas logs --persist` honors. `nas ttyd on <port>` uses the same helper.
- **`nas backup` rejects unrecognized arguments instead of silently ignoring them.** `nas backup /mnt/usb/backup.img.gz` (forgetting `--to`) used to discard the path entirely and image to the default `/mnt/nasdata/backups` — a backup that isn't where you think it is, discovered at restore time. Unknown arguments, extra arguments, and a missing `--to` value are now usage errors, like every other subcommand.

### Changed
- **A stale backup is now called out.** The backup image is the only rollback net for `nas upgrade`, but `nas status` reported an 18-month-old backup with the same green `ok` as a fresh one. Past 90 days it flips to a warning, and the `nas upgrade` confirmation gate prints the recorded backup's age — loudly when it's over 3 months old.
- **`mountnas.local` no longer resolves to the Docker bridge.** With Docker running, avahi advertised the hostname's A record on *every* interface — including `docker0` (`172.17.0.1`), which it handed out first — so a LAN client resolving `mountnas.local` could get an address only reachable on the box itself (confirmed via `avahi-browse`: docker0, eth0 **and** loopback were all published). The shipped `/etc/avahi/avahi-daemon.conf` now denies `docker0`, so discovery returns the real LAN address (verified: resolution flips from `172.17.0.1` to the eth0 address). Users with custom docker networks can extend the `deny-interfaces` line. Regression-guarded: the mDNS test now asserts resolution matches the default-route (LAN-reachable) address, not just any box address.

## [1.0rc1] — 2026-07-17

**First 1.0 release candidate.** Feature-complete: the diskless RAM-root
appliance, the `nas` CLI, single-image in-place upgrades with a booted-and-
verified restore path, storage supervision, notifications, the read-only web
dashboard + built-in guide, the browser terminal, and a self-hosted 85-test
QEMU suite that validated the previous two releases with zero post-release
fixes. Changes since beta-6:

### Fixed
- **NFS now starts reliably at boot.** When the `mountnas` supervisor won the boot ordering, its `rc-service nfs start` collided with rpcbind's own default-runlevel start (rpcbind still mid-start) — nfs failed ("cannot start nfs as rpcbind would not start") and **stayed down until a manual `nas restart`**. Caught by the beta-6 validation run's own dashboard render (nfs a grey "off" pill on an otherwise healthy box — the suite's docker/samba-biased assertions had never looked). The supervisor now **settles rpcbind (bounded ~10s) before starting nfs** — it already owns data-service ordering, so this is the right altitude — plus `after rpcbind` in its `depend()` for the boot sequence. Regression-guarded in category K.

### Added
- **`avahi-tools` baked in** — `avahi-resolve`/`avahi-browse` for verifying and debugging `.local` discovery. Also un-skips the suite's mDNS resolution test, which had silently skipped in every full run (only the daemon's existence was ever checked — now `<host>.local` resolution is verified end-to-end).

### Testing
- **The backup restore drill, finally automated** (`tests/qemu`, now 85 tests): back up a configured box, pull the image out, write it to a fresh virtual stick, **boot it**, and prove the OS + saved config came back — until now the only rollback net for upgrades was gzip-verified but had never been booted.
- **Packaging-integrity test**: asserts the pure released image (no dev pushes) actually ships the full mountnas-tools manifest and every baked-in tool the docs promise — closing the blind spot where the dev_guest test pattern could mask an APKBUILD that forgot a file.

## [beta-6] — 2026-07-16

### Testing
- **Upgrade-safety coverage for user drift** (`tests/qemu`, now 81 tests). Two new category-D tests where the harness *creates* realistic drift before upgrading, so even a fresh image has something to validate: `test_user_changes_survive_upgrade` edits `smb.conf`/`snapraid.conf`/`sshd_config`/`/etc/nut/ups.conf`/`fstab` + a custom `/etc/apk/repositories` line, sets a root password, adds a samba user and a package, then self-upgrades and asserts every edit survived (incl. the CDN re-pin keeping the custom repo line, and the overlay config winning over the apk-shipped `nut` default); `test_docker_survives_upgrade` runs a `--restart unless-stopped` container with data on `/mnt/nasdata` and a customized `daemon.json`, upgrades, and asserts the container, its image, its data, and the config all came through — confirming `nas upgrade` cannot harm installed Docker.

### Added
- **New baked-in tools:** [`cmkfs`](https://github.com/ethanpil/cmkfs) (guided TUI for mkfs — every MountNAS release ships the **latest** cmkfs release, resolved at build time), [`duf`](https://github.com/muesli/duf) (a better `df`; repackaged locally — not in Alpine v3.24), `bottom` (`btm` system monitor), `cyme` (modern `lsusb`), and `ttyd` (powers `nas ttyd`, below).
- **`nas ttyd` — browser-based terminal** (off by default, port 22222): `on [port]` / `off` / `status`, with the same commit-honesty warnings as `nas web`. Serves a **real `/bin/login` prompt**, never a bare shell; root login works (`on` appends `pts/*` entries to `/etc/securetty` once — busybox `login` refuses root on unlisted ttys otherwise); plain-HTTP cleartext warning printed on enable. The dashboard footer links to the terminal while it's running.
- **Dashboard: full Docker containers table** — every container (running, paused, stopped) with name, short ID, state pill (exited-nonzero renders red), status, image, ports, and age; the summary card shows running/paused/stopped counts. Collapsible (closed by default, counts in the summary line) — a compose stack makes it long. All from ONE time-bounded `docker ps -a` (deliberately no `{{.Size}}` and no `docker stats` — the two genuinely expensive queries), so there is no performance hit.
- **Dashboard: hardware inventory** — a collapsed section with the USB device tree (`lsusb -tv`), PCI devices (`lspci`), and physical memory modules (`dmidecode`), all sysfs/SMBIOS reads.
- **Disabling unused services is now documented and fully supported.** New "Disabling Unused Services" sections in the README and the built-in guide cover every service. The one enabling change: the `mountnas` supervisor's data-service list is overridable via `DATA_SERVICES=` in `/etc/conf.d/mountnas` (list only what you keep) — previously Docker/Samba/NFS could not be permanently disabled at all (they live in no runlevel, `apk del` is undone by upgrade world-reconciliation, and init.d edits don't persist on a diskless system). `nas status` and the web dashboard understand the override and report deliberately disabled services as disabled instead of warning forever.

## [beta-5] — 2026-07-13

### Added
- **Read-only web dashboard + built-in user guide** (`nas web on [port]`, off by default): overall health, storage state, services, per-disk temps/free space and the failing check lines, auto-refreshing every ~2 minutes at `http://<host>:8080/`. Deliberately unable to manage anything: a root-run job renders **static files into tmpfs** and busybox httpd (dropped to `nobody`) serves only those — no request-time code, no auth surface, no disk writes. The single page also carries hardware/CPU detail, load/memory (used·avail·total)/RAM-root fill, installed-package count, your added packages (world vs. the release base), and a collapsible tail of the last 100 syslog lines. `/guide.html` is a comprehensive user guide baked into each release (philosophy, how-tos, full `nas` manual, file map, baked-in package list, troubleshooting); `/status.json` feeds integrations. Adds `busybox-extras` (the httpd applet) to the image.
- **Health digest** (`/usr/libexec/mountnas/health-digest`): opt-in cron one-liner that pushes a periodic summary (status verdict, warnings, recent operations) through the notification sinks; silent no-op with no sinks configured.
- **Operations log** (`nas history`): setups, commits (with their notes), rollbacks, backups, upgrades and shutdowns/reboots are recorded append-only to `/cfg/mountnas-ops.log` — UTC timestamp, who ran it (doas user, ssh origin or tty), outcome. Written directly to the config partition so it persists **without** `nas commit` and survives a box that comes up half-broken; self-trims to ~1000 entries; included in `nas report`. Zero setup, zero attention.
- **Notification sinks** (`nas notify`, `/etc/mountnas/notify.conf`): every alert — disk-loss transitions, SMART trouble (via the new `smartd-notify` wrapper), failed upgrades, health digests — now fans out to any mix of `email`, `ntfy`, generic `webhook`, `slack`, `discord`, and `gotify` sinks. Push sinks need no SMTP relay, so phone notifications work with one config line. `nas notify --test` verifies the setup; `nas notify "subject"` sends ad-hoc messages from scripts/cron (body pipeable). The old `alert-email` file keeps working as an email sink; `nas status` now reports the overall sink count. Stateless: no daemon, zero overhead until an event actually fires, every network send time-bounded.

## [beta-4] — 2026-07-12

### Fixed
- **Interrupted `nas backup` / `nas upgrade` over SSH now clean up.** A dropped SSH session delivers SIGHUP, which neither operation trapped — and ash skips EXIT traps on untrapped signals. Backup stranded `/cfg` read-only (every later `nas commit` failed until a manual remount) and left a partial image behind; upgrade leaked its multi-GB temp files and loop device. Both now trap HUP.
- **`nas upgrade` no longer intermittently aborts with "cannot mount the BOOT partition"**: losetup scans the image's partition table asynchronously, so on a busy box the mount could race the p1 device node into existence. The upgrade now nudges a rescan and waits (bounded ~5 s) for the node.
- **`nas restart` holds data services when `/mnt/nasdata` is a network filesystem.** OpenRC's `restart` re-started the docker/samba/nfs its own stop had stopped mid-transition, so the unsupported-netfs state said "services held" while Docker kept running. The hold is now enforced after the transition.
- **`nas disks --json` reports `in_fstab` for `LABEL=` and `/dev/` entries too** — previously only `UUID=` matched, so label-based entries (which `nas disks` itself suggests) read as unconfigured.
- **`nas disks` offers the paste-ready line again for a disk whose fstab entry was commented out** — a disabled entry was treated as configured forever.
- **`nas rollback` can no longer be locked out by a stale staging file from before a hostname change** (it was misreported as an encrypted overlay).

### Changed
- **Faster, quieter boots**: the boot-time package sync resolves offline-first (on-media repo + `/cfg/cache`) and only touches the CDN repos when something is missing locally. Previously every boot fetched package indexes over the network — and an offline box waited out the timeouts during startup.
- `nas commit` prunes `.mountnas-notes` entries whose snapshot lbu has rotated away (the file grew an orphaned line per rotation, forever).

### Build / CI
- The build now fails if the raw image grows within 128 MiB of `nas upgrade`'s temp-space pre-check (`need_kb`), so the image size and the pre-check can no longer drift apart silently.
- QEMU suite hardening from its first full run on KVM: serial-socket draining moved to a background thread, plus 10 harness fixes.

## [beta-3] — 2026-07-07

### Fixed
- **lbu include/exclude never worked.** The seed overlay shipped plain `/etc/lbu/include` and `/etc/lbu/exclude` files since alpha-1 — but lbu's real mechanism is `/etc/apk/protected_paths.d/lbu.list` (`+path`/`-path`), and nothing ever read the plain files. Consequences until now: `/root`, samba passwords, crontabs, and VPN identities **did not persist across reboots**, and boot-generated files meant to be excluded (`/etc/issue`) showed as unsaved changes forever (the beta-2 report that unraveled this). The seed now ships the real list; existing boxes are migrated automatically once by the `mountnas` service (old files parked as `*.migrated` — run `nas commit` after the first boot on beta-3 to persist the migration).
- **`nas upgrade` detects gzip by content** (magic bytes), not filename — a valid image saved as `.img.tgz` was treated as a raw disk and failed cleanly but confusingly. Boxes on beta-2 and earlier still run their installed matcher: name the file `.img.gz` there.
- Persistent-logging honesty: `nas logs --persist status` and `nas status` now say whether the setting is committed or will be lost at reboot.

### Added
- **Disk-loss email alerts**: put an address in `/etc/mountnas/alert-email` (plus a configured `/etc/msmtprc`) and the 15-minute watcher emails once on the transition when the data disk disconnects, its mount dies, or its filesystem goes read-only — including the recovery command. Complements smartd's `-m` (SMART = disk warning it will fail; this = disk already gone).
- **`nas status` surfaces alerting state**: a line reporting whether disk-loss email alerts are off, wired up (`-> address`), or configured-but-unsendable (address set but `mail` missing) — so a broken alert setup is caught now, not when a disk actually dies.

### Changed
- **`nas` screens unified** (presentation, plus two small behavior tweaks noted below): one header/rule/hint grammar across all screens (bold-cyan section headers, dim tips), rules/framing use only ASCII (`=`/`-`) and every line is ≤76 columns for serial consoles (body text keeps the em-dash punctuation already used elsewhere). Two intentional behavior changes ride along: colors are now also suppressed when `TERM=dumb` (previously only `NO_COLOR`/non-tty), and `usage:` errors now print to stderr instead of stdout.
- **`nas status` reads at a glance**: groups of passing checks compact to single `[ OK ]` lines (services, per-mount fstab trio, runlevel ownership) while any warning/failure keeps its own loud line; a verdict footer ("all N checks passed" / "N failed — details above") closes the screen and uptime is humanized (`3d 4h`). `--json` note: `fail_lines`/`warn_lines`/`healthy`/`services[]` are byte-stable; only the informational `checks.ok` count shrinks with the merged lines.
- **`nas help` is two pages** (commands grouped by task, then files & recipes), with a `more`-style any-key pause on interactive terminals — pipes and scripts still get the whole text flat. A subcommand-clarity line sits under the title ("run as: nas \<command\>"), command names are bold, and group headers are colored.
- **`nas changes --diff` colorizes diffs** on the terminal (piped output stays patch-clean); the upgrade warning box renders red; wizard steps and upgrade stages are bolded.
- **`nas disks` gets semantic color**: mounted mountpoints green, "(not mounted)" dim, blank-disk guidance yellow, boot-stick partition tags red.
- **The login welcome banner adopts the `nas` palette**: version bold, disk-state lines red/yellow by severity, unsaved-changes yellow, the help pointer dim — same tty/`NO_COLOR`/`TERM=dumb` gating.

### Removed
- **`nas validate` / `nas checkup`** — the two aliases for `nas status` / `nas status --deep` are gone; use the real commands. They added dispatcher and help/completion surface for no capability, following the earlier `nas howto` removal. A CI-lint guard now keeps the shell completions in lockstep with the dispatcher's command set.

### Known / parked
- Serial-console (`qm terminal`) full-screen layout remains wrong after the ash-compat fix; parked per maintainer decision — use SSH or noVNC for full-screen tools.

## [beta-2] — 2026-07-07

Everything found in the first full live test (beta-1 on Proxmox), fixed. Two reported items were not code bugs: the `status --json` jq error came from the test sheet's own command (jq operator precedence — `|` binds looser than `,`), and the chrony "KoD RATE" log line was pool-server rate limiting caused by reboot-heavy testing (`iburst` fires on every boot; chrony backs off automatically).

### Fixed
- **Serial-console resize never ran** — the snippet was guarded on bash, but root's login shell is busybox ash, so `qm terminal`/IPMI sessions stayed at a wrong 80x24 (btop/mc/nano garbled). Now runs under ash and bash.
- **`nas disks --json` crashed** ("Cannot index array") — a jq scoping bug in the `in_fstab` computation. Blank disks in the human view also now say "(blank — no filesystem; …)" with the mkfs first step instead of showing nothing.
- **Runtime disk-loss detection missed dead-but-listed mounts**: a hot-detached disk backing a bind-mounted nasdata passed every check (path spec, mountpoint present, /proc/mounts still `rw`) while all I/O returned EIO. `data-watch` now read-probes the mountpoint and flips the state to `mountfail`.
- **Reattached disks recover without a reboot**: the supervisor now detects dead mounts (EIO on read), lazy-unmounts them, and remounts fresh — `nas restart` used to start services against the dead mount.
- **`nas report` was completely broken** — it nests `nas status --deep`, whose loops clobbered the report's generic variable names, sending the bundle into a directory literally named after the last disk. Report variables are now prefixed and the sensors helper declares everything local.
- **`nas upgrade --check` misreported a private repo as "no network"** — HTTP status is now captured and reported distinctly (network/DNS vs private-or-no-releases vs rate limit). On-box checks and URL upgrades require the repository to be public.
- **msmtprc template friction**: the single example account is now named `default`, so uncomment-and-fill works without the `account default : name` alias line.

### Added
- **`nas commit -m "note"`** — label a commit; the note appears beside the matching snapshot in `nas rollback --list` and on the rollback confirmation. Notes follow snapshots automatically (keyed by the overlay mtime lbu embeds in rotated filenames).

### Removed
- **`nas howto`** — removed entirely (command, topic files, completions, docs).
- **LUKS** (`cryptsetup` + `dmcrypt`) — removed entirely per maintainer direction.

### Docs
- Persistent-log rotation made explicit: automatic, 1 MB × 10 files via busybox syslogd (`-s 1024 -b 9`) — nothing to manage.

## [beta-1] — 2026-07-07

First beta. A deep multi-angle code review of the alpha-7 CLI pass surfaced 15 findings — no data-loss or boot-breaking bugs, but real contract violations and fragility. Every finding is fixed here, one commit each.

### Fixed
- **`--help` can no longer execute a command.** `nas checkup --help` used to *run* a deep status (waking sleeping disks) because the help interceptor fell through for commands without a help page; it is now closed (help or overview, never execution) and every command has a page.
- **Flags parse in any order.** `nas validate --json` (the documented status alias) emitted colored human text into monitoring pipes; `--deep --json` combinations silently dropped a flag. status/validate/checkup now share one flag loop — and **deep JSON snapshots work** for the first time.
- **The "MountNAS ?" banner bug**: a missing release file short-circuited gen-issue's fallback so the version file was never consulted. The release/version fallback now lives in one shared `release-string` helper used by `nas`, the banner, and the login message (it was hand-copied three slightly different ways; one copy was wrong).
- **`nas status` fails closed**: if check tracking cannot start (mktemp failing — most plausibly a full RAM root, the exact state a probe must catch), status exits 2 instead of silently reporting healthy.
- **`nas logs --persist` no longer clobbers user config**: it edits only its own `-O/-s/-b` tokens inside `SYSLOGD_OPTS`, preserving remote-forwarding and any other user additions; typos like `--persist onn` (or `--help`) are usage errors instead of masquerading as a status query, and `-n` validates its count.
- **`nas rollback` survives its own crashes**: a stale `.new` file from an interrupted rollback used to trip the encrypted-overlay refusal forever; snapshot-name collisions can no longer overwrite an existing snapshot.
- **CI validates `release_tag`** before it reaches sed — a `&` in the tag silently corrupted the stored release string; a `/` broke the build mid-command.
- **Sub-zero sensor readings display** as signed values instead of vanishing as "no sensor".
- `nas help <typo>` exits 1 with a clear message instead of succeeding with the generic overview.

### Changed
- **Status checks emit structured records** (`TYPE<TAB>message`); `--json` renders from the records instead of re-parsing the human text at a magic character offset — the display format is free to change without silently breaking dashboards, and the CONTEXT.md "do not touch the tags" landmine is retired.
- **Monitoring polls are ~half the cost**: JSON mode skips the per-disk hdparm sensor probes (its data has no JSON field), one 8-service probe loop serves both output modes (the human status gains smartd/crond/chronyd lines), and `nas disks --json` reuses its single lsblk dump.
- **One `_boot_usb_disk` helper** replaces four hand-copied resolutions of "which disk is the boot USB" (status guard, disks, disks --json, backup), and the fstab boot-USB guard uses one lsblk dump instead of one per fstab line.
- **`nas changes --diff` reviews everything a commit persists**: mode/owner deltas (a bare chmod no longer renders as an empty section), deleted-directory contents, and an explicit note for byte-identical files.
- **Shell completions self-maintain**: howto topics are read from the installed directory (new topics complete without touching the completion files), and the zsh command list gained the validate/checkup aliases bash already had.

## [alpha-7] — 2026-07-06

A `nas` CLI feature pass — safer commits, better screens, automation hooks.

### Fixed
- **Version identity.** `nas version`, `nas status`, and the login banner showed the internal apk build id (`1.0.0_git…`) instead of the release everyone knows (`alpha-7`) — release tags can't satisfy apk's version grammar, so the tag now ships separately in `/usr/share/mountnas/release` and is displayed everywhere. This also fixes `nas upgrade --check`, which compared the GitHub *tag* against the *build id* and therefore always claimed a new release existed.

### Added
- **`nas rollback [--list | <n>]`** — the config time machine. lbu already kept the last few committed overlays on `/cfg`; now they're listed (dates/sizes) and restorable with a crash-safe swap that applies at the next boot, keeping the replaced config available for rolling forward. Recovering from a bad commit no longer means pulling the stick and hand-editing tarballs.
- **`nas changes --diff`** — unified diffs of every unsaved file against the committed overlay: review exactly what a commit would persist.
- **`nas status --json`** and **`nas disks --json`** — machine-readable output for monitoring/dashboard integrations, built from the same code paths as the human output.
- **Meaningful exit codes:** `nas status` exits 1 when any `[FAIL]` fired (0 otherwise) — usable directly as a cron/monitoring probe.
- **Boot-USB guard:** `nas status` now FAILs loudly if any data fstab entry resolves to the boot USB itself — the one unrecoverable user error (formatting/mounting the running OS media).
- **Sensors in `nas status`:** CPU temperature, fan speeds, and per-disk temperatures (standby-safe — never wakes a sleeping drive), in a compact section; VMs get a quiet "(no sensors)" line.
- **`nas logs`** with **opt-in persistent logging**: `--persist on` moves syslog to `/mnt/nasdata/logs` with rotation, so a crash or power cut finally leaves history behind (RAM-only logs vanish exactly when you need them). Documented tradeoff: periodic writes keep that disk awake. The supervisor restarts syslogd after the data disk mounts so the target always exists.
- **`nas howto <topic>`** — the README's recipes (disks, pool, parity, luks, mail, backup, upgrade, logs, vpn) available offline on the box.
- **Per-command help** (`nas <cmd> --help`, `nas help <cmd>`) with examples, and **tab completion** for bash and zsh.
- **Scripting flags:** `nas upgrade --yes`, `nas reboot|shutdown --yes|--save` — the interactive gates stay the default for humans.

### Changed
- **`nas disks` fits a terminal now:** two lines per disk (dashed header with name/size/bus/type/temp, identity beneath) and two per partition (identity/mount, then the 36-char UUID on its own line) instead of 120+-column rows. Same data.
- `nas status` header shows `hostname.local` beside the hostname; `[ OK ]/[WARN]/[FAIL]` tags are color-coded on a terminal (plain in pipes/logs, `NO_COLOR` honored).

## [alpha-6] — 2026-07-06

### Added
- **LUKS disk encryption** (`cryptsetup` + the `dmcrypt` boot service, off by default): mdadm and LVM shipped but encrypted data disks did not — and dm-crypt is needed at mount time, exactly when a box may be offline. Keyfile-based unlock before `localmount`; README "Encrypted data disks (LUKS)" documents the flow and the honest threat model.
- **Working email alerts** (`msmtp` + `mailx`): the image previously had *no mail transport*, so smartd's notifier had nowhere to send. `mail(1)` is pre-wired to msmtp; a commented `/etc/msmtprc` template (mode 0600) ships, and the seeded `smartd.conf` shows the one-liner. Works from cron too (SnapRAID reports).
- **restic**: encrypted, deduplicated, versioned backups to local disks, SFTP, S3, or any rclone remote — rclone syncs, restic backs up. The one real size cost (~14 MB static binary).
- **Recovery & media testing**: `testdisk` (partition recovery + PhotoRec undelete) and `f3` (counterfeit/failing flash detection) — recovery tools must already be on the box when the disaster happens.
- **Plain WireGuard** (`wireguard-tools`: wg + wg-quick) alongside Tailscale/ZeroTier; the kernel module was already in linux-lts.
- **Small QoL tools**: `zstd`/`lz4`/`xz` (full compressors; busybox only decompresses), `xxhash` (fast copy verification), `fdupes` (duplicate hunting after consolidating old drives).

Net cost: ~16 MB of packages against the ~130 MB alpha-5 saved. The upgrade smoke test runs **blocking** for the first time this release (alpha-5 → alpha-6).

## [alpha-5] — 2026-07-06

### Fixed
- **Boot-hang guard for network filesystems.** A dead NFS/CIFS declared as `/mnt/nasdata` could stall the `mountnas` service — and with it the whole default runlevel, which busybox init finishes *before* starting the gettys: no console login at all. The supervisor now refuses network filesystems for the system disk (new `netfs` state, explained by `nas status` and the login banner), and the README documents that network filesystems in fstab are never mounted at boot.
- **UEFI boot menu waited 30 s** at every boot (grub counts whole seconds where syslinux counts tenths); both are 3 s now.
- **`nas backup` is Ctrl-C-safe.** An interrupt used to strand `/cfg` read-only — breaking every later `nas commit` long after the cause was forgotten — and leave a partial backup file behind; both are cleaned up now, and a failed rw remount is reported instead of swallowed.
- **The upgrade's world reconcile survives a zero-byte `world.base`** (FAT truncates files to zero on power loss). Previously the awk `NR==FNR` idiom silently dropped every user-installed package from world.
- **`nas` exits with the command's status.** The prompt-cache refresh ran last and masked every failure from scripted callers (`nas commit && …` chains, the CI tests).
- Hostname validation rejects leading/trailing hyphens, and after a rename avahi + the console banner track the new name immediately instead of after a reboot.

### Changed
- **Near-atomic upgrades.** `nas upgrade` now stages *every* payload under temp names first — the slow copies happen while the old system is still intact and bootable, and a staging failure aborts with the USB untouched — then commits with back-to-back renames. Previously a power cut mid-write could leave a new kernel beside an old modloop (an unbootable module mismatch) because minutes of copying sat between renames. A failed directory swap-in now restores the old tree (e.g. `/apks`, required for boot) instead of leaving it missing.
- **Early CPU microcode** (`amd-ucode` + `intel-ucode`) ships on the boot media and is prepended to the initrd by both bootloaders — CPU errata fixes for exactly the repurposed desktop/NUC hardware MountNAS targets. `nas upgrade` carries the images forward like the other payloads.
- **The image is 3.5 GiB raw (was 6 GiB) and fits real-world "4 GB" sticks.** BOOT 2.5 GiB (~2× the current payload), MNASCFG ~1 GiB (overlay + the apk cache). `nas backup` reads ~40% less from the stick, and the upgrade temp-space precheck drops from 7 GiB to ~3.75 GiB. Existing 6 GiB sticks upgrade fine — upgrades replace files, never partitions. The build log now prints a BOOT size report so size regressions are visible per build.
- **~140 MB smaller image:** the `linux-lts` apk is no longer cached in the on-media repo — nothing could ever install it (the kernel boots from `/boot` and updates via `nas upgrade`, never via apk).
- **Storage supervisor robustness:** waits up to 15 s for declared disks that are still enumerating (USB docks with staggered spin-up) and mounts late arrivals instead of placeholdering them; and runs a preen `e2fsck` on `/cfg` when its mount fails — power loss is the normal NAS failure mode, and nothing else ever fscks the config partition.
- **smartd no longer wakes sleeping disks:** the shipped `/etc/smartd.conf` uses `DEVICESCAN -n standby,q` (the stock default polled every 30 min with no power-state check, keeping NAS disks spinning 24/7).
- `pick-nic` gives PHYs a few seconds to assert carrier, so multi-NIC boxes pick the cabled port instead of whichever interface `/sys` lists first.

### Added
- **`data-watch`** (every 15 min via the stock periodic cron): flips the storage state when the system disk vanishes at runtime or its filesystem goes read-only from errors — previously `nas status`, the prompt, and the banner all said "ok" forever after a runtime disk loss. Detection only: services are deliberately left alone so a transient USB reset cannot take Docker down.
- **CI: blocking supervisor smoke test.** QEMU + expect drives the whole first-install story on the freshly built image: the first-boot wizard end to end, `mkfs` + fstab + `rc-service mountnas restart`, docker + samba actually starting, a `[FAIL]`-free `nas status`, `nas commit`, then a reboot that must bring everything back on its own. (The upgrade smoke test stays non-blocking for this build — alpha-4 → alpha-5 is the first pair that can pass — and gets re-tightened after the first green run.)
- The console banner warns when RAM is below ~4 GB (the OS runs from RAM); the README states the 4 GB recommendation and the power-loss/commit interaction.

## [alpha-4] — 2026-07-06

### Fixed
- **In-place upgrade works (from this release onward).** The modloop-free step now
  copies only the **kernel modules** to RAM instead of the whole modloop (modules +
  firmware, which overflowed the RAM root on 4 GB machines and could wedge `lbu`
  until a reboot). Exact headroom is measured up front; a transient-busy unmount is
  handled. Because an upgrade runs the *installed* release's code, boxes on
  alpha-1/2/3 still need a one-time reflash — see UPGRADE.md "One-time migration".
- **Offline package installs.** The `mountnas` service never created the BOOT
  mountpoint, so the on-USB package repo was never exposed at runtime and `apk`
  silently depended on the network. Fixed; offline `apk add` (USB snapshot +
  `/cfg` cache) now works as designed.

### Changed
- **Firmware: curated consumer-x86 set** (~365 MB vs 756 MB full) matched to
  repurposed laptops/desktops/NUCs/mini-PCs: GPU (Intel i915/xe, AMD amdgpu/radeon,
  Nvidia), wifi (Intel incl. Bluetooth, MediaTek, Atheros ath6k–ath12k, Broadcom,
  Cypress, Realtek rtw88/rtw89/rtlwifi), Bluetooth (qca, rtl_bt, ar3k), wired NICs
  (rtl_nic, tigon, bnx2, e100), laptop platform (cirrus, amd, amdnpu, dell, hp,
  lenovo, synaptics). The previous list missed common consumer firmware (Realtek
  NIC/wifi, Intel GPU, Bluetooth) and shipped an empty `realtek` stub. Anything
  else can be added on a running box — README "Adding firmware for other hardware"
  (verified to install early in boot, before device probing).

### Docs
- UPGRADE.md: one-time migration path from alpha-1/2/3 with config carry-over.
- README: firmware-addition guide; troubleshooting entries for custom
  `/etc/init.d` scripts (lbu does not track them — `lbu include` once) and for
  `tar: empty archive` commits (full RAM root).

## [alpha-3] — 2026-07-06

- **New baked-in packages:** `zsh` (alternate login shell) and `mosh` (roaming,
  low-latency remote shell over UDP). No new services — `mosh-server` is spawned
  per session over SSH, and `zsh` is opt-in via `chsh`. This release exists mainly
  to exercise the in-place upgrade path (alpha-2 → alpha-3 adds two packages, which
  the `nas upgrade` world-reconcile should install while preserving your config).

## [alpha-2] — 2026-07-06

The improvements below were previously listed under "Unreleased".

### Fixed
- **Upgrade no longer corrupts `/etc/apk/world`.** `world.base` erroneously carried bare `linux-firmware` (not resolvable from the boot media), which the first `nas upgrade` injected into every box's world. Both world lists are now generated by one shared script (`scripts/mkworld.sh`) and CI asserts they match.
- `nas upgrade` cleans up its temp files and loop device on Ctrl-C/kill (previously leaked up to ~8 GB on the data disk).
- `nas disks` no longer `eval`s lsblk output — a filesystem label containing shell syntax could run as root; parsing now goes through `lsblk -J` + `jq`.
- Upstream source checksums (snapraid, mergerfs, zerotier-one) are committed and actually verified by CI instead of being regenerated per build.

### Changed
- `nas upgrade` also refreshes the bootloader payload (grub EFI core + modules, `ldlinux.c32`) so long-upgraded sticks don't skew loader vs. system.
- `nas backup` verifies the written image (`gzip -t`) before recording it.
- `nas setup` disables empty-password SSH logins automatically once a root password is set.
- Kernel cmdline has a single source (`scripts/cmdline.base`); `write-bootcfg` refuses to guess when it's missing instead of silently falling back.
- Alpine **main/community repositories are enabled** on the live system, pinned to the release's Alpine version, with the apk cache on the config partition — `apk add <pkg>` + `nas commit` now persists across reboots, even offline. `nas upgrade` re-pins the repo version to match the new release.
- CI: shellcheck runs on every push; lint targets are auto-discovered; `aports_ref` is derived automatically; third-party actions are pinned by commit SHA; and a new **upgrade smoke test** boots the previous release in QEMU and drives a real `nas upgrade` to the freshly built image before anything is published.

### Added
- `nas changes` (alias `nas changed`) — list exactly what `nas commit` would save.
- `nas upgrade --check` — ask GitHub whether a newer release is published; prints the exact upgrade command.
- `nas report` — secrets-free diagnostics bundle for bug reports.
- `nas disks` — per-disk hardware header (vendor, model, serial, firmware, bus, HDD/SSD, temperature — without waking sleeping drives) with partitions indented beneath (fstype, label, UUID, mountpoint, free space); paste-ready fstab lines end with the drive's model + serial for physical identification.
- `nas status --deep` validates fstab with `findmnt --verify`.

## [1.0.0-alpha] — 2026-07-01

Initial alpha release of MountNAS — a diskless Alpine NAS that runs entirely from RAM off a USB stick.

- **Diskless, single-image OS.** One `.img.gz` file serves as both the fresh-install image and the upgrade payload. The OS rebuilds in RAM from packages + an overlay on every boot; only configuration persists.
- **Single-slot in-place upgrades.** `nas upgrade` rewrites the OS on the USB without rebooting, preserving your config and data disks. Full-image backups via `nas backup` serve as the rollback net.
- **Storage supervisor.** The `mountnas` service holds Docker/Samba/NFS until the primary data disk mounts, preventing RAM fill if a disk is missing or fails. Read-only placeholders over failed data disks prevent accidental writes to the wrong place.
- **The `nas` CLI.** Unified command-line control: setup, status checks, disk discovery, mounts, backups, upgrades, commit/persist, power management.
- **First-login wizard.** Auto-running `nas setup` handles hostname, root password, timezone, and network config. SSH keys install from the BOOT partition for headless first-boot access.
- **Built-in tools for NAS workloads.** SnapRAID (parity), mergerfs (pooling), Docker, Samba, NFS, ZeroTier, Tailscale, smartmontools, mdadm, LVM, filesystems (ext4, xfs, btrfs, F2FS, exFAT, NTFS), and network diagnostics.
- **Automated CI validation.** Shell script linting and QEMU boot testing under both BIOS and UEFI firmware ensure every release is bootable before it ships.
- **Power-user scaffolding.** Progress bars for long operations, persistent backup timestamps, upgrade URLs with checksum verification, smart fstab suggestions, immediate network apply.
