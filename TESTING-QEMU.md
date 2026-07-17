# TESTING-QEMU.md — the MountNAS QEMU test suite, end to end

This document covers the self-hosted QEMU test suite in `tests/qemu/`:
what hardware/VM you need, how to run it on a freshly installed Alpine
Linux system, how to read the results, and **what every one of the 85
tests actually verifies**.

The suite complements — it does not replace — the blocking CI smoke tests
(`scripts/ci-*.exp`, run per release in GitHub Actions) and the manual
real-hardware checks listed in `CONTEXT.md` §8. What this suite adds is the
stuff only QEMU can do safely: hot-unplugging a mounted disk, injecting I/O
errors, cutting power in the middle of an upgrade, corrupting the config
overlay — plus full regression coverage of the `nas` CLI.

---

## 1. System requirements

### Host machine

| Requirement | Minimum | Recommended | Why |
|---|---|---|---|
| OS | Alpine Linux (fresh install is fine) | Alpine latest-stable | `run-suite.sh` installs its own deps via `apk` |
| CPU | x86_64 with virtualization (VT-x/AMD-V), 2 cores | 4+ cores | guests run one at a time, but QEMU + gzip both want CPU |
| **KVM** | `/dev/kvm` available | — | without it the suite falls back to TCG software emulation: **5–8× slower**; only the smoke tier is realistic |
| RAM | 12 GB | 16 GB | upgrade-test guests run with `-m 8192`; everything else uses 4 GB guests |
| Disk | 12 GB free | **30+ GB free** | image cache (~1 GB/release), decompressed base images (3.5 GB each), golden snapshot, 12 GB upgrade payload disk |
| Network | outbound HTTPS | — | only needed to download release images and for the few `network`-marked tests; fully offline runs work with local image files |

### Running inside a Proxmox VM (the typical setup)

The suite runs QEMU **inside** your VM, so the VM needs *nested
virtualization*:

1. On the **Proxmox host**, nested virt must be enabled (it is by default on
   recent PVE; verify with `cat /sys/module/kvm_intel/parameters/nested` →
   `Y`/`1`, or `kvm_amd` for AMD).
2. Create the VM with **CPU type `host`** (not the default `kvm64` — that
   hides the virtualization flag). Proxmox UI: VM → Hardware → Processors →
   Type: `host`. CLI: `qm set <vmid> --cpu host`.
3. Give it ≥ 12 GB RAM, ≥ 40 GB disk, 4 cores.
4. Install Alpine (see below). After boot, `ls -l /dev/kvm` must succeed.
   If it doesn't, the CPU type is the usual culprit.

### Fresh Alpine install (10 minutes)

From the Alpine ISO (`alpine-virt` or `alpine-standard`, latest-stable):

```sh
# at the live prompt, log in as root (no password) and run:
setup-alpine
#   answers that matter:
#   - keyboard/hostname/network: defaults are fine (DHCP)
#   - root password: set one
#   - which disk: your VM disk, mode "sys" (classic full-disk install)
#   - apk mirror: pick any (or "f" for fastest)
#   - sshd: openssh          <- you want SSH access
reboot
```

After the reboot, log in as root and fetch the repo:

```sh
apk add git
git clone https://github.com/ethanpil/mountnas
cd mountnas
```

That's the whole host setup. Everything else is handled by the runner.

---

## 2. Running the suite

### The three commands, in order

```sh
# 1. Sanity: installs dependencies, imports the suite, collects all tests.
#    Runs nothing, downloads nothing. Takes ~1 min on first run.
sh tests/qemu/run-suite.sh --collect

# 2. Smoke tier: ~15 min under KVM. Boots the image, runs the wizard,
#    builds the golden snapshot, sends a mail through the pipeline.
#    Proves the whole harness + report pipeline before committing hours.
sh tests/qemu/run-suite.sh --tier smoke

# 3. The full monty: ~2.5-3 h under KVM.
sh tests/qemu/run-suite.sh
```

Run as **root** (it apk-installs packages; QEMU/KVM access is simplest that
way). With no image argument, the **latest GitHub release** is downloaded
and tested. To test a specific or unpublished image:

```sh
sh tests/qemu/run-suite.sh /path/to/mountnas-beta-3.img.gz
```

### All options

