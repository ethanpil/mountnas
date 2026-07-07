# CONTEXT.md — MountNAS evolution & working notes

Companion to the design spec (`mountnas-dev-plan.md`, originally in
`~/Downloads/files/`). The plan describes the *intended* design; this file records
**what actually got built, what diverged from the plan, the non-obvious lessons,
and what still needs doing.** Read this before changing the build or the packages —
most of the CI steps look arbitrary but each fixes a specific, hard-won failure
that will silently regress if "cleaned up" without understanding it.

---

## 1. Status at a glance (as of alpha-6, 2026-07-06)

- **Build: GREEN, releases through alpha-6 published.** The workflow assembles
  everything end-to-end: 4 local apks, `mkimage` ISO, single-slot 3.5 GiB
  `.img.gz` (~1 GB compressed).
- **CI-verified per release, all blocking:** boot-to-login under SeaBIOS *and*
  OVMF; the full first-install story (wizard → data disk → docker/samba start →
  commit → reboot persistence, via the supervisor smoke test); and a REAL
  in-place upgrade from the previous published release (upgrade smoke test,
  blocking since the first green alpha-4 → alpha-5 run). See §6/§8.
- **Still manual:** boot from a real USB stick on real hardware (§8).
- **Single deliverable** = `mountnas-<tag>.img.gz` (write to USB with Etcher/dd for a
  fresh install; the same file is what `nas upgrade` consumes). See §4.

---

## 2. Repository layout (current)

