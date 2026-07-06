# Upgrading MountNAS

MountNAS runs from RAM off a USB stick. An upgrade **rewrites the operating system on
that stick in place**, then you reboot into the new version. Your **configuration**
(`/cfg` / the `MNASCFG` partition) and your **data disks** are never touched.

There is **one image** for everything: `mountnas-<tag>.img.gz`. Write it to a blank stick
for a fresh install, or hand it to `nas upgrade` to update an existing box.

---

## ⚠️ Read this first

Upgrading is the one operation that can leave a headless box unbootable. There is **no
automatic rollback** — your safety net is a full-image backup you make *before* upgrading.

- **Always run `nas backup` first**, and **copy the resulting image off this box** (to your
  PC, a NAS share, another USB). A backup that only lives on the box you're upgrading can't
  save you if the box won't boot.
- **Recovery = write that backup image to a *different* USB and boot it.**
- **NEVER boot with two MountNAS USB drives attached at once.** Both use the disk labels
  `BOOT` and `MNASCFG`; with two present the system can grab the wrong one. Remove the
  failed stick before inserting the backup.

`nas upgrade` refuses to proceed until you confirm you have a backup.

---

## Step by step

### 1. Back up the boot USB — REQUIRED

```
nas backup
```

This images the entire boot USB (OS + your saved config) to
`/mnt/nasdata/backups/mountnas-backup-<host>-<timestamp>.img.gz`. Use `nas backup --to
<dir-or-file>` to write it elsewhere (e.g. a mounted share). It does **not** back up your
data disks or Docker data — those live on separate storage.

**Copy the file off this box now.** From your PC, for example:

```
scp root@mountnas:/mnt/nasdata/backups/mountnas-backup-*.img.gz .
```

### 2. Get the new release image onto the box

Not sure whether a newer release exists? Ask from the box itself — it queries the
GitHub releases API and prints the exact upgrade command when one is published:

```
nas upgrade --check
```

Download `mountnas-<tag>.img.gz` from the release and place it where the box can read it —
e.g. copy it to the data disk:

```
scp mountnas-<tag>.img.gz root@mountnas:/mnt/nasdata/
```

You can hand `nas upgrade` either the compressed `.img.gz` (it decompresses to temp space
on the data disk) or an already-decompressed `.img`.

**Or skip this step entirely** and give `nas upgrade` the release URL directly — it
downloads to temp space on the data disk and, when the release's `SHA256SUMS` file sits
next to the image (GitHub releases publish it), verifies the checksum before proceeding:

```
nas upgrade https://github.com/<user>/mountnas/releases/download/<tag>/mountnas-<tag>.img.gz
```

### 3. Run the upgrade

```
nas upgrade /mnt/nasdata/mountnas-<tag>.img.gz
```

It will:

1. Show the upgrade warning and require you to type **`YES`** to confirm you have a backup.
2. Check there is enough temp space to unpack the image (aborts cleanly if not).
3. Unpack the image and mount its boot partition.
4. Run **`copy-modloop`** — Alpine's tool that moves the running kernel modules into RAM and
   detaches the live modloop, so the OS files on the USB can be rewritten safely.
5. Overwrite the boot files (`vmlinuz`, `initramfs`, `modloop`, the on-USB `apks` repo,
   `world.base`) in place, writing to temp names then renaming so an interruption can't
   corrupt the running system. The bootloader payload (grub's EFI core + modules,
   syslinux's `ldlinux.c32`) is refreshed the same way, so the loader never drifts
   behind the system it boots.
6. Reconcile `/etc/apk/world` so packages this release **added** are installed and packages
   it **dropped** are removed — while keeping any packages **you** installed yourself.
7. Re-pin the Alpine package repositories in `/etc/apk/repositories` to the new release's
   Alpine version (only the version part of the `dl-cdn` lines is touched — repositories
   you added yourself are left alone).
8. Regenerate the bootloader config and `nas commit` your configuration.

Nothing you rely on is touched until step 5, and if `copy-modloop` or the unpack fails
first, the box is left exactly as it was.

### 4. Reboot

```
nas reboot
```

The box boots the new version. Check it:

```
nas status      # shows the new version + storage config still sane
```

---

## If the upgrade fails or the new version misbehaves

There is no in-place rollback — recover from the backup you made in step 1:

1. Power down the box and **remove the MountNAS USB stick.**
2. On your PC, write your `nas backup` image to a **different** USB stick with
   [balenaEtcher](https://etcher.balena.io/) or `dd`:
   ```
   gzip -dc mountnas-backup-*.img.gz | sudo dd of=/dev/sdX bs=4M status=progress
   ```
   (Replace `/dev/sdX` with the target stick — double-check it.)
3. Insert **only** that stick and boot. You're back to exactly where you were when you made
   the backup — OS, config, and all.

Your data disks were never part of the upgrade or the backup, so they are unaffected.

---

## Notes

- **RAM.** `copy-modloop` holds the uncompressed kernel modules (~300–500 MB) in RAM until
  you reboot — fine on typical NAS hardware.
- **Temp space.** Unpacking a `.img.gz` needs room for the ~6 GB decompressed image on the
  data disk (or wherever `TMPDIR` points). `nas upgrade` checks this before doing anything.
- **Config safety.** Because `MNASCFG` is a separate partition, upgrading never risks your
  settings. The full-image backup captures OS *and* config together, so restoring it rolls
  both back consistently.
