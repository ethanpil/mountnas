# CONTEXT.md — MountNAS evolution & working notes

Companion to the design spec (`mountnas-dev-plan.md`, originally in
`~/Downloads/files/`). The plan describes the *intended* design; this file records
**what actually got built, what diverged from the plan, the non-obvious lessons,
and what still needs doing.** Read this before changing the build or the packages —
most of the CI steps look arbitrary but each fixes a specific, hard-won failure
that will silently regress if "cleaned up" without understanding it.

---

## 1. Status at a glance

- **Build: GREEN.** The GitHub Actions workflow assembles everything end-to-end:
  builds the 4 local apks, runs `mkimage` to produce the ISO, and assembles the
  two-slot `.img.gz`.
- **Boot: NOT yet verified.** No successful QEMU/hardware boot has been confirmed.
  First `.img` boot attempt (Proxmox/SeaBIOS) hung at `Booting from Hard Disk…`:
  the GPT image had no legacy-BIOS boot setup and no UEFI loader. **Now fixed** —
  the image is built for both BIOS and UEFI (see §6, "Dual-firmware boot"), but the
  fix is unverified pending a rebuild + boot test (§8).
- **Primary deliverable** = `mountnas-<tag>.img.gz` (write to USB with Etcher/dd).
  The `-upgrade.img` is only for `nas upgrade`. They are different things — see §4.

---

## 2. Repository layout (current)

```
mountnas/
├── packages.list                     # world set (incl. local apks)
├── scripts/
│   ├── mkimg.nas.sh                  # mkimage profile (kernel cmdline, apks)
│   └── genapkovl-mountnas.sh         # seed overlay (world, runlevels, /etc config)
├── mountnas-tools/                   # LOCAL apk: the nas CLI + services (noarch-ish)
│   ├── APKBUILD
│   └── files/                        # the actual scripts (NOT src/ — see §6)
│       ├── nas, mountnas, mountnas-net,
│       ├── mountnas-sshkey, mountnas-issue, write-bootcfg, gen-issue,
│       ├── issue-ifupdown, profile-nas-{welcome,aliases,prompt}.sh
├── snapraid/        APKBUILD          # LOCAL apk: compiled from source
├── mergerfs/        APKBUILD          # LOCAL apk: repackaged upstream static binary
├── zerotier-one/    APKBUILD + zerotier-one.initd   # LOCAL apk: repackaged + init script
├── .github/workflows/build.yml       # the whole build pipeline (heavily iterated)
├── README.md  UPGRADE.md  CONTEXT.md  LICENSE
```

There are **four locally-built apks**, all signed by the per-build key and served
from the on-media local repo: `mountnas-tools`, `snapraid`, `mergerfs`,
`zerotier-one`. They are excluded from the upstream preflight resolve and are why
several CI steps exist.

---

## 3. Architecture invariants (do not break)

- **Code in the apk, editable config in the seed overlay.** Diskless applies the
  overlay *before* packages install, so anything an apk writes to `/etc` would
  clobber user config every boot. `mountnas-tools` ships only code
  (`/usr/sbin`, `/etc/init.d`, `/usr/libexec`, lbu-excluded `/etc/profile.d`).
  All editable defaults (`fstab`, `sshd_config`, `smb.conf`, runlevels, …) live in
  `genapkovl-mountnas.sh` and are user-owned via lbu.
- **Two slots A/B on the BOOT (FAT/ESP) partition; config on `MNASCFG` (ext4).**
  Overlay is found by **label** (`ovl_dev=LABEL=MNASCFG`), not a UUID.
- **Data services (docker/samba/nfs) are NOT in any runlevel.** The `mountnas`
  service starts them only once `/mnt/nasdata` is mounted. Do not `rc-update add`
  them — `nas validate` flags it.
- **`mountnas` service = `nas` CLI separation:** the service is `mountnas` so
  `rc-service mountnas …` never collides with the `nas` command.

---

## 4. The artifacts (what each is for)

The CI publishes a **GitHub Release** (not a zip — see §6) with:

| File | Purpose |
|---|---|
| `mountnas-<tag>.img.gz` | **The product.** Two-slot image (BOOT + MNASCFG). Write to USB. Self-contained: the seed overlay is baked onto MNASCFG. |
| `mountnas-<tag>-upgrade.img` | **Upgrades only** (`nas upgrade <upgrade.img>`). The plain mkimage iso9660 of the OS + embedded `world.base`, renamed from `.iso` so it isn't mistaken for a bootable install medium. `nas upgrade` loop-mounts it (fs detected by content). No MNASCFG, no slot structure — booting it alone gives plain diskless Alpine with no config. |
| `mountnas-<tag>.rsa.pub` | The per-build package signing key (see §7 caveat). |
| `SHA256SUMS` | Checksums of the above. |

**The seed `.apkovl.tar.gz` is intentionally NOT published.** It's baked into the
`.img` (MNASCFG) so the image is self-contained; it has no standalone consumer (the
auxiliary `nas-make-usb` path that once used it was removed).

---

## 5. Divergences from the original plan (packages)

The plan's `packages.list` had several names that don't exist / aren't in
latest-stable. Corrected:

- `cgdisk` — **removed** (provided by `gptfdisk`, not its own package).
- `sgdisk` — **added as its own package** (split out of `gptfdisk`; NOT included by
  `gptfdisk`). Used by CI to lay out the `.img` GPT (installed on the build host);
  kept in `packages.list` only for manual on-device disk partitioning — no shipped
  tool uses it anymore (the `nas-make-usb` consumer was removed). Droppable if that
  admin convenience isn't wanted.
- `gddrescue` → **`ddrescue`**; `ntfs-progs` → **`ntfs-3g-progs`**.
- `nvtop`, `sdparm`, `curlftpfs` — **removed** (not in v3.24).
- `zerotier-one` — not in Alpine at all → built locally (§7).
- `-openrc` name fixes: `openssh-server-openrc` → **`openssh-server-common-openrc`**;
  `samba-openrc` → **`samba-server-openrc`**.
- `sysstat-openrc` — **removed**: sysstat has **no OpenRC service** on Alpine (no
  `/etc/init.d/sysstat`). Also removed `rc_add sysstat` from `genapkovl`. The
  `sysstat` package stays (sar/iostat tools).
- `snapraid` — only in **edge/testing** → compiled from source (`snapraid/APKBUILD`,
  pinned to a release tag; bump `pkgver` to update).
- `mergerfs` — edge-only and unsafe to pull a prebuilt edge apk onto stable
  (libstdc++ ABI). Upstream ships **fully-static** binaries → repackaged into a
  local apk (`mergerfs/APKBUILD`).

The CI **preflight** (`apk add --simulate`) excludes all four local packages
(`mountnas-tools|snapraid|mergerfs|zerotier-one`) since they aren't upstream.

---

## 6. CI/build pipeline — the non-obvious fixes (DO NOT REGRESS)

Everything below is in `.github/workflows/build.yml`. Each line fixes a real
failure encountered during bring-up.

**Version match.** `alpine_branch=latest-stable` (= v3.24 now), and **`aports_ref`
MUST match** (`3.24-stable`). A `mkimage.sh` from the wrong aports version fails
against the installed apk-tools. Bump both together on a new Alpine release.

**Non-root build user + GitHub runner restrictions** (the big class of failures):
- **Unprivileged userns is blocked on ubuntu-24.04 runners** → apk's package-script
  sandbox (`unshare`) fails with `Operation not permitted`. Fixed by a host step:
  `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`. This unblocks
  *all* non-root apk scripts (the check, abuild, mkimage).
- **`abuild-keygen -i`** wants `doas` (not installed) → we run `-an` and `cp` the
  pubkey to `/etc/apk/keys` as root.
- **`abuild -r` installs build deps via apk = needs root.** Build runs as the
  non-root `build` user → we install **doas** (`permit nopass keepenv build`);
  abuild shells out to it. (`-r` installs both make- *and* regular depends.)
- **The init-script check** uses `apk add --root checkroot --initdb` as non-root →
  needs `--usermode`, plus `--repositories-file /etc/apk/repositories
  --allow-untrusted --no-scripts` (fresh root has no repos/keys; we only verify
  that `/etc/init.d/<svc>` files exist).
- **`genapkovl` runs under `fakeroot`** so its `chown root:root` succeeds; otherwise
  overlay files carry the build uid and **doas rejects `/etc/doas.conf`** at runtime.

**abuild quirks for the local packages:**
- **`mountnas-tools` source must NOT live in `src/`.** abuild's `$srcdir` *is*
  `$startdir/src` and abuild **wipes it** before `package()`. The files live in
  `files/`, `package()` reads from `$startdir/files/…`, `builddir="$startdir"`,
  `build()` is a no-op.