| Option | Effect |
|---|---|
| `IMAGE.img.gz` (positional) | test this local image instead of downloading the latest release |
| `--previous FILE` | previous-release image for the real upgrade test (default: downloaded; if none exists those tests skip) |
| `--tier smoke\|full` | `smoke` = 5-test sanity subset; `full` = everything (default) |
| `--require-kvm` | abort if `/dev/kvm` is missing instead of limping along under TCG |
| `--keep-guests` | keep every per-test overlay disk and socket dir (debugging) |
| `--collect` | dependency check + test collection only; runs nothing |
| `-- <pytest args>` | passed to pytest verbatim — see below |

Useful pytest selections (after `--`):

```sh
sh tests/qemu/run-suite.sh img.gz -- -m "not upgrade"     # skip the ~1h upgrade block
sh tests/qemu/run-suite.sh img.gz -- -m faults            # only fault injection
sh tests/qemu/run-suite.sh img.gz -- -k samba -x          # one test, stop on failure
```

### Environment variables

| Variable | Default | Effect |
|---|---|---|
| `MOUNTNAS_TEST_CACHE` | `~/.cache/mountnas-qemu` | image + golden-snapshot cache location |
| `MOUNTNAS_TEST_TIME_SCALE` | 1 (KVM) / 6 (TCG) | multiplies every timeout in the suite |
| `MOUNTNAS_TEST_REPO` | `ethanpil/mountnas` | GitHub repo for release downloads |
| `MOUNTNAS_OVMF` | auto-discovered | UEFI firmware path; empty = UEFI tests skip |

### What happens on the first run

1. Dependencies are installed (`python3`, `qemu-system-x86_64`, `qemu-img`,
   `ovmf`, `mtools`, `e2fsprogs`, `openssh`, Pillow, pexpect, pytest; plus
   `pytest-html` and `ansi2html` in a private venv).
2. The image is downloaded (or your local file is used), SHA256-verified
   against the release's `SHA256SUMS`, and sparse-decompressed.
3. The suite's SSH public key is written onto the image's FAT BOOT
   partition — the shipped `mountnas-sshkey` service installs it at every
   boot, which is how tests get shell access without touching the product.
4. The **golden snapshot** is built (~6–8 min, once per image): the pristine
   image boots, the first-boot wizard is driven over the serial console, a
   data disk is formatted and committed, and the result is frozen as qcow2
   backing files. Every subsequent test boots a throwaway overlay of it in
   seconds. A first-boot screendump GIF is captured during this build.
5. Tests run. Each gets fresh disks; nothing a test does can leak into
   another test or into the cached images.

Subsequent runs skip 2–4 (cache hits) and go straight to the tests.

---

## 3. Reading the results

### Where everything lands

```
~/mountnas-qemu-test-suite-result-YYYY-MM-DD/
├── mountnas-qemu-test-suite-result-YYYY-MM-DD.html   <- open this
├── junit.xml          # machine-readable (CI dashboards, diffing runs)
├── summary.json       # totals + per-test outcome/duration + env info
├── pytest.log         # DEBUG-level serial/QMP/SSH traces of the whole run
├── guests/            # golden-build guest logs
└── artifacts/<test-id>/          # per test:
    ├── NNN-<label>.png           #   raw screenshots
    ├── transcript.txt            #   every command + rc + output
    └── guest-*/                  #   serial.log, qemu-cmdline.txt,
                                  #   qemu-stderr.log, failure-dmesg.txt
```

### The HTML report

Self-contained (screenshots embedded) — copy the single `.html` anywhere and
open it in a browser. Anatomy:

- **Header/environment table**: image tag tested, QEMU version, KVM on/off,
  time scale, host, date. *Check KVM says "yes" — a TCG run with timeouts
  is not a product failure.*
- **Summary line**: passed / failed / skipped / error counts.
- **Per-test rows** (click to expand):
  - **Screenshots** — VGA console captures (login prompts, banners, failure
    states). The boot-sequence GIF is attached to `test_boot_sequence_gif`.
  - **Command transcript** — every command the test ran on the guest, over
    SSH or serial, with exit code, duration, and color-preserved output.
    For `nas` commands this transcript *is* the screenshot — SSH output
    never appears on the VGA screen.
  - **On failure, additionally**: the final VGA screendump at the moment of
    failure, the full serial log (kernel + OpenRC + getty output since
    power-on), guest `dmesg` if SSH still answered, and QEMU's stderr.

