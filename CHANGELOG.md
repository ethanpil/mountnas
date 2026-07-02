# Changelog

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
