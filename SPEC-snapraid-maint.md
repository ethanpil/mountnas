# SPEC: snapraid-maint — scheduled SnapRAID maintenance

Status: DRAFT for review. Not implemented.
Provenance: the step order and the safety model follow Zack Reed's
"Modern SnapRAID Maintenance Script" (v2.2.0, 2026-07-14). The code is
original. We do not copy the script (no license).

## 1. Purpose

Make unattended `snapraid sync` safe. A bare cron line will write a mass
deletion into parity and destroy the one copy that could recover it. This
tool gates the sync, runs the scrub, and reports the result through the
existing MountNAS surfaces.

Protections, in priority order:

1. **Threshold gate** — do not sync when the diff shows too many
   deletions or updates (ransomware, fat-finger `rm`).
2. **Mount preflight** — do not run when a data or parity path is not on
   a mounted disk (the empty-mountpoint catastrophe: snapraid reads an
   empty directory as "all files deleted").
3. **Scrub rotation** — read back a slice of old blocks after each clean
   sync, so silent bit rot is found before a restore needs the blocks.
4. **One run at a time** — a lock stops overlapping cron runs.
5. **Honest reporting** — a verdict in the ops log, the dashboard,
   `nas status`, and the notification sinks.

Non-goals (see §10): service quiescing in v1, SMART/temperature checks
(smartd owns them), spindown, HTML reports, multi-array support.

## 2. Components

| Path | Role | Delivery |
|---|---|---|
| `/usr/libexec/mountnas/snapraid-maint` | the runner; cron calls it | apk (code) |
| `mountnas-tools/files/cmd/snapraid.sh` | `nas snapraid …` surface | apk (code) |
| `/etc/mountnas/snapraid-maint.conf` | user settings | genapkovl seed (person-edited config; lbu captures it; all commit surfaces fire) |
| `/mnt/nasdata/snapraid/logs/` | per-run logs | created by the runner; data disk, never the overlay |
| `/mnt/nasdata/snapraid/state/` | last-run verdict + blocked counter | same |
| `/run/lock/mountnas-snapraid.lock` | flock target | runtime |
| crontab line (marker `# mountnas-snapraid`) | the schedule | written by `nas snapraid schedule`; captured by lbu (`+var/spool/cron/crontabs`) |

POSIX sh (busybox ash). Covered by ci-lint discovery and the unit suite,
like every other shipped script.

## 3. Configuration

Seeded `/etc/mountnas/snapraid-maint.conf` — the complete surface:

```sh
# snapraid-maint — you own this file (edit, then: nas commit).
DEL_THRESHOLD=100       # block sync above this many deleted files (0 = no gate)
UPD_THRESHOLD=200       # block sync above this many updated files (0 = no gate)
SCRUB_PERCENT=7         # scrub the oldest N% of blocks after a clean sync (0 = off)
SCRUB_OLDER_DAYS=10     # scrub only blocks not checked in N days
NOTIFY=problems         # problems | always | never
```

Rules:

- The runner checks `[ -f ]` before it sources the file (a missing file
  must not abort busybox ash). Missing file = the defaults above.
- **Upgrade path (create-if-absent):** the genapkovl seed reaches
  freshly flashed boxes only. When the file is absent, the runner and
  `nas snapraid schedule` write it with the defaults above, so an
  upgraded box gets a file to edit and lbu gets a file to track. Same
  pattern as the conf.d upgrade channel.
- Every value is validated. A bad value falls back to its default and
  the run log says so.
- Scrub needs NO state of ours: snapraid records block ages in its
  content files, and `scrub -p N -o D` uses them.

## 4. Command surface

```
nas snapraid run [--force-sync]   sync + scrub now (foreground, streamed)
nas snapraid schedule [HH:MM]     write the cron line (default 02:00)
nas snapraid schedule off         remove the cron line
nas snapraid status [--deep]      disks + setup chain + last verdict;
                                  --deep adds snapraid's own statistics
```

Decisions embedded here:

