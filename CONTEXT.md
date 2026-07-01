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
  single-slot `.img.gz`.
- **Boot: bootloader verified, full boot pending.** Proxmox/SeaBIOS bring-up peeled
  back three layers — hang at `Booting from Hard Disk…` (no GPT legacy-boot), then
  `This is not a bootable disk` (no syslinux VBR), then `/sbin/init not found`
  (repo not discovered). All addressed (§6); the box now reaches the diskless init.
  Full boot-to-login (and the new single-slot upgrade) is unverified pending a
  rebuild + test (§8).
- **Single deliverable** = `mountnas-<tag>.img.gz` (write to USB with Etcher/dd for a
  fresh install; the same file is what `nas upgrade` consumes). See §4.

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
  All editable defaults (`fstab`, `sshd_config`, `smb.conf`, `inittab`, runlevels, …)
  live in `genapkovl-mountnas.sh` and are user-owned via lbu.
- **No `x-mount.mkdir` (or `X-mount.mkdir`) in fstab.** Both are util-linux (libmount)
  *userspace* options that libmount strips before the syscall — but busybox `mount`
  (which runs `localmount` at early boot) implements neither and forwards them to the
  kernel, which rejects them → `ext4: Unknown parameter 'x-mount.mkdir'` at ~3s. The
  capital-X spelling does NOT help (busybox fails on it identically). Do NOT re-add
  either. Mountpoints are guaranteed a different way: the **`mountnas-mkdirs`** service
  runs `before localmount` and `mkdir -p`s every `/cfg` and `/mnt/*` target from
  `/etc/fstab`, so plain busybox `mount` can then mount them. A mount that still fails
  is handled at runtime by the `mountnas` service (ro placeholder + service gating).
- **Explicit `/etc/inittab`** ships a getty on **tty1** (VGA / Proxmox noVNC) *and*
  **ttyS0** (serial / `qm terminal`) so both consoles get a login prompt regardless of
  the packaged default. **The `console=` cmdline devices MUST match those getty ids
  (`console=tty1 console=ttyS0`).** The diskless initramfs auto-appends a getty (comment
  `# enable login on alternative console`) for any `console=` with no inittab entry;
  `console=tty0` (tty0 = the active VT = the VGA VT1) therefore appended a *second*
  getty on the same noVNC screen as the tty1 getty — two prompts fighting over input,
  login impossible. Using `console=tty1` makes the appender find tty1 already present
  and add nothing. This is the real cause of "can't log in on the Proxmox graphical
  console" (the earlier securetty/getty theories were wrong).
- **Single-slot: one OS on the BOOT (FAT/ESP) partition; config on `MNASCFG` (ext4).**
  BOOT holds the native diskless layout (`/boot`, `/apks`); overlay is found by
  **label** (`ovl_dev=LABEL=MNASCFG`), not a UUID. `nas upgrade` rewrites BOOT in
  place (via `copy-modloop`); rollback is a full-image `nas backup` (see §4a). The
  old A/B two-slot scheme was removed — it only existed to dodge the busy-modloop
  problem, which `copy-modloop` solves directly.
- **Data services (docker/samba/nfs) are NOT in any runlevel.** The `mountnas`
  service starts them only once `/mnt/nasdata` is mounted. Do not `rc-update add`
  them — `nas status` flags it.
- **`mountnas` service = `nas` CLI separation:** the service is `mountnas` so
  `rc-service mountnas …` never collides with the `nas` command.

---

## 4. The artifacts (what each is for)

The CI publishes a **GitHub Release** (not a zip — see §6) with:

| File | Purpose |
|---|---|
| `mountnas-<tag>.img.gz` | **The product — ONE image for everything.** Single-slot image (BOOT + MNASCFG). Write to USB for a fresh install, OR pass to `nas upgrade` to update in place (it loop-mounts partition 1 for the new boot files). Self-contained: the seed overlay is baked onto MNASCFG. |
| `mountnas-<tag>.rsa.pub` | The per-build package signing key (see §7 caveat). |
| `SHA256SUMS` | Checksums of the above. |

There is **no separate `-upgrade.img`** anymore — the full `.img.gz` is the upgrade
payload too (removed the iso9660 + its xorriso `world.base` embed step).

**The seed `.apkovl.tar.gz` is intentionally NOT published.** It's baked into the
`.img` (MNASCFG) so the image is self-contained; it has no standalone consumer.

### 4a. Upgrade + backup model (single-slot)

- **`nas upgrade <img.gz>`** rewrites BOOT **in place**: warn+`YES` gate → free-space
  precheck → unpack + loop-mount the image's p1 → **`copy-modloop`** (moves modules to
  RAM, detaches the live modloop so it's overwritable) → overwrite `/boot`+`/apks`+
  `world.base` (temp-name then rename = crash-safe) → reconcile `/etc/apk/world`
  (new base ∪ user extras) → `write-bootcfg` + `lbu commit` → reboot. Config/data
  untouched. **No automatic rollback.**
- **`nas backup`** images the WHOLE USB (`gzip < /dev/<usb>`) to a file (default
  `/mnt/nasdata/backups`, or `--to`). It briefly remounts `/cfg` ro for a consistent
  image. This is the rollback net: recovery = write the image to another USB and boot.
  It does NOT cover data disks/Docker (separate storage). Records `$STATE/last-backup`,
  which the upgrade gate surfaces.