### Outcome semantics

| Outcome | Meaning |
|---|---|
| **passed** | the asserted behavior was observed on a real booted guest |
| **failed** | assertion false — read the transcript bottom-up; the last red `rc=` is usually the story. Cross-check the serial log for kernel/OpenRC noise at that timestamp |
| **skipped** | preconditions absent, by design — reasons are printed: no OVMF firmware (UEFI test), no previous release (`needs_prev`), no internet (`network`), no SMART device (smartd test) |
| **error** | the harness itself broke (fixture failure) — e.g. golden build failed. Look at `guests/golden-build/serial.log` first |

Exit code of `run-suite.sh` = pytest's exit code: `0` all green, `1` failures,
other = usage/internal errors. `summary.json` has the same verdict for
scripting (`.counts`, `.exitstatus`).

### Skips you should expect on a typical run

- `test_boot_ovmf_login` — only if the `ovmf` apk package couldn't install.
- `test_upgrade_from_previous_release`, `test_user_packages_survive_upgrade`
  — when no previous release exists (first release, private repo, or
  offline) and `--previous` wasn't given.
- `network`-marked tests (apk-add persistence, `upgrade --check`) — offline.
- `test_smartd_test_mail_arrives` — if smartctl can't drive the emulated
  NVMe device on this QEMU version.

Everything else skipping is worth investigating.

### Flakiness policy

No test uses bare sleeps; every wait is a deadline-polled loop scaled by
`MOUNTNAS_TEST_TIME_SCALE`. If a test fails under TCG but passes under KVM,
raise the scale before filing a bug. The two power-cut-mid-upgrade tests
assert *invariants* (the box boots; `/apks` exists) rather than exact
timing, so they are stable by construction even though the cut lands at a
slightly different phase each run.

---

## 4. The complete test catalog (85 tests)

Markers: **[smoke]** = smoke tier · **[upgrade]** / **[faults]** /
**[slow]** = selectable blocks · **[network]** = needs internet ·
**[needs_prev]** = needs a previous release.

### A — Boot & image integrity (`test_a_boot.py`, 9 tests)

| Test | What it verifies |
|---|---|
| `test_boot_seabios_login` **[smoke]** | The pristine image reaches a `login:` prompt under legacy BIOS (SeaBIOS) — the gptmbr → VBR → syslinux chain works. Screenshot taken. |
| `test_boot_ovmf_login` | Same under UEFI (OVMF) — the `/EFI/BOOT/BOOTX64.EFI` grub fallback path works. |
| `test_boot_sequence_gif` **[smoke]** | The golden build captured the animated first-boot screendump GIF; anchors it into the report. |
| `test_getty_on_tty1_and_ttys0` | Exactly one getty on tty1 (VGA) and one on ttyS0 (serial), and `console=tty1 console=ttyS0` on the cmdline — guards the historical double-getty bug that made the Proxmox noVNC console unusable (two prompts fighting over input). |
| `test_boot_without_data_disk_state_fresh` | With no data disk configured the supervisor reports state `fresh` and boot still reaches a shell — storage must never stall the default runlevel (no getty otherwise). |
| `test_partition_labels_boot_mnascfg` | The single-slot layout is intact: `LABEL=BOOT` (FAT) + `LABEL=MNASCFG` (ext4) exist and `/cfg` is mounted — the overlay is found by label, not UUID. |
| `test_data_disk_detected_per_bus[virtio-scsi]` | A `LABEL=nasdata` disk on a virtio-scsi controller is found, mounted, and visible in `nas disks --json` — exercises the `virtio_scsi` module in `scripts/cmdline.base`. |
| `test_data_disk_detected_per_bus[ahci]` | Same on an AHCI/SATA controller (`ahci` module) — the typical real-hardware data-disk bus. |
| `test_data_disk_detected_per_bus[nvme]` | Same on NVMe (`nvme` module). |

### B — First-boot wizard (`test_b_wizard.py`, 7 tests)

All driven over the serial console on a pristine (never-configured) image,
exactly as a new user at a monitor would experience it.