- **No `on`/`off`.** Those verbs fit one-switch features (`nas web`).
  Parity is not one switch: `on` would "succeed" at scheduling a job
  that can only fail on an unconfigured box. `schedule` claims exactly
  its scope — the timer, not the array.
- **`--force-sync` is the only override**, valid only with `run`. The
  cron path can never force. The flag skips the threshold gate for one
  run; every other protection still applies.
- **Every subcommand preflights the array** (§6). An unconfigured box
  gets `[FAIL] no array in /etc/snapraid.conf — 'nas disks' finds your
  disks; see the README's SnapRAID section` — never a scheduled job
  that silently fails nightly.
- `schedule` and `schedule off` are idempotent and edit only the line
  carrying the `# mountnas-snapraid` marker. After a change they print
  the persistence warning (`not saved until: nas commit`), the same
  honesty pattern as `nas web`.
- **Existing hand-rolled cron lines:** today's README, guide, and
  `nas help` all tell users to write their own snapraid cron lines, so
  the installed base has them. `schedule` scans the crontab for
  non-marker lines that name snapraid and warns — otherwise parity runs
  twice nightly, once without the gate.
- `schedule` warns when crond is not running (the job would silently
  never fire; `nas status` already shows crond in the service list).
- `run` prints a one-line tmux hint when interactive and `$TMUX` is
  unset: the first sync runs for hours, and a dropped SSH session
  SIGHUPs it (harmless — sync is resumable, the lock releases — but a
  wasted night).

`nas snapraid status` reports the setup chain in order, so the missing
item is always the next step — and a per-disk table so the array's
shape is never a mystery. Everything below comes from snapraid.conf,
/proc/mounts and df (cheap; wakes no disks):

```
[ OK ] array configured   (/etc/snapraid.conf: 4 data, 1 parity)
         d1       data     /mnt/disk1     mounted   3.2T/3.6T
         d2       data     /mnt/disk2     mounted   1.1T/3.6T
         d3       data     /mnt/disk3     mounted   2.0T/3.6T
         d4       data     /mnt/disk4     MISSING   -
         parity   parity   /mnt/parity1   mounted   3.4T/3.6T
[FAIL] disks mounted      (4/5 — d4 not on a mounted disk)
[ OK ] parity >= largest data disk
[ OK ] scheduled          (02:00 nightly — saved)
[ OK ] last run           2026-08-25 02:00 SYNCED (+12 ~3 -0), scrub clean
       full log: /mnt/nasdata/snapraid/logs/maint-20260825-020000.log
```

`nas snapraid status --deep` appends snapraid's own view — the
`snapraid status` per-disk table (files, fragmentation, wasted/free)
and the array scrub ages — plus the tail of the last run's log. Behind
`--deep` for the same reason `nas status` gates it: reading the content
files is slow and wakes spun-down disks. The cheap default must stay
safe to run reflexively.

## 5. Runner algorithm

Steps in order. A step that fails stops the run (except where noted).

```
 1. lock        flock -n /run/lock/mountnas-snapraid.lock  → held: exit 3
 2. config      read + validate /etc/mountnas/snapraid-maint.conf
                (write the defaults file first when it is absent — §3)
 3. preflight   §6                                          → fail: exit 2
 4. diff        snapraid diff → parse added/removed/updated/moved counts
                exit 0 = nothing to do → skip to step 7
 5. gate        removed > DEL_THRESHOLD or updated > UPD_THRESHOLD
                (and the threshold is not 0, and not --force-sync)
                → BLOCKED: exit 1. Parity is NOT touched.
 6. touch+sync  snapraid touch, then snapraid sync → nonzero: exit 4
                (touch AFTER the gate: touched files change timestamps,
                and a box full of zero sub-second files — an rsync from
                FAT is enough — must not inflate the gated updated
                count and block its own first runs. sync re-scans the
                tree, so the touched files sync in this same run.)
 7. scrub       SCRUB_PERCENT > 0 → snapraid scrub -p N -o D
                scrub errors → exit 4 (parity is synced; say so)
 8. report      §8: state file, ops log, notification per NOTIFY policy
```