- `nas restore` and the per-commit config-snapshot subsystem were **removed** — the
  full image covers them.

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

**Single-slot BOOT layout.** `setup-bootable` lays down the native diskless layout —
kernel/initramfs/modloop under `/boot`, the apk repo under `/apks` (with its own
`.boot_repository` marker). We keep it as-is and assert the three boot files +
`apks/x86_64/APKINDEX.tar.gz` landed (**no `|| true`** — a `setup-bootable` layout
change fails the build). We `touch "$M/apks/.boot_repository"` to guarantee the marker.
(The old build moved everything into `A/…` and embedded `world.base` into a separate
upgrade ISO via `xorriso`; both are gone with A/B and the single-image release.)

**Boot-repository discovery.** The diskless init installs the base userspace into the
RAM root at boot by discovering the on-media apk repo — it scans `/media/*` for a
**`.boot_repository`** marker (`find_boot_repositories`) and uses the real path it
finds. The cmdline must be `alpine_repo=auto`: a literal path is used verbatim (fails,
not under `/media`) and disables the marker scan. Getting it wrong →
`opening /apks/x86_64/APKINDEX.tar.gz: No such file` → `0 packages` →
`/sbin/init not found in new root` → initramfs emergency shell.

**Dual-firmware boot (BIOS + UEFI).** The BOOT partition is a GPT ESP (`ef00`).
**`setup-bootable` does NOT make this image bootable** — it installs syslinux only
when handed a *device*, but we hand it the mounted *directory*, so it just copies
files and the partition keeps its dosfstools dummy VBR. Nothing installed a UEFI
loader either. The bring-up symptoms came in this order, each a layer deeper:
1. SeaBIOS `Booting from Hard Disk…` then **hang** — no legacy-boot setup on GPT.
2. After adding the legacy attribute + `gptmbr.bin`: **`This is not a bootable
   disk`** — gptmbr now chainloaded the partition, but its VBR was the dosfstools
   dummy (no syslinux VBR).
3. Fixed by installing the syslinux VBR ourselves.

Both loaders are installed explicitly, split by whether the FAT must be mounted:
- **Legacy BIOS** (`SeaBIOS → gptmbr → BOOT VBR → syslinux → syslinux.cfg`):
  `sgdisk --attributes=1:set:2` flags the partition legacy-bootable; **unmounted**,
  `syslinux --install ${LOOP}p1` writes the VBR + `ldlinux.sys`, and `dd …gptmbr.bin`
  puts GPT-aware MBR code in the protective MBR (overwriting setup-bootable's plain
  `mbr.bin`). **Mounted**, we first `cp ldlinux.c32` to the FAT root — syslinux 6.x
  chains `ldlinux.sys → ldlinux.c32`, which must sit beside it or boot aborts with
  `Failed to load ldlinux.c32`.
- **UEFI** (OVMF): **mounted**, `grub-install --target=x86_64-efi --removable
  --no-nvram` lays the grub core at `/EFI/BOOT/BOOTX64.EFI` (removable fallback
  path, no NVRAM entry needed) + modules under `/boot/grub`. It does *not* write the
  config — it loads the hand-written `/boot/grub/grub.cfg` from `write-bootcfg`.
- (`grub`/`grub-efi`/`syslinux` are host build deps only; nothing is added to the
  image's world set — the loaders live solely on the FAT partition.)

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
a bootable ISO + apks cache; `.img` partitions/mkfs/setup-bootable/single-slot layout
complete; Release publishing wired. On Proxmox the dual-firmware bootloader works —
SeaBIOS gets past the earlier hang / "not a bootable disk" into the Alpine diskless
init, which found the repo once `.boot_repository` + `alpine_repo=auto` were in place.

**Open / next (in priority order):**
1. **Boot-test the `.img.gz` to a login prompt** (Proxmox SeaBIOS *and* OVMF, and real
   USB). Confirm the single OS boots, the seed overlay applies (root-owned, doas works),
   and `mountnas` holds then releases docker/samba/nfs around `/mnt/nasdata`; and that
   `command -v copy-modloop` is present. The single most important unverified thing.
2. **Validate the single-slot upgrade + backup (§4a).** `nas backup` → a valid
   `mountnas-backup-*.img.gz`; `nas upgrade <img.gz>` → warn+`YES` gate, free-space
   precheck, `copy-modloop`, crash-safe in-place overwrite, world reconcile, reboot into
   the new version with **config + a user-added package preserved**; then a restore drill
   (write the backup image to a second USB and boot it).
3. **Boot-module breadth (addressed, verify).** The cmdline loads
   `…,ahci,nvme,virtio_pci,virtio_scsi,virtio_blk` on top of the USB-stick set so a VM
   disk (Proxmox defaults to VirtIO SCSI) is found at boot. The list is kept in sync
   across **three** places — `mkimg.nas.sh`, the `.img` `cmdline.base` echo in
   `build.yml`, and the `write-bootcfg` fallback default; change all three together.
4. The rest of the plan's "assumptions to validate on first build" (its §11).

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
- `README.md` — user-facing docs. `UPGRADE.md` — single-slot in-place upgrade + backup docs.
- Build host base: Alpine **latest-stable (v3.24)**, `jirutka/setup-alpine`, `abuild`.