```
mountnas/
├── packages.list                     # world set (incl. local apks); rationale comments per package
├── scripts/
│   ├── mkimg.nas.sh                  # mkimage profile (reads cmdline.base; boot_addons = ucode)
│   ├── genapkovl-mountnas.sh         # seed overlay (world via mkworld.sh, runlevels, /etc config)
│   ├── mkworld.sh                    # SINGLE source of the world list (seed AND world.base)
│   ├── cmdline.base                  # SINGLE source of the kernel cmdline (see §8 item 3)
│   ├── ci-lint.sh                    # shellcheck (auto-discovered targets) + su-block apostrophe guard
│   ├── ci-supervisor-test.exp        # QEMU serial: wizard/storage/services/reboot (blocking)
│   └── ci-upgrade-test.exp           # QEMU serial: previous release -> this build (blocking)
├── mountnas-tools/                   # LOCAL apk: the nas CLI + services (arch=x86_64, see §6)
│   ├── APKBUILD
│   └── files/                        # the actual scripts (NOT src/ — see §6)
│       ├── nas                       # the CLI (setup/status/disks/changes/report/backup/upgrade/…)
│       ├── mountnas                  # storage guard + data-service supervisor (init.d)
│       ├── mountnas-mkdirs, mountnas-net, mountnas-sshkey, mountnas-issue   # boot helpers (init.d)
│       ├── pick-nic, gen-issue, write-bootcfg, data-watch    # /usr/libexec/mountnas
│       ├── periodic-datawatch        # /etc/periodic/15min wrapper (lbu-excluded, dot-free name)
│       ├── issue-ifupdown            # /etc/network/if-up.d hook
│       ├── profile-nas-{welcome,aliases,prompt,resize}.sh    # /etc/profile.d (lbu-excluded)
│       └── logo
├── snapraid/        APKBUILD          # LOCAL apk: compiled from source
├── mergerfs/        APKBUILD          # LOCAL apk: repackaged upstream static binary
├── zerotier-one/    APKBUILD + zerotier-one.initd   # LOCAL apk: repackaged + init script
├── .github/workflows/build.yml       # the whole build pipeline (heavily iterated)
├── .github/workflows/lint.yml        # ci-lint.sh on every push/PR
├── README.md  UPGRADE.md  CHANGELOG.md  CONTEXT.md  LICENSE
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
  (`/usr/sbin`, `/etc/init.d`, `/usr/libexec`, and the lbu-EXCLUDED `/etc/profile.d`
  snippets + `/etc/periodic/15min/mountnas-datawatch` — apk-shipped files under
  `/etc` must be added to the exclude list in genapkovl or lbu captures them).
  All editable defaults (`fstab`, `sshd_config`, `smb.conf`, `smartd.conf`,
  `msmtprc`, `mail.rc`, `inittab`, runlevels, …) live in `genapkovl-mountnas.sh`
  and are user-owned via lbu.
- **world ⊆ media repo, by construction.** `mkworld.sh` = alpine-base +
  packages.list + mkinitfs; the mkimage profile's `$apks` = packages.list +
  profile_standard's bases (which include alpine-base) — so every world entry is
  always fetchable from the offline media repo. NEVER add a package to world (or
  world.base) outside packages.list: that is exactly how bare `linux-firmware`
  once broke apk on every upgraded box (see mkworld.sh header). linux-lts is
  deliberately NOT in `$apks` — kernel bits live on `/boot`, never in world.
- **Upgrade writes are staged, then renamed.** `nas upgrade` copies EVERY payload
  to a `.new` name first (slow copies happen while the old system is intact and
  bootable; a staging failure aborts having changed nothing), then commits with
  back-to-back renames; `_commit_dir` restores the `.old` tree if a swap-in
  fails so `/apks` can never end up missing. Do not "simplify" this back to
  interleaved copy+rename — a power cut mid-modloop-copy then boots a mixed
  kernel/modloop pair, which does not boot.
- **Image geometry is frozen per deployed stick.** 3.5 GiB raw: BOOT 2.5 GiB +
  MNASCFG ~1 GiB (overlay + `/cfg/cache`); fits real-world "4 GB" sticks.
  Upgrades replace files, never partitions, so sizes only matter at image-build
  time — watch the "BOOT size report" in every build log (currently ~1 GB used
  of 2.5 GiB) before growing the payload.
- **Network filesystems are never mounted by the boot path.** No `netmount`
  service ships; the supervisor skips network fstypes when placeholdering and
  refuses one as `/mnt/nasdata` (state `netfs`, services held) — a dead remote
  must never stall the default runlevel, because busybox init starts the gettys
  only after it completes (no console login otherwise).
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
  place (via the `_free_modloop` step in `nas`); rollback is a full-image `nas backup`
  (see §4a). The old A/B two-slot scheme was removed — it only existed to dodge the
  busy-modloop problem, which the modules-to-RAM free step solves directly.
- **Data services (docker/samba/nfs) are NOT in any runlevel.** The `mountnas`
  service starts them only once `/mnt/nasdata` is mounted. Do not `rc-update add`
  them — `nas status` flags it.
- **apk repos are enabled and PINNED to the image's Alpine version; the cache
  lives at `/cfg/cache`.** Never switch the CDN lines to `latest-stable` (the
  symlink moves on a new Alpine release → version skew against the installed
  base). The pinned version travels as the `alpine.base` marker on BOOT and
  `nas upgrade` re-pins the dl-cdn lines from it (repositories is user-owned
  config, so only the version component is rewritten). User-added packages
  persist because (a) the cache sits on MNASCFG next to the apkovl and (b) the
  `mountnas` service re-syncs the installed set to `/etc/apk/world` once `/cfg`
  is mounted — the diskless init may have skipped a package that is only in the
  cache/CDN (it installs world with `--force-broken-world` semantics, so a
  missing extra is boot noise, not a boot failure).
- **`mountnas` service = `nas` CLI separation:** the service is `mountnas` so
  `rc-service mountnas …` never collides with the `nas` command.

---

## 4. The artifacts (what each is for)

The CI publishes a **GitHub Release** (not a zip — see §6) with:

| File | Purpose |
|---|---|
| `mountnas-<tag>.img.gz` | **The product — ONE image for everything.** Single-slot image (BOOT + MNASCFG). Write to USB for a fresh install, OR pass to `nas upgrade` to update in place (it loop-mounts partition 1 for the new boot files). Self-contained: the seed overlay is baked onto MNASCFG. |
| `mountnas-<tag>.rsa.pub` | The build's package signing key (see the §8 signing-key caveat — currently rotates per release). |
| `SHA256SUMS` | Checksums of the above. |

There is **no separate `-upgrade.img`** anymore — the full `.img.gz` is the upgrade
payload too (removed the iso9660 + its xorriso `world.base` embed step).

**The seed `.apkovl.tar.gz` is intentionally NOT published.** It's baked into the
`.img` (MNASCFG) so the image is self-contained; it has no standalone consumer.

### 4a. Upgrade + backup model (single-slot)

- **`nas upgrade <img.gz>`** rewrites BOOT **in place**: warn+`YES` gate → free-space
  precheck → unpack + loop-mount the image's p1 → **`_free_modloop`** (moves ONLY the
  kernel modules to RAM — not the firmware tree, which does not fit a 4 GB box's
  tmpfs; detaches the live modloop so it's overwritable; replaced Alpine's
  `copy-modloop`, see §8 known-bug note) → **stage** every payload to `.new` names
  (kernel/initramfs/modloop, `/apks`, `world.base`, `alpine.base`, bootloader
  payload, `*-ucode.img` when present) → **commit** with back-to-back renames
  (see the staged-writes invariant, §3) → reconcile `/etc/apk/world`
  (new base ∪ user extras) → re-pin repos → `write-bootcfg` + `lbu commit` →
  BOOT remounted read-only → reboot. Config/data untouched. **No automatic
  rollback** (the full-image `nas backup` is the rollback net).
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

Package additions after the plan (alpha-3…: zsh/mosh, curated firmware set,
msmtp/mailx, restic, testdisk, f3, wireguard-tools, zstd/lz4/xz, xxhash,
fdupes, microcode boot addons) are tracked in `CHANGELOG.md`; each entry in
`packages.list` carries its own rationale comment. cryptsetup/dmcrypt (LUKS)
shipped in alpha-6 and was REMOVED in beta-2 at the maintainer's direction —
do not re-add without an explicit ask. Non-obvious wiring: `mail(1)` → msmtp
glue is seed config (`/etc/mail.rc` sets both `sendmail=` and `mta=` because
mailx flavors disagree on the variable name; `/etc/msmtprc` ships 0600 because
it holds a password and names its single account `default` so uncommenting
just works).

---

## 6. CI/build pipeline — the non-obvious fixes (DO NOT REGRESS)

Everything below is in `.github/workflows/build.yml`. Each line fixes a real
failure encountered during bring-up.

**Version match.** `alpine_branch=latest-stable` (= v3.24 now), and the aports ref
MUST match — a `mkimage.sh` from the wrong aports version fails against the
installed apk-tools. The workflow now **auto-derives** the ref from the installed
`/etc/alpine-release` (`3.24` → `3.24-stable`) when the `aports_ref` input is left
empty; the input remains as a manual override only.

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
`.boot_repository` marker). We keep it as-is and assert the boot files (incl. the
`*-ucode.img` microcode images that arrive via `boot_addons` in the profile;
`write-bootcfg` prepends them to the initrd lines when present) +
`apks/x86_64/APKINDEX.tar.gz` landed (**no `|| true`** — a `setup-bootable` layout
change fails the build). We `touch "$M/apks/.boot_repository"` to guarantee the marker.
Geometry: `truncate -s 3584M`, BOOT `+2560M`, MNASCFG the rest — see the frozen-
geometry invariant (§3); the "BOOT size report" printed right after (df + top-15
files) is the headroom gauge, and it must never be able to fail the build (its
`sort|awk` pipeline is guarded — a `head` there once SIGPIPE'd sort and killed a
run under the strict step shell).
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

**Lint + boot gate.**
- **`scripts/ci-lint.sh`** runs before anything expensive (and again on every
  push/PR via `.github/workflows/lint.yml`). It DISCOVERS its targets (shebang
  grep over `mountnas-tools/files/` + profile.d globs + `scripts/*.sh`) so a new
  script can never ship unlinted; flags are `shellcheck -s sh -S warning
  -e SC2034,SC3043,SC3045` (excludes deliberate: SC2034 — openrc-run vars like
  `description=` look unused; SC3043/SC3045 — `local` and `read -s` are fine in
  busybox ash). It also guards the §6 apostrophe landmine: an awk pass flags any
  stray apostrophe inside build.yml's `su -c '…'` block, which shellcheck cannot
  see.
- **QEMU boot smoke test** (after assembly, before publish): the image is booted
  under BOTH firmwares (SeaBIOS and OVMF) and must print a `login:` prompt on the
  serial console within ~7 min, else the job fails and nothing is published. The
  disk is attached **`if=virtio`** on purpose — the cmdline module list carries
  virtio_blk but NOT ide/ata_piix, so QEMU's default IDE bus would never be found
  by the initramfs and the test would false-fail.
- **Supervisor smoke test** (blocking; `scripts/ci-supervisor-test.exp`): boots
  the fresh image with a blank second virtio disk and drives the serial console
  through the first-boot wizard, `mkfs`+fstab+`rc-service mountnas restart`,
  requires docker AND samba to start, `nas status` to be `[FAIL]`-free, then
  `nas commit` + reboot + login with the new password and the storage/services
  returning by themselves. This is the only pre-publish gate that executes THIS
  build's supervisor/wizard code (the upgrade test runs the previous release's).
- **Upgrade smoke test** (blocking; `scripts/ci-upgrade-test.exp`) — described in
  §8: boots the PREVIOUS published release and drives a real `nas upgrade` to
  the just-built image, then reboots and checks version + world. Exits 0 with a
  notice when no previous release exists (first release, forks).
- **Serial-test conventions** are documented in the header comments of both
  `.exp` files — most importantly: sent marker strings are quote-split
  (`echo X"-OK"`) and matched unsplit (`X-OK`) so a command's own terminal echo
  can never satisfy the expect, and the root prompt is matched as `:~# `.

**Version + signing key.**
- `nas version`/`nas status` report mountnas-tools' `pkgver`; the workflow seds the
  release tag (leading `v` stripped) into the APKBUILD before building, falling back
  to `1.0.0_git<date>` when the tag is not a valid apk version (e.g. `dev`).
- The signing key comes from the **`ABUILD_PRIVKEY` repo secret** when set — a
  stable trust anchor, so the published `.rsa.pub` stops changing every build.
  Generate once (`abuild-keygen -an` anywhere, or plain
  `openssl genrsa -out key.rsa 4096` — the workflow only needs a PEM RSA private
  key and derives the pubkey itself), paste the full PEM into the secret.
  Without the secret (forks, PRs) the random per-build keygen runs.
  **As of alpha-6 the secret is NOT set — see the §8 caveat.**

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

**Verified (all in CI, per release):** full build assembles; all 4 local apks
build & sign; boot-to-login under SeaBIOS and OVMF; the first-install story
end-to-end (wizard, storage registration, docker/samba gating, commit, reboot
persistence — supervisor smoke test); a real in-place upgrade from the previous
published release (upgrade smoke test, blocking). Historical bring-up context:
the Proxmox/SeaBIOS boot chain was debugged in three layers (hang → "not a
bootable disk" → `/sbin/init not found`) — the fixes live in §6.

**Open / next (in priority order):**
1. **Real hardware.** Boot from a real USB stick on a real box: confirm the seed
   overlay applies (root-owned, `doas` works), NIC pick + DHCP on real PHYs,
   microcode actually early-loads (`dmesg | grep microcode`), and disk spin-up
   timing under the supervisor's 15 s wait. Everything QEMU can prove is already
   gated in CI; hardware-specific behavior is the remaining risk.
2. **Backup restore drill (manual).** `nas backup` → write the image to a second
   USB → boot it. The upgrade half is CI-covered (blocking); user-added-package
   preservation across an upgrade is still only manually verified.
3. **Boot-module breadth (addressed, verify on odd hardware).** The cmdline loads
   `…,ahci,nvme,virtio_pci,virtio_scsi,virtio_blk` on top of the USB-stick set so a VM
   disk (Proxmox defaults to VirtIO SCSI) is found at boot. The cmdline has a
   **single source**: `scripts/cmdline.base` — `mkimg.nas.sh` reads it (via
   `CMDLINE_FILE`), `build.yml` copies it onto BOOT, and `write-bootcfg` reads the
   on-media copy (no baked-in fallback; it fails loudly if the file is missing).
   eMMC/SD boot (mmc_block/sdhci) is a known gap to evaluate if such hardware
   shows up — the `mmc` mkinitfs feature is present in the standard profile.

**Known bug (ROOT CAUSE FOUND, fixed in alpha-4) — in-place upgrade failed at
`copy-modloop`.** The CI upgrade test + a live-box diagnostic session nailed it:
Alpine's `copy-modloop` does `cp -a` of the WHOLE modloop tree — kernel modules
**plus the full firmware set** — into the tmpfs RAM root (= half of RAM). Two
RAM-dependent failure modes, both observed:
- **4 GB box (real hardware):** the copy hits ENOSPC mid-firmware; worse, the
  aborted partial `/lib/modules.tmp` fills the tmpfs and wedges `lbu commit`
  ("tar: empty archive") until a reboot clears RAM.
- **8 GB (CI VM):** the copy fits, then `umount /.modloop` reported a (spurious,
  transient) "target is busy" → "modloop failed to stop".
Fix shipped in the `nas` CLI (alpha-4): **`_free_modloop`** replaces
`copy-modloop` — copies ONLY the kernel modules (tens of MB, exact headroom
measured first), clears the kernel's `firmware_class.path` if it points into
the modloop (post-detach loads fall back to `/lib/firmware`, where apk-added
blobs live — verified on a live box that apk-added firmware installs EARLY at
boot, before device probing), then stops the modloop service with a
direct/lazy-umount fallback for the transient-busy case.
Because the upgrade runs the **source** release's code, alpha-1/2/3 boxes still
hit the old path and must reflash to alpha-4. The one-time bootstrap completed:
the alpha-4 → alpha-5 run was the **first green** upgrade test
(`UPGRADE-TEST PASS`, run 28829367172), and the test is **blocking** since.

**alpha-5 notes:** the upgrade write phase now stages ALL payloads
first and only then renames back-to-back (power cut mid-copy can no longer mix
kernel/modloop generations); the image is 3.5 GiB raw (BOOT 2.5 GiB + MNASCFG
~1 GiB — partition sizes are frozen per deployed stick, so headroom lives in
the build log's BOOT size report); linux-lts is no longer cached in the media
repo (nothing could install it); early microcode ships via boot_addons and the
write-bootcfg initrd lines; and the blocking supervisor smoke test (§6) now
covers the wizard + storage/service gating that used to be manual-only. The
upgrade smoke test went GREEN for the first time on the alpha-4 → alpha-5 pair
(run 28829367172) and was flipped to blocking immediately after.

**alpha-6 notes:** NAS-essentials package pass (see CHANGELOG + §5 wiring notes):
cryptsetup/dmcrypt, msmtp/mailx mail pipeline, restic, testdisk, f3,
wireguard-tools, zstd/lz4/xz, xxhash, fdupes. First build with the upgrade
smoke test BLOCKING (alpha-5 → alpha-6, green). Image 983 MB compressed.

**alpha-7 notes:** `nas` CLI feature pass (full list in CHANGELOG). Landmines
for maintainers:
- `/usr/share/mountnas/version` MUST stay the apk pkgver — the CI upgrade test
  reads it (`-ex $newver`) and apk needs a valid version. The user-visible tag
  lives in `/usr/share/mountnas/release` (seded into `_reltag` by build.yml);
  everything user-facing displays RELEASE, and `upgrade --check` compares
  tag-to-tag (comparing against pkgver mismatched forever — the old bug).
- `nas status` exits 1 on any FAIL, 2 when check tracking itself could not
  start (fail-closed). Checks emit structured records — ok()/warn()/bad()
  append TYPE<TAB>message to $NAS_CHECKS (file, not a variable: the checks
  run in pipe subshells) and `--json` renders purely from those records
  (beta-1; the old magic-offset parse of the human text is gone, so the
  display format is free to change). The supervisor CI test still greps the
  literal FAIL word in the human output — keep the tag words intact inside
  the color escapes for that one consumer.
- bash completion ships as files/bash-nas-completion.sh with its body inside
  eval: busybox ash sources profile.d too and PARSES function bodies eagerly,
  so bare bash array syntax there would syntax-error every ash login. ci-lint
  lints it with -s bash explicitly (no shebang, so discovery skips it); the
  zsh compdef is unlintable data.
- 'nas logs --persist on|off' edits ONLY the -O/-s/-b tokens inside
  SYSLOGD_OPTS (beta-1; it used to rewrite the file wholesale and clobber
  user tokens); the mountnas service restarts syslogd after the data disk
  mounts because the boot-time syslogd starts before the -O target exists.

**beta-1 notes:** all 15 findings from the alpha-7 code review fixed, one
commit each (see CHANGELOG). Structural: status checks-as-records (above);
one `release-string` helper (nas/gen-issue/welcome — never re-implement the
release/version fallback by hand); one `_boot_usb_disk()` helper (never
hand-roll findfs LABEL=BOOT + pkname again); the --help interceptor is
CLOSED (help or overview, never execution — add a _cmd_help_for page for
every new dispatcher command); release_tag is validated in CI before the
_reltag sed; completions read howto topics from the installed dir.

**Known caveats:**
- **Signing key — ACTION NEEDED: the `ABUILD_PRIVKEY` repo secret is still NOT
  set.** Verified by comparing published pubkeys: alpha-4's and alpha-5's
  `mountnas-<tag>.rsa.pub` differ, so every release is still signed by a random
  per-build key. Boots and upgrades work regardless (each image is internally
  self-consistent — the initramfs trusts its own build's key), but the published
  `.rsa.pub` cannot serve as a stable trust anchor until the secret exists.
  To fix: `openssl genrsa -out mountnas-signing.rsa 4096` (keep it private,
  back it up), then repo Settings → Secrets → Actions → new secret
  `ABUILD_PRIVKEY` = the full PEM. The first release after that rotates the key
  one final time. See §6 "Version + signing key".
- `depmod: ERROR: fstatat(3, vmlinuz)` during the kernel step is **benign** (modloop
  builds/signs fine right after).
- The `apk index` "No provider for the dependencies" warning during local-repo
  signing is **expected** (the 4-package local index doesn't contain its stable
  deps; they resolve at install time).

---

## 9. How to cut a build

GitHub → Actions → **Build MountNAS** → Run workflow. Inputs: `release_tag`
(image filename + release tag), `alpine_branch=latest-stable`,
`aports_ref` **left empty** (auto-derived from the installed Alpine version;
set only to override), `arch=x86_64`.
Output: a GitHub Release tagged `<release_tag>` with the files in §4.

## 10. References
- `mountnas-dev-plan.md` — the ORIGINAL design spec (historical; lived in
  `~/Downloads/files/`, not in the repo). The shipped design has since diverged
  where §5/§8 say so; this file + CHANGELOG.md are the living record.
- `README.md` — user-facing docs. `UPGRADE.md` — single-slot in-place upgrade +
  backup docs (incl. the one-time alpha-1/2/3 migration). `CHANGELOG.md` —
  per-release history.
- Build host base: Alpine **latest-stable (v3.24)**, `jirutka/setup-alpine`, `abuild`.
