# Changelog

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