- **`mountnas-tools` arch must be `x86_64`, not `noarch`.** apk fetches a noarch
  package from `<repo>/noarch/…`, which doesn't exist in a local abuild repo (it
  builds into `<repo>/x86_64/`) → `mkimage` can't find it.
- **Maintainer must be RFC822** (`Name <email>`), or `abuild` aborts validation.
- **Man pages must be gzipped or split into `-doc`.** We just `rm -rf
  $pkgdir/usr/share/man` (snapraid/mergerfs) — appliance, no man needed.
- **Repackage `package()` must `mkdir -p "$pkgdir"`** before `cp` (`install -D` /
  `make install` create it; plain `cp` does not).

**mkimage:**
- **It does NOT inherit the host apk repos.** Pass them explicitly: build
  `--repository` args from `/etc/apk/repositories` *plus* `--repository
  $HOME/packages/repo` (the local repo), else `linux-lts`/`alpine-base`/… don't
  resolve.
- **It verifies package signatures against its *own* `$APKROOT/etc/apk/keys`**, which
  trusts our build key (local packages pass) but not arbitrary keys. This is why
  ZeroTier is **repackaged under our key** instead of trusting the foreign key (§7).

**ISO post-processing (two interacting traps):**
- `setup-bootable` streams the source ISO through **`uniso`** (can't seek). Any
  post-mkimage modification re-lays-out the ISO → `uniso` errors "non-linear reads".
  So **embed `world.base` AFTER `setup-bootable` has consumed the clean ISO.**
- Embedding with plain `xorriso … -commit` **discards the El Torito boot image**
  → the ISO no longer boots (`isolinux: could not read from cdrom (0004)`). Must use
  **`xorriso -indev … -outdev … -boot_image any replay -map world.base …`** to
  preserve the isohybrid/El-Torito boot.

**Slot-A layout (hardened).** `setup-bootable` copies the ISO's `boot/` + `apks/`
to the BOOT partition; we then `mv` kernel/initramfs/modloop into `A/boot/` and
apks into `A/apks/`. This now has **no `|| true`** and asserts the three boot files
landed — a layout change in `setup-bootable` fails the build instead of shipping an
empty slot A.

**Dual-firmware boot (BIOS + UEFI).** The BOOT partition is a GPT ESP (`ef00`),
and `setup-bootable` only handles the syslinux side — it does **not** make a GPT
disk legacy-bootable, and nothing installed a UEFI loader. A SeaBIOS VM (Proxmox's
default) therefore printed `Booting from Hard Disk…` and hung forever. Both paths
are now set up explicitly:
- **Legacy BIOS:** `sgdisk --attributes=1:set:2` sets the *legacy BIOS bootable*
  attribute on the BOOT partition, and we `dd` syslinux's **`gptmbr.bin`** (the
  GPT-aware MBR code, not `mbr.bin`) into the protective MBR — done **after**
  `setup-bootable`, which writes the wrong `mbr.bin` we overwrite. SeaBIOS →
  gptmbr → syslinux VBR (installed by `setup-bootable`) → `syslinux.cfg`.
- **UEFI:** `grub-install --target=x86_64-efi --removable --no-nvram` lays the
  grub core image at `/EFI/BOOT/BOOTX64.EFI` (the removable fallback path OVMF
  boots with no NVRAM entry) plus modules under `/boot/grub`. It does *not* write
  the config — it loads the hand-written `/boot/grub/grub.cfg` from `write-bootcfg`.
  (`grub`/`grub-efi`/`syslinux` are already host build deps; nothing is added to the
  image's own world set — the loaders live only on the FAT partition.)

**busybox ash strictness.** The big build step runs under busybox `ash` (stricter
than bash about `set -eu`). Two recurring bugs:
- **Apostrophes inside a `su … -c '…'` block** close the single quote early →
  `syntax error: unexpected "("`. Keep comments/strings inside that block
  apostrophe-free. (The `'"$VAR"'` injection pattern is the only intentional
  quoting; it must stay balanced/even.)
- Best-effort sub-logic should be wrapped so it can't abort the build (we learned
  this on a now-removed ZeroTier key step: `( set +eu … ) || true`).