| Test | What it verifies |
|---|---|
| `test_wizard_full_flow_prompt_order` **[smoke]** | All five steps appear in order (hostname → root password → timezone → network → save), end at "Setup complete", and the hostname is applied. |
| `test_wizard_flips_permit_empty_passwords` | Once a root password exists, the wizard flips the shipped `PermitEmptyPasswords yes` → `no` — the one sshd change the wizard is allowed to make. |
| `test_wizard_writes_setup_done_marker` | `/etc/mountnas/setup-done` is written (and dated) so the wizard never re-offers itself. |
| `test_wizard_rejects_invalid_hostname` | An illegal hostname (`bad name!`) re-prompts instead of being accepted. |
| `test_wizard_static_network_path` | The `[S]tatic` branch prompts for interface/IP-with-prefix/gateway/DNS and writes a static stanza to `/etc/network/interfaces`. |
| `test_wizard_not_rerun_after_commit_reboot` | After the wizard's closing commit and a reboot, login asks for the password — the wizard does NOT run again. |
| `test_doas_config_root_owned_and_valid` | `/etc/doas.conf` is root:root and parses — guards the genapkovl/fakeroot lesson where overlay files carried the build uid and doas refused its own config at runtime. |

### C — The `nas` CLI (`test_c_cli.py`, 16 tests)

| Test | What it verifies |
|---|---|
| `test_status_exit_0_when_ok` **[smoke]** | A healthy box: `nas status` exits 0 with no `[FAIL]` lines. |
| `test_status_json_is_valid_with_counts` | `nas status --json` is valid JSON with the documented shape (release/version/services/checks/healthy/...), `healthy: true`, zero fails, docker running. |
| `test_disks_json_valid` | `nas disks --json` is valid JSON; the nasdata partition appears with `in_fstab: true`; the boot USB disk is flagged. |
| `test_disks_human_output` | The human listing shows the `*` boot-USB marker and the data disk. |
| `test_status_exit_2_fail_closed` | When check tracking can't even start (`TMPDIR` unwritable → mktemp fails), status exits **2**, never a false-healthy 0. |
| `test_version_and_release_strings` | `nas version` agrees with `/usr/share/mountnas/version` (the apk pkgver the CI upgrade test also keys on). |
| `test_help_interceptor_never_executes` | `nas reboot --help` / `shutdown --help` / `backup --help` show help and **never execute** — verified by uptime continuity. Guards the closed `--help` interceptor contract. |
| `test_completions_dont_break_ash_login` | A busybox-ash login shell sources profile.d cleanly — the bash completion's eval wrapper protects ash (bare bash array syntax would syntax-error every login). |
| `test_report_creates_bundle` | `nas report` produces a `/tmp/mountnas-report-*.tar.gz` containing status/system/fstab/dmesg — and no stray directory named after a disk (the beta-2 variable-leak regression where the bundle wrote into a dir literally called `sdd`). |
| `test_status_exit_1_on_fail` | A data service added to a runlevel (`rc-update add docker`) is flagged as a FAIL and status exits 1; removing it restores health. |
| `test_changes_then_commit_then_clean` | `nas changes` lists an uncommitted /etc file; `nas commit -m` saves it; `nas changes` then reports clean. |
| `test_rollback_across_reboot` | Two commits → `nas rollback 1` → reboot → the older config is live; the pre-rollback overlay is preserved as a snapshot (roll-forward possible). |
| `test_logs_persist_token_surgery` | `nas logs --persist on/off` edits ONLY the `-O/-s/-b` tokens in `SYSLOGD_OPTS`; a custom user token survives both transitions (beta-1 fix for the wholesale-rewrite bug). |
| `test_backup_produces_valid_image` **[slow]** | `nas backup` writes a gzip-valid image whose payload starts with a boot-sector magic (55aa), records last-backup (surfaced by the upgrade gate), and leaves `/cfg` read-write afterwards. |
| `test_backup_restore_drill` **[slow]** | THE restore drill, finally automated: back up a configured box (committed probe file), pull the image to the host, write it to a fresh "stick", **boot it**, and prove the OS + hostname + saved config + release all came back. Until this test, the only rollback net for upgrades had never been booted. |
| `test_released_image_ships_expected_files` | Packaging integrity against the PURE released image (no dev pushes — the dev_guest pattern would mask an APKBUILD that forgot a file): the full mountnas-tools manifest, the baked-in tools (`cmkfs`/`duf`/`btm`/`cyme`/`ttyd`/httpd), and (once shipped) avahi-tools. |

