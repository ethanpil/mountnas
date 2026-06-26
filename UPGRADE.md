# MountNAS — Upgrading the OS

MountNAS upgrades the operating system in place, from the running box, with a
one-keystroke rollback that is always available. Your **configuration partition
(`MNASCFG`) and your data disks are never touched** by an upgrade — only the OS
on the `BOOT` partition changes.

> **The `.img.gz` is for first install only.** Re-flashing it over a running NAS
> erases the config partition. Once a stick is in service, *always* upgrade with
> `nas upgrade` — never re-write the image.

---

## The two-slot (A/B) model

The `BOOT` partition holds **two complete, independent, bootable systems**, slot
**A** and slot **B**. Each slot has its own kernel, initramfs, modloop, local
`apks` repo, and `world.base` package manifest. The bootloader cmdline pins each
slot to its own files (`modloop=/<slot>/boot/modloop-lts`,
`alpine_repo=/<slot>/apks`), so the two never interfere.

**Both slots are always kept** — the current one and the previous one. An upgrade
stages the new system into the *inactive* slot and points the bootloader at it.
The slot you were running stays intact and becomes the rollback target, so a
downgrade is available at any time, not just inside a finalize window.

Because staging always writes the **non-running** slot, an upgrade can never
overwrite the system you are currently executing from, and the live modloop is
never modified — so the FAT32 "busy file" failure can't happen.

This is why the stick needs to be **8 GB or larger** (16 GB comfortable): the
shipped image is roughly one-slot-sized (slot B is empty and compresses away),
and the second slot fills on the first upgrade.

---

## Upgrading, step by step

You need only the new release's **`.iso`**. `world.base` travels inside the ISO,
so nothing else is required.

### 1. Stage the new system

```
nas upgrade <new.iso>
```

This mounts the `BOOT` partition read-write, confirms no slot switch is already
pending, then stages the new kernel, initramfs, modloop, `apks` repo, and
`world.base` into the **other** slot and points the bootloader's default at it.
Your current slot is left intact as the rollback target. It asks for confirmation
before writing anything; config and data are untouched.

### 2. Reboot into it

```
nas reboot
```

The box boots the newly staged slot: new kernel, new package versions, your
unchanged configuration, disks mounted, services running.

### 3. Verify

```
nas status
nas validate
```

Confirm the data disk is mounted, services are up, and your fstab/shares still
check out. If anything is wrong, see **Rolling back** below — you have not
committed to the new slot yet.

### 4. Finalize

```
nas upgrade --finish
```

This regenerates `/etc/apk/world`, installs only the genuinely new package names
(offline, from the slot's own local repo), runs `nas commit`, and marks the
current slot as active. **It does not delete the previous slot** — that stays as a
downgrade target.

How `world` is regenerated (so the upgrade applies what a release *added* **and**
what it *dropped*, while preserving packages you installed yourself):

```
user_extras = current /etc/apk/world  −  the OLD release's world.base
new world    = the NEW release's world.base  ∪  user_extras
```

Only names in the new world that aren't already installed are pulled, from the
slot's local repo. Version updates flow automatically from each slot's own repo,
so the base is never re-asserted by hand. If the previous release's `world.base`
is ever missing, finalize falls back to a union (add-only) so one of your packages
is never dropped by mistake — it just can't detect release removals that one time.

---

## Rolling back

A rollback is available at any time, by either route:

- **From the running system:**

  ```
  nas upgrade --rollback
  ```

  Points the next boot at the previous slot and offers to reboot immediately
  (closing the window where you're still living in the slot you're abandoning).

- **From the boot menu:** at power-on, pick the other `MountNAS (slot X)` entry.

Because both slots are kept, the previous version is always one reboot away.

---

## Guard rails

- `nas upgrade` and `nas upgrade --finish` **refuse to run while a slot switch is
  pending** — i.e. when the bootloader default no longer matches the running slot.
  They tell you to `nas reboot` first. This prevents staging from overwriting the
  slot the bootloader is about to boot, and prevents finalizing a slot you haven't
  actually booted.
- Staging **always targets the non-running slot**, so it can never overwrite the
  live system.
- `nas upgrade` refuses if the `BOOT` partition is missing its `.nas-boot` marker.
- `--rollback` offers an immediate reboot so you don't keep operating from the
  slot you're leaving.

---

## Validate before you trust it (recommended for a first build)

Per the build assumptions, the A/B slot pinning is the highest-risk piece. Before
relying on `nas upgrade` on real hardware, validate it in QEMU: boot the `.img`,
add a scratch data disk, confirm `mountnas` holds then releases services, then
manually stage slot B and confirm `nas upgrade --finish` and `nas upgrade
--rollback` behave as described above.