**Artifacts.** `actions/upload-artifact` **always zips** everything into one file.
For individually-downloadable, standalone files we publish a **GitHub Release**
(`softprops/action-gh-release@v2`, `files: out/*`) — which requires
`permissions: contents: write` on the job.

---

## 7. ZeroTier specifics

- Source: `ethanpil/ZeroTierOne-AlpineLinux-Binaries` (the maintainer's own repo of
  prebuilt Alpine apks). Pinned to a release tag in `zerotier-one/APKBUILD`; **bump
  `pkgver`** to update.
- We **repackage** that apk's payload (`tar -xzf` the apk, copy `usr/`) into a fresh
  apk **signed by our build key**, because:
  1. The upstream apk is signed with a per-build key (`.SIGN.RSA.builder-XXXX`) that
     neither `mkimage`'s `$APKROOT` keystore nor the booted image trusts. Trusting a
     foreign key in both places is fragile; signing under our key is the same trust
     path as the other local packages.
  2. **The upstream apk ships only the binaries — no init script.** We add
     `zerotier-one.initd` so `rc-service zerotier-one` works (it's off by default;
     `var/lib/zerotier-one` is in the lbu include so node identity persists).
- It IS dynamically linked (depends `libstdc++`, `libssl`, `libcrypto`, `libgcc`,
  musl); abuild re-traces these automatically on repackage.

---

## 8. What's verified vs. open

**Verified:** full build assembles; all 4 local apks build & sign; mkimage produces
a bootable-intended ISO + apks cache; `.img` partitions/mkfs/setup-bootable/slot
layout complete; Release publishing wired.

**Open / next (in priority order):**
1. **Boot-test the `.img.gz`** (QEMU/Proxmox or real USB hardware) under **both
   SeaBIOS and OVMF** — verifies the dual-firmware boot fix (§6). Then confirms slot
   A boots, the seed overlay applies (root-owned, doas works), and `mountnas` holds
   then releases docker/samba/nfs around `/mnt/nasdata`. The single most important
   unverified thing. NB: on a VM this also surfaces the module-breadth risk in #4 —
   if the loader works but the kernel can't find root, that's #4, not the boot fix.
2. **Verify the fixed `.iso` boots** (the `-boot_image any replay` change).
3. **Validate the A/B upgrade flow** — the plan's highest-risk assumption: that the
   initramfs honors per-slot `modloop=/<slot>/…` + `alpine_repo=/<slot>/apks` on the
   cmdline. Test `nas upgrade <upgrade.img>` → reboot slot B → `--finish` / `--rollback`.
4. **Boot-module breadth (addressed, verify).** The cmdline now loads
   `…,ahci,nvme,virtio_pci,virtio_scsi,virtio_blk` on top of the USB-stick set so a
   VM disk (Proxmox defaults to VirtIO SCSI) can be found at boot. The list is kept
   in sync across **three** places — `mkimg.nas.sh` (ISO), the `.img` `cmdline.base`
   echo in `build.yml`, and the `write-bootcfg` fallback default; change all three
   together. Still unverified that the running kernel actually binds the VM bus;
   confirm during the boot test (#1).
5. The rest of the plan's "assumptions to validate on first build" (its §11).

**Known caveats:**
- **Per-build signing key is random** (`build-<hex>.rsa.pub`), published as
  `mountnas-<tag>.rsa.pub`. It changes every build. If reproducible verification or
  a stable trust anchor matters, switch to a committed/secret fixed signing key.
- `depmod: ERROR: fstatat(3, vmlinuz)` during the kernel step is **benign** (modloop
  builds/signs fine right after).
- The `apk index` "No provider for the dependencies" warning during local-repo
  signing is **expected** (the 4-package local index doesn't contain its stable
  deps; they resolve at install time).

---

## 9. How to cut a build

GitHub → Actions → **Build MountNAS** → Run workflow. Inputs: `release_tag`
(image filename + release tag), `alpine_branch=latest-stable`,
**`aports_ref=3.24-stable`** (must match the branch version), `arch=x86_64`.
Output: a GitHub Release tagged `<release_tag>` with the files in §4.

## 10. References
- `mountnas-dev-plan.md` — the design spec (commands, the `nas` CLI, UPGRADE model).
- `README.md` — user-facing docs. `UPGRADE.md` — A/B upgrade docs.
- Build host base: Alpine **latest-stable (v3.24)**, `jirutka/setup-alpine`, `abuild`.