### D — In-place upgrade (`test_d_upgrade.py`, 13 tests, all [upgrade])

The crown jewels. Guest layout mirrors the CI upgrade test: system disk +
a 12 GB payload disk carrying `new.img.gz` that doubles as TMPDIR scratch.
Two tests deliberately create realistic **user drift** first, so a fresh
image always has something to test the upgrade against.

| Test | What it verifies |
|---|---|
| `test_upgrade_from_previous_release` **[needs_prev]** | THE real upgrade: previous published release → this image, reboot, exact expected version, and no bare `linux-firmware` in world (the world-reconciliation landmine that once broke apk on every upgraded box). |
| `test_upgrade_self_current_to_current` | The full upgrade path of *this* build even when no previous release exists; `/apks` intact afterwards. |
| `test_upgrade_succeeds_at_4gb_ram` | THE alpha-4 regression: on a 4 GB box, `_free_modloop` (kernel modules only, not firmware) must let the upgrade succeed, and `lbu commit` must not be wedged afterwards — Alpine's `copy-modloop` used to ENOSPC and wedge exactly this. |
| `test_powercut_during_staging_old_system_boots` **[faults]** | Power cut while payloads are being staged to `.new` names: phase 1 changes nothing, so the OLD system must boot untouched with `/apks` intact. |
| `test_powercut_late_window_boots_old_or_new` **[faults]** | Power cut deep in the write phase (staging tail / rename commit): the box must boot with either version — never a mixed kernel/modloop pair (which does not boot) and never a missing `/apks` (`_commit_dir`'s `.old` restore). |
| `test_user_packages_survive_upgrade` **[network] [needs_prev]** | A user-installed package (extras = world − old base) rides across the version bump and reinstalls. |
| `test_user_changes_survive_upgrade` | The harness edits `smb.conf`, `snapraid.conf`, `sshd_config`, `/etc/nut/ups.conf`, `fstab` and a custom `/etc/apk/repositories` line, sets a root password, adds a samba user, and installs a package — commits, self-upgrades, reboots, and asserts **every** edit survived (incl. the CDN re-pin being surgery that keeps the custom repo line, and the overlay config winning over the apk-shipped `nut` default). |
| `test_docker_survives_upgrade` | On a configured guest with `/mnt/nasdata` mounted: a running `--restart unless-stopped` container, its imported image, a host-written data marker on the data disk, and a customized `daemon.json` must ALL survive an upgrade — docker's data-root lives on the untouched data disk and `daemon.json` is overlay-owned. Proves "`nas upgrade` cannot harm installed Docker". |
| `test_gzip_sniff_accepts_wrong_extension` | An image saved as `.img.tgz` still upgrades — gzip is detected by the `1f8b` magic, never the filename (beta-2 tester's browser rename). |
| `test_rejects_non_gzip_payload` | Random bytes named `.img.gz` are rejected cleanly ("cannot mount the image's BOOT partition"), with version and boot files untouched. |
| `test_upgrade_from_url` | `nas upgrade https://...` downloads into TMPDIR, re-sniffs the bytes, upgrades, reboots into the right version (served by a suite-local HTTP server). |
| `test_upgrade_check_against_github` **[network]** | `nas upgrade --check` produces a sane verdict against the live releases API (and a *legible* error if the repo is private — the beta-1 finding). |
| `test_free_space_precheck_aborts` | With TMPDIR too small for the 3.5 GiB unpack, the upgrade aborts BEFORE touching anything. |

### E — Storage lifecycle (`test_e_storage.py`, 6 tests)

| Test | What it verifies |
|---|---|
| `test_add_second_disk_flow` | The documented add-a-disk story: mkfs → fstab → `rc-service mountnas restart` → mounted, writable, status-clean. |
| `test_mergerfs_pool_two_disks_reboot` | Two disks pooled via `fuse.mergerfs` in fstab; the pool and a file written into it survive a reboot; the file physically lives on exactly one branch. |
| `test_snapraid_sync_with_parity` **[slow]** | A minimal snapraid config (1 data + 1 parity) syncs successfully and `snapraid status` is clean — exercises the locally-compiled snapraid apk. |
| `test_mkdirs_before_localmount_new_mountpoint` | A brand-new fstab mountpoint exists by the time busybox `localmount` runs (the `mountnas-mkdirs` service) — fstab carries no `x-mount.mkdir`, which busybox mount would forward to the kernel and fail the mount at ~3s. |
| `test_boot_usb_never_treated_as_data_disk` | A `/mnt/*` fstab entry resolving to the boot USB — the one unrecoverable user error — is flagged FAIL by `nas status`. |
| `test_all_mounts_return_after_reboot` | The whole storage stack (nasdata + extra disk + docker + samba) returns by itself after a reboot, state `ok`. |

### F — Hardware failure & fault injection (`test_f_faults.py`, 10 tests, all [faults])

| Test | What it verifies |
|---|---|
| `test_hot_unplug_sets_disconnected_and_alerts` | Yanking the mounted data disk (QMP `device_del`): data-watch flips state to `disconnected` and emails the alert (received by the suite's SMTP sink) — the beta-3 disk-loss alerting. |
| `test_alert_fires_once_transition_only` | Repeat watcher runs after the failure do NOT re-alert — transition-only by construction (the watcher exits early unless the previous state was ok). |
| `test_hot_replug_nas_restart_recovers` | Plugging a nasdata disk back in: `rc-service mountnas restart` clears the dead mount (`umount -l`) and brings storage + services back to `ok`. |
| `test_blkdebug_io_errors_mountfail_not_crash` | A data disk that EIOs every read (blkdebug injection): boot completes, state degrades to `mountfail`, the read-only placeholder blocks the mountpoint, services are held, `nas status` exits 1 — never a hang or crash. |
| `test_ro_remount_detected` | An ext4-style `errors=remount-ro` event (silent failure mode): the watcher's third probe flags the read-only data disk and alerts. |
| `test_late_disk_within_spinup_window` | A disk that appears seconds *after* the supervisor starts (slow USB-dock spin-up): the 15 s wait loop catches it — state `ok` with no manual restart. |
| `test_netfs_nasdata_refused_services_held` | A network filesystem as `/mnt/nasdata` is refused by design (state `netfs`, services held, box responsive) — a dead remote must never stall the default runlevel. |
| `test_powercut_mid_mkfs_boots_and_degrades` | Power cut during `mkfs` of a declared disk: next boot reaches SSH; nasdata unaffected; status not wedged. |
| `test_powercut_mid_lbu_commit_still_boots` | Power cut during `nas commit` (the overlay swap): next boot comes up and a subsequent commit works — never a torn overlay. |
| `test_corrupt_apkovl_boots_to_defaults` | Garbage written over the active overlay: the diskless init shrugs it off and boots to DEFAULTS (wizard on offer) rather than hanging. |

### G — Data services (`test_g_services.py`, 4 tests)

| Test | What it verifies |
|---|---|
| `test_docker_container_survives_reboot` | A `--restart unless-stopped` container (built network-free from the guest's own busybox **plus the musl loader** — without it the container crash-loops and a bare `Up` grep can't tell) is running again after a reboot. Stability = Up **and** `RestartCount` 0, asserted pre-reboot. |
| `test_samba_password_survives_reboot` | THE beta-3 lbu.list regression: an `smbpasswd -a` user still exists after commit + reboot. This was silently broken from alpha-1 to beta-2 (`/etc/lbu/include` was never an lbu interface). |
| `test_data_services_absent_from_runlevels` | docker/samba/nfs are in NO runlevel — the mountnas supervisor is their only starter. |
| `test_zerotier_identity_persists_reboot` | The ZeroTier node identity (`/var/lib/zerotier-one`) survives commit + reboot — identity loss would mean a new node ID and re-authorizing everywhere. |

### H — Config persistence / lbu (`test_h_lbu.py`, 5 tests)

| Test | What it verifies |
|---|---|
| `test_lbu_include_root_persists` | `/root` is a `+` entry in `/etc/apk/protected_paths.d/lbu.list` and a file there survives commit + reboot — the real lbu mechanism works. |
| `test_lbu_exclude_not_captured` | `-` entries (e.g. `/etc/issue`, regenerated at boot) are not tracked as unsaved changes. |
| `test_legacy_lbu_files_migrated_once` | Old-style `/etc/lbu/include` files are merged into `lbu.list` by the mountnas service, parked as `*.migrated`, and the migration is idempotent (no duplicates on a second restart). |
| `test_apk_shipped_etc_not_in_lbu_status` | apk-shipped files under /etc (profile.d, periodic wrapper) are lbu-excluded — otherwise every commit would capture code the next apk upgrade should own. |
| `test_user_apk_add_persists_reboot` **[network]** | `apk add` + commit + reboot → the package is back (cache on MNASCFG + the world re-sync in the supervisor). |

### I — Mail pipeline (`test_i_mail.py`, 4 tests)

A suite-local SMTP sink plays the relay; guests reach it through QEMU's
user networking.

| Test | What it verifies |
|---|---|
| `test_msmtprc_shipped_permissions_0600` | `/etc/msmtprc` (it holds a relay password) ships 0600 root:root. |
| `test_mail_pipeline_delivers_to_sink` **[smoke]** | `mail -s` end-to-end: mailx → msmtp → relay; subject and body arrive intact — proves the `sendmail=`/`mta=` glue in `/etc/mail.rc`. |
| `test_smartd_test_mail_arrives` | smartd's `-M test` mail traverses the same pipeline, monitored device = an emulated NVMe drive (the one QEMU bus with a SMART health log). |
| `test_alert_email_comment_stripping` | `/etc/mountnas/alert-email` parsing: comments and blank lines are skipped; the alert goes to the first real address. |

### J — Network niceties (`test_j_network.py`, 3 tests)

| Test | What it verifies |
|---|---|
| `test_banner_shows_dhcp_ip` | `/etc/issue` carries the box's DHCP address — the banner a headless user reads off the monitor to find the box. Screenshot taken. |
| `test_mdns_daemon_advertises_hostname` | avahi is up and `<hostname>.local` resolves to the **LAN-reachable** address (the default-route source), not the Docker bridge — avahi otherwise advertises the hostname on `docker0` (`172.17.0.1`) too and hands it out first. The seed ships `deny-interfaces=docker0` from 1.0rc2; the test self-applies it against older images so the fixed behavior is asserted either way. (avahi-tools ships from beta-7; fetched from the CDN otherwise, skips only when offline.) |
| `test_hostname_change_regenerates_banner` | `gen-issue` picks up a hostname change and rewrites the banner (the wizard and if-up hook both lean on it). |

### K — Newest features (`test_k_features.py`, 8 tests)

These exercise features that exist in the repo but not yet in a published
image, so each runs on `dev_guest`: a golden guest with the repo's current
`mountnas-tools/files` pushed over the released ones. **Diskless caveat:**
the push patches the RAM root only — a reboot restores the released apk, so
post-reboot assertions read raw files instead of invoking new commands.

| Test | What it verifies |
|---|---|
| `test_notify_fans_out_to_webhook_and_email` | One `nas notify --test` reaches EVERY configured sink: a JSON webhook (host-side POST catcher validates title/host) and an email (SMTP sink validates the subject). |
| `test_notify_lists_sinks_and_takes_piped_body` | `nas notify` with no args lists the configured sinks; a body piped into `nas notify "subject"` arrives intact in the delivered message. |
| `test_data_watch_alerts_through_sinks` | The disk-loss watcher routes through the sink fan-out: with a webhook-only config (no msmtp at all), hot-unplugging the data disk still lands a DISCONNECTED alert as a JSON POST. |
| `test_disable_data_service_via_conf` | The documented "Disabling Unused Services" recipe works: with `DATA_SERVICES="samba nfs"` in `/etc/conf.d/mountnas`, the supervisor keeps Docker off across a restart, and `nas status` stays exit-0, listing docker as *disabled* rather than warning "not running". |
| `test_supervisor_settles_rpcbind_before_nfs` | The nfs/rpcbind race is fixed: from a fully-stopped rpcbind+nfs (the exact boot-time gap), the fixed supervisor settles rpcbind first and brings nfs up via `nas restart` — previously nfs failed at boot and stayed down until a manual restart (caught by the beta-6 validation dashboard render). The boot-*ordering* half (`after rpcbind` in `depend()`) is validated by the beta-7 release run, since a diskless reboot rebuilds the RAM root from the released apk. |
| `test_ops_log_history_and_no_commit_persistence` | A commit lands in `nas history` with a well-formed record (UTC ts, op, actor with `@`, details), and `/cfg/mountnas-ops.log` survives a reboot **without** any commit — the direct-to-/cfg design. |
| `test_web_dashboard_guide_and_json` **[network]** | `nas web on` serves the dashboard (hostname, services, disks, the docker containers table with a live probe container, the hardware-inventory collapsible with `lsusb -tv`/`lspci`/DIMMs), valid `/status.json`, the full `/guide.html`, and the logo; `nas web status` reports running; the enable is in the ops log; `nas web off` stops serving. Installs busybox-extras from the CDN, hence the marker. The rendered page is saved as a report artifact for visual review. |
| `test_ttyd_browser_terminal` **[network]** | `nas ttyd on` serves the login-prompt terminal on 22222 with the cleartext + commit-honesty warnings, and whitelists ptys in `/etc/securetty` exactly once (root login; idempotency asserted on a second `on`); the dashboard render links "Web terminal" while it runs (and drops the link after `off`); the enable lands in the ops log; `nas ttyd off` stops serving. Installs ttyd from the CDN. |

---

## 5. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `WARNING: /dev/kvm not available` | Nested virt off, or VM CPU type isn't `host` (§1). `--require-kvm` makes this fatal instead. |
| `could not query ... releases; is the repo public?` | The GitHub repo is private or you're offline — pass a local image file instead. |
| Golden build fails at the wizard | Product prompt wording changed — update the regexes in `tests/qemu/lib/config.py` (single source; ci-*.exp scripts share the same contract). |
| Golden build fails at `wait_ssh` | Key injection issue: check `mcopy` output in `pytest.log`; verify `mountnas-sshkey` ran on the guest (`guests/golden-build/serial.log`). |
| A test fails right after a product change to console output | Same as above — the serial contract lives in `lib/config.py` only. |
| Everything times out under TCG | Expected at scale 6 for heavy tests; run `--tier smoke`, or raise `MOUNTNAS_TEST_TIME_SCALE`. |
| `not enough free space under ~/.cache/mountnas-qemu` | Upgrade payload disks are the driver; `rm -rf ~/.cache/mountnas-qemu/golden` frees the most (it rebuilds). |
| A wedged run left qemu processes behind | `pkill -f qemu-system-x86_64` — per-test sockets live in `/tmp/mnq-*` and can be removed. |
| Stale golden after editing the build recipe | Bump `GOLDEN_SCHEMA_VERSION` in `lib/config.py` (invalidates the cache) or delete the cache dir. |
| Report has no screenshots | pytest-html/pillow failed to install in the venv (offline?) — the run still works; rerun `run-suite.sh` online once. |

### Debugging one failing test

```sh
# rerun a single test, keep its disks, stop immediately:
sh tests/qemu/run-suite.sh IMG --keep-guests -- -k test_name -x

# then inspect artifacts/<test-id>/:
#   transcript.txt         every command + output the test ran
#   guest-*/serial.log     full console since power-on
#   guest-*/qemu-cmdline.txt   copy-paste to boot the same VM interactively
```

To poke at a guest by hand, run the `qemu-cmdline.txt` command yourself (its
disks are still there with `--keep-guests`), connect to the serial socket
with `socat - UNIX-CONNECT:/tmp/mnq-*/ser.sock`, or SSH with the suite key:
`ssh -i ~/.cache/mountnas-qemu/golden/*/id_ed25519 -p <port> root@127.0.0.1`
(the port is in `qemu-cmdline.txt` after `hostfwd=tcp:127.0.0.1:`).

---

## 6. Scope notes

**Deliberately NOT covered here** (see `CONTEXT.md` §8):

- Real USB-stick boot on physical hardware (NIC PHYs, microcode early-load,
  real disk spin-up) — QEMU can't stand in for these; they remain the
  manual pass.
- The backup **restore** drill (writing a `nas backup` image to a second
  stick and booting it) — the backup *creation* is tested (C-14).
- SMART **failure** simulation (smartd coverage is the `-M test` mail path;
  emulated-NVMe health-log fault injection is future work).

**Relationship to CI:** the expect-based smoke tests in `scripts/` remain
the blocking pre-publish gate in GitHub Actions (no KVM there). This suite
is the deep, self-hosted layer you run before cutting a release or after
touching the supervisor/upgrade/lbu machinery.
