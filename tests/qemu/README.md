# MountNAS QEMU test suite

> **Full documentation — requirements, fresh-Alpine walkthrough, result
> interpretation, and the complete per-test catalog — lives in
> [`TESTING-QEMU.md`](../../TESTING-QEMU.md) at the repo root.**
> This file is the quick reference.

Comprehensive automated tests that boot the real `mountnas-<tag>.img.gz`
under QEMU and exercise everything from first boot through hardware-failure
recovery: the wizard, every `nas` subcommand, storage lifecycle, hot
unplug/replug, power cuts mid-upgrade, lbu persistence, the mail pipeline.

This suite is **self-hosted** (it needs KVM for sane runtimes); the existing
CI expect tests in `scripts/` are untouched and remain the pre-publish gate.

## Quick start (fresh Alpine host, e.g. a VM on Proxmox with nested virt)

```sh
apk add git                      # once
git clone https://github.com/ethanpil/mountnas && cd mountnas
sh tests/qemu/run-suite.sh --collect              # sanity: imports + collection
sh tests/qemu/run-suite.sh --tier smoke           # ~15 min: boot/wizard/mail sanity
sh tests/qemu/run-suite.sh                        # full run, ~2.5-3 h under KVM
sh tests/qemu/run-suite.sh mountnas-beta-3.img.gz # test a local image instead
```

Run as **root** (installs packages, and QEMU/KVM is simplest that way).
The report lands in:

```
~/mountnas-qemu-test-suite-result-YYYY-MM-DD/
    mountnas-qemu-test-suite-result-YYYY-MM-DD.html   # self-contained report
    junit.xml  summary.json  pytest.log
    artifacts/<test-id>/    # raw screenshots, transcripts, serial logs
```

With no image argument the latest GitHub release is downloaded (the repo
must be public, same constraint as `nas upgrade --check`). Upgrade tests
also fetch the *previous* release; pass `--previous file.img.gz` to pin it,
or they self-skip / fall back to a current→current upgrade.

## Options

| Flag | Meaning |
|---|---|
| `--tier smoke\|full` | smoke = `-m smoke` subset; full = everything (default) |
| `--previous FILE` | previous-release image for the real upgrade test |
| `--require-kvm` | abort instead of falling back to TCG emulation |
| `--keep-guests` | keep per-test overlay disks + logs for debugging |
| `--collect` | import + collect only; runs nothing, touches no images |
| `-- ...` | passed to pytest verbatim, e.g. `-- -k unplug -x`, `-- -m "not upgrade"` |

Useful pytest selections: `-m "not upgrade"` (skip the slow upgrade block),
`-m faults`, `-k samba`.

## How it works

- **Golden snapshot**: the pristine image is booted once, the wizard driven
  over the serial console, a data disk formatted and committed, then frozen
  as qcow2 backing files under `~/.cache/mountnas-qemu/golden/<sha>-vN/`.
  Every test boots a throwaway overlay in seconds. Bump
  `GOLDEN_SCHEMA_VERSION` in `lib/config.py` when the recipe changes.
- **SSH**: the suite's public key is injected onto the image's FAT BOOT
  partition (`mcopy`, no root needed); the shipped `mountnas-sshkey` service
  installs it at every boot. Assertions run over SSH; the wizard and
  console-only paths use pexpect on the serial socket.
- **Faults**: QMP `device_del`/`device_add` (hot plug), `blkdebug` (EIO),
  `block_set_io_throttle`, and `quit` (power cut).
- **Screenshots**: QMP `screendump` of the VGA console where a real screen
  exists; ANSI→HTML transcripts for every SSH/serial command (nas commands
  never touch the VGA screen -- the transcript *is* their screenshot). On
  failure: final screen, serial log, and guest dmesg are attached
  automatically.
- **No KVM?** The suite warns and continues under TCG with all timeouts
  ×6 (`MOUNTNAS_TEST_TIME_SCALE` to override). Only the smoke tier is
  realistic there.

## Environment variables

| Var | Effect |
|---|---|
| `MOUNTNAS_TEST_CACHE` | cache dir (default `~/.cache/mountnas-qemu`) |
| `MOUNTNAS_TEST_TIME_SCALE` | multiply every timeout (TCG default: 6) |
| `MOUNTNAS_TEST_REPO` | GitHub repo for downloads (default `ethanpil/mountnas`) |
| `MOUNTNAS_OVMF` | UEFI firmware path (auto-discovered; empty = skip UEFI) |

## Debugging a failure

1. Open the HTML report: the failed test carries its screenshots, command
   transcript, final screendump, serial log, and dmesg.
2. `artifacts/<test-id>/` has the same files raw, plus
   `guest-*/qemu-cmdline.txt` -- rerun that command by hand for a live VM.
3. Rerun just the failure with kept disks:
   `sh tests/qemu/run-suite.sh IMG -- --keep-guests -k <testname> -x`
4. `pytest.log` has DEBUG-level serial/QMP/SSH traces for the whole run.

## Layout

```
run-suite.sh        bootstrap: deps, KVM/OVMF checks, venv, pytest invocation
conftest.py         fixtures (golden, guests, sink, http) + report hooks
lib/                guest control (QEMU/QMP/serial/SSH), images, golden,
                    artifacts/transcript rendering, SMTP sink, HTTP server
test_a_boot.py      A: firmware boot, gettys, labels, per-bus disk detection
test_b_wizard.py    B: first-boot wizard flows
test_c_cli.py       C: nas subcommands (status/disks/report/commit/rollback/...)
test_d_upgrade.py   D: in-place upgrades incl. power cuts (marker: upgrade)
test_e_storage.py   E: add-disk, mergerfs, snapraid, fstab guards
test_f_faults.py    F: unplug/replug, EIO, netfs, power cuts (marker: faults)
test_g_services.py  G: docker/samba/zerotier persistence
test_h_lbu.py       H: lbu include/exclude/migration persistence
test_i_mail.py      I: msmtp/mailx/smartd/alert pipeline
test_j_network.py   J: issue banner, mDNS
```

Not covered here (by design): real USB-stick boot on physical hardware and
the backup-restore drill -- see CONTEXT.md §8.