Exit codes: `0` success / nothing to do · `1` blocked by threshold ·
`2` preflight failure · `3` lock held · `4` a snapraid command failed.

Details:

- **Diff parsing** reads the summary counts from `snapraid diff` output
  and treats its exit code 2 as "differences exist". If the counts
  cannot be parsed, the runner treats the run as BLOCKED (fail closed),
  never as "0 changes".
- **Step 9 always runs**, whatever the exit path after the lock: the
  verdict must reach the state file even for a failure. Signal traps
  release the lock (flock also releases it on process death).
- **Lock held** writes an ops-log entry and exits 3; it notifies only
  when `NOTIFY=always`. A held lock usually means yesterday's sync is
  still running, which is not an emergency. A run that finds the lock
  held AND a state file older than 48 h reports it as a problem.

## 6. Mount preflight (derived, zero config)

The authoritative list of paths is `/etc/snapraid.conf` itself. The
runner parses it — `data` lines (3rd field) and EVERY parity variant
(`parity`, `2-parity` … `6-parity`, `z-parity`; each value may be a
comma-split list of files — take each file's directory). A parse that
matches only `^parity` would pass preflight with a 2-parity disk
unmounted and then degrade that parity. For each path: walk up to the
nearest mountpoint; that mountpoint must not be `/`. (Same walk the box
uses elsewhere; on a diskless box `/` is RAM, so a path that resolves to
`/` means the disk is absent and the directory is an empty shell.)

Rejected alternative: a `REQUIRED_MOUNTS` array in the config file
(Reed's design). Two lists drift; the derived list cannot.

## 7. State, logs, retention

- `state/last-run` — one `key=value` block: `date`, `verdict`
  (`SYNCED|BLOCKED|NOTHING|FAILED`), `deleted`, `updated`, `added`,
  `scrubbed`, `exit`.
- `state/blocked-count` — consecutive BLOCKED runs. Reset on any
  non-blocked run. At 3, the notification subject escalates
  (`snapraid: sync STILL BLOCKED (3 nights)`); a nightly repeat of the
  identical warning is what users learn to ignore.
- `logs/maint-YYYYMMDD-HHMMSS.log` — full command output per run. The
  runner prunes to the newest 60 files.
- `/mnt/nasdata` unwritable: the run continues (the array can be healthy
  without the system disk), logs fall back to `/var/log/mountnas.log`,
  and the report says state could not be saved.

## 8. Reporting

- **Ops log** (`_ops_log snapraid …`): one line per run, every run.
- **Notification** (existing `notify` fan-out; no channel config of our
  own): per `NOTIFY` — `problems` (default) sends on exit 1/2/4,
  `always` also on success, `never` never. Example:

  > `[mountnas] snapraid: sync BLOCKED — 3412 deletions (threshold 100).
  > Parity untouched and still holds yesterday's state. If this change
  > is intentional: nas snapraid run --force-sync`

- **Dashboard** Protection row upgrades from content-file mtime to the
  real verdict (`synced last night · scrub current`); mtime remains the
  fallback when no state file exists.
- **`nas status`** gains one line from `state/last-run`; `--deep` keeps
  the detailed `snapraid status` view it has today.

## 9. Decisions record

| # | Decision | Rejected alternative and why |
|---|---|---|
| D1 | No service quiescing in v1. | `docker pause` from cron: SIGSTOP-frozen containers survive a crashed run (NAS down all night beats "sync saw live writes"); Docker is one writer of three (Samba/NFS keep writing), so it costs without the guarantee; snapraid detects mid-sync changes and defers those files to the next run, so the exposure is a fraction of the normal 24 h window. Future: opt-in `QUIESCE=all` through the supervisor's hold machinery with a trap-guaranteed resume — never behind the supervisor's back. |
| D2 | `schedule`, not `on`/`off`. | §4. Also avoids collision with the removed daemon's `nas snapraid on`. |
| D3 | Mount list derived from snapraid.conf. | §6. |
| D4 | Scrub rotation via snapraid's own block ages. | Own bookkeeping: duplicate state that can disagree with the content files. |
| D5 | State + logs on the data disk. | `/var/…` is RAM (verdict lost at reboot); lbu overlay would need a commit per nightly run. |
| D6 | Config in `/etc`, person-edited. | Fits the commit model: a person edits at a shell, every unsaved-changes surface fires. (The removed daemon failed exactly this test: a program rewrote its config.) |
| D7 | Fail closed on unparseable diff. | Treating parse failure as "no changes" would sync through the gate exactly when snapraid's output format changed. |
| D8 | Own implementation from this spec. | Vendoring: no license, blog-hosted, no repo/tracker; a month-old rewrite is not the battle-tested artifact — the design is, and the design is what this spec keeps. |
| D9 | `touch` runs after the gate, not before diff (Reed runs it before). | Touched files change timestamps; a box full of zero sub-second files would inflate the gated updated count and block its own first runs. sync re-scans, so touched files still sync in the same run. |
| D10 | Every parity variant is parsed (`2-parity`…`6-parity`, `z-parity`, split values). | Matching `^parity` only: preflight passes with a secondary parity disk unmounted, then sync degrades it — the exact failure preflight exists to stop. (`status.sh`'s parity-size check has this same limitation today; out of scope here.) |

## 10. Out of scope (v1)

Service quiescing (D1) · SMART/temperature (smartd) · spindown
(hdparm/smartd) · HTML mail (digest exists) · multi-array ·
Healthchecks-style dead-man ping (candidate for v2; today the README's
crond warning covers the "alerting went blind" case).

## 11. Test plan

**Unit (`tests/unit/test_snapraid.sh`)** — stubbed `snapraid` binary:

- gate blocks at threshold+1, passes at threshold, `0` disables the gate
- `--force-sync` passes the gate; cron path cannot force
- unparseable diff output → BLOCKED (D7)
- preflight fails on an unmounted data dir and an unmounted parity dir
- preflight fails on an unmounted `2-parity` dir and a split-parity
  entry (D10)
- touch runs only after the gate passes; a blocked run touches nothing
- absent conf file: defaults apply, and `schedule` creates the file (§3)
- `schedule` warns on an existing non-marker snapraid cron line
- lock held → exit 3, no sync attempted
- scrub runs only after a clean sync; `SCRUB_PERCENT=0` skips it
- `schedule`/`schedule off` idempotent; only the marker line changes
- `status` chain shows the first missing step on an unconfigured box
- `status` disk table: roles right (incl. `2-parity`), a missing disk
  rows as MISSING and fails the mounted check, no disk is woken
  (stubbed df/mounts only — no snapraid call on the cheap path)
- state file written on success, failure, and block; blocked-count
  escalation at 3
- **Mutation checks** (must FAIL the suite when reintroduced): invert
  the threshold comparison; drop the fail-closed diff branch; make the
  preflight walk accept `/`.

**QEMU (`test_e_storage.py` or K)** — real array, extends the existing
two-disk fixture:

- `nas snapraid run` performs a real sync; `snapraid status` clean
- mass-delete beyond threshold → run exits 1, parity intact, and
  `snapraid fix` restores a deleted file (the protection, proven)
- `--force-sync` then syncs the deletion
- `schedule` writes the crontab line; `status` reports it; `off` removes it

**QEMU verify item** — pin how snapraid 14.7's diff classifies files
after `touch` (the reorder in §5 makes this non-blocking, but the test
records the behavior so a future reorder cannot reintroduce the trap).

**Touch surfaces (complete list; the first four are ci-lint-enforced)**
— dispatcher entry + `_cmd_help_for` + `help_snapraid` ·
bash completion (command list, subcommand branch, help-topic list) ·
zsh completion (same) · `nas help` overview line ·
README (replace the raw-cron guidance) · web-guide (three crontab
examples name snapraid today) · dashboard Protection row ·
`nas status` line + additive `snapraid_last_run` field in `--json` ·
`report.sh` (add the maint conf to its file list and the last-run state
to the bundle) · CHANGELOG · CONTEXT §11 (this design).
