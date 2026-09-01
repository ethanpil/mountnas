# SPEC: four differentiation features

Status: DRAFT for review. Not implemented. Order of build: §3 (config
mirror) → §2 (shares) → §1 (disks init) → §4 (doc generation). Each is
its own change set with its own spec-review-test cycle; this document is
the shared design record. Maintainer notes from 2026-08-26 are folded in
and marked **[note]**.

---

## 1. Storage bootstrap — `nas disk init` + `nas mount` + `nas snapraid add`

Three narrow commands that chain into one story: a disk goes from
shrink-wrap to parity-protected without opening an editor. The split is
a safety statement — exactly ONE command can destroy data, and the
other two never can.

### Command surface

```
nas disks init [/dev/sdX]      DESTRUCTIVE: format a BLANK disk, then chain
                               into the mount flow below
nas disk  ...                  alias of `nas disks` (all subcommands)   [note]
nas mount [dev|serial|uuid|label]
                               NEVER formats: fstab + mount for an
                               already-formatted partition             [note]
nas snapraid add <mnt> [--parity]
                               append the array lines (data+content, or
                               parity) to /etc/snapraid.conf           [note]
```

`nas mount` with no argument lists the partitions not yet in fstab and
asks; `disks init` with no argument lists the BLANK disks. The chain:
init → (mount flow) → offer `snapraid add` for data/parity roles →
remind `nas snapraid run` + `nas commit`.

### UX

```
# nas disk init /dev/sdb
  /dev/sdb: WDC WD40EFRX-68N32N0  4.0 TB — BLANK (no partitions, no signatures)
  Role?
    [1] nasdata   the system disk (Docker, appdata, backups) — required once
    [2] data      a storage disk (joins the pool / SnapRAID array)
    [3] parity    a SnapRAID parity disk
  : 2
  Filesystem [ext4/xfs, default ext4]:
  Contents?  (sets the ext4 inode density — xfs allocates dynamically)
    [1] mostly large files   videos, backups, disk images  (1 inode / 1 MB)
    [2] mixed or small files photos, music, documents      (mkfs default)
  : 1
  Plan: GPT, one partition, mkfs.ext4 -L disk1 -i 1048576 -m 0
        fstab: UUID=...  /mnt/disk1  ext4  rw,noatime,nofail  0 2
  This ERASES /dev/sdb (serial WD-WCC7K4NL2856).
  Type the LAST 4 characters of the serial to continue: 2856
  [ OK ] partitioned + formatted (label disk1)
  [ OK ] fstab line appended
  [ OK ] mounted at /mnt/disk1 (via the supervisor)
  Add it to the SnapRAID array now? [Y/n]: y
  [ OK ] snapraid.conf: + data d1 /mnt/disk1
  [ OK ] snapraid.conf: + content /mnt/disk1/snapraid.content
  hint  parity is not synced yet — run: nas snapraid run
  [WARN] not saved — nas commit
```

### Decisions

- **`nas disk` is a dispatcher alias of `nas disks`** [note] — same
  mechanism as `changes|changed`: one case arm `disks|disk)`, one help
  map entry, both completion files, and the ci-lint alias handling that
  already exists for the other pairs.
- **The inode question, ext4 only** [note]. ext4 fixes the inode table
  at mkfs time; the default (1 inode per 16 KB) wastes ~1 GB of inode
  table per TB and is far more than a media disk ever uses. Choices map
  to: large files → `-i 1048576` (1 inode/MB — still ~4M inodes on a
  4 TB disk, plenty for media plus clutter); mixed/small → mkfs default.
  The prompt states the tradeoff in one line; for xfs the question is
  skipped with the reason printed ("xfs allocates inodes dynamically").
  There is no wrong answer that loses data — only wasted table space or,
  in the extreme small-files-on-large-preset case, running out of inodes
  with space free; the hint names `df -i` as the check.
- **Reserved blocks**: data and parity roles get `-m 0` (ext4's 5% root
  reserve is ~200 GB on a 4 TB disk and exists to keep a ROOT fs
  operable — meaningless on a data disk). nasdata keeps `-m 1`: it hosts
  Docker and logs, and a hard-full nasdata is an operational failure the
  reserve softens.
- **Blank means blank.** Refuse any disk with a partition table or
  filesystem signature (`blkid` + `wipefs -n` probe). No `--force` in
  v1: a used disk must be wiped by hand first (`wipefs -a`, documented
  in the refusal message). This keeps the command incapable of the
  catastrophic mistake.
- **The confirm token is the serial's last 4 characters**, not YES —
  it proves the operator is looking at the right physical disk, which
  is the real failure mode (sdb/sdc confusion).
- Role → mountpoint convention: nasdata → `/mnt/nasdata` (refused if
  fstab already maps one), data → next free `/mnt/diskN`, parity →
  next free `/mnt/parityN`. Labels match the mountpoint (disk1 …).
- Parity role: ext4 with `-i 1048576 -m 0` (parity is one huge file).
  Data and parity roles end by OFFERING `nas snapraid add` (below) —
  the conf edit happens only through that one append-only path, and
  only on an explicit yes.

### `nas mount` [note]

Covers the case init's blank-only gate refuses: an ALREADY-formatted
disk (moved from another machine, an existing media drive). Resolves
the argument as a device path, serial, UUID or label; validates: the
partition has a filesystem, is not already in fstab, and is NEVER the
boot USB (the same check `nas status` fails on). A partition currently
mounted by hand is detected and offered "make permanent here, or move
to a role mountpoint". Role prompt (data/parity/nasdata/custom path) →
append the fstab line → supervisor mount → status. Append-only: the
command never edits or removes existing fstab lines — fstab remains the
user-owned source of truth, this is a typing aid. Its help says the
quiet part: permanent mounts only; one-off mounts stay plain mount(8).

### `nas snapraid add` [note]

Justified by the real trap, not the trivial line: a correct array needs
CONTENT lines on multiple disks, and snapraid hard-refuses to run with
fewer than two copies — the mistake beginners actually make (and the
refusal we hit ourselves in testing). So:

- data:   appends `data dN <mnt>` (next free dN) AND
          `content <mnt>/snapraid.content`
- parity: appends `parity <mnt>/snapraid.parity` (or `2-parity` when
          a parity line already exists — every variant the preflight
          parses) AND `content <mnt>/snapraid.content`
- **the ≥2-content invariant** (review finding): snapraid refuses to
  run with fewer than two content copies on different disks, so every
  `add` ends by counting content lines. Below two, it offers the house
  convention `content /mnt/nasdata/snapraid.content` (nasdata may hold
  a CONTENT file — only array data is excluded; the seeded template's
  own commented example) when nasdata is mounted, and otherwise warns
  plainly: "the array needs a second content copy before the first run".
- guards: path on a mounted disk (the walk), NOT /mnt/nasdata as a
  data/parity disk (the one rule the seeded conf shouts), not already
  present in the conf
- append-only into the user-owned file; prints exactly what it added,
  then reminds `nas snapraid run` (first sync) + `nas commit`

**`snapraid remove` deliberately does NOT exist**: pulling a disk from
an array has parity-rebuild semantics, and a command would make it look
safer than it is. Removal stays a documented manual procedure.

### Files touched

`cmd/disks.sh` (init + helpers), new `cmd/mount.sh`, `cmd/snapraid.sh`
(add subcommand), `files/nas` (alias arm + mount entry), both
completions + help map (ci-lint enforces all of it), README Quick Start
(the manual steps become "or: `nas disk init`"), guide Storage section,
tests.

### Tests

Unit: role→mountpoint selection, blank-disk gate (stubbed blkid/wipefs
outputs), serial-confirm mismatch aborts pre-write, inode flag mapping,
xfs skips the inode prompt; mount: identifier resolution (dev/serial/
UUID/label), already-in-fstab and boot-USB refusals, append-only
(existing lines byte-identical after a run — mutation check); snapraid
add: dN numbering, content line added with data, 2-parity escalation,
nasdata refused, duplicate refused.
QEMU (extends `golden_with_extras`): init a blank extra disk end-to-end
via pty answers → mounted, `nas status` clean, fstab line correct,
`tune2fs -l` shows the inode ratio and 0% reserved; a second run refuses
the now-used disk and `nas mount` picks it up instead; the full chain
init → mount → snapraid add → `nas snapraid run` syncs a real array.

---

## 2. Share management — `nas share`

First-class Samba shares without hand-editing smb.conf — while never
touching what the user hand-edited.

### Command surface

```
nas share                        list all shares (generated AND hand-written)
nas share add <name> <path>      create a share (prompts for access)
nas share remove <name>
nas share mode <name> rw|ro      whole-share default access        [note]
nas share allow <name> <user> [--ro]   grant a user (optionally read-only)
nas share revoke <name> <user>
nas share user add <user>        Linux user (no shell) + smbpasswd  [note]
nas share user passwd <user>     change a Samba password            [note]
nas share user remove <user>
```

### Answers to the open questions [note]

- **`nas share user …` — yes, it is needed.** A Samba credential is a
  Linux account plus an smbpasswd entry; without the subcommand the
  first share still requires knowing `adduser -H -s /sbin/nologin` +
  `smbpasswd -a`. `user add` creates a shell-less, home-less system
  user and calls `smbpasswd -a` (interactive prompt — the password is
  never a command argument, so it cannot land in shell history or the
  ops log). Persistence is already solved: passdb.tdb is in the lbu
  include, `/etc/passwd` is /etc.
- **Password change** = `nas share user passwd <user>` → `smbpasswd
  <user>` (its own double prompt). The Linux account keeps no usable
  password at all (`passwd -l` state) — these users exist for SMB only,
  so there is exactly ONE password per user and it is the SMB one.
- **Per-share user membership** = `allow`/`revoke`, mapping to the
  share's `valid users =` list.
- **Read-only vs full access — not full-access-only, but exactly two
  levels.** Whole-share default via `mode rw|ro` (`read only = yes/no`)
  and per-user exception via `allow --ro` (`read list =`). That covers
  the real household cases ("the kids can read the media share, I can
  write it") without inventing an ACL matrix. Anything finer is
  hand-edit territory, and stays possible (below).

### Mechanics

- The command owns ONE generated file: `/etc/samba/mountnas-shares.conf`.
  The seeded `smb.conf` gains a single `include = /etc/samba/mountnas-shares.conf`
  line (create-if-absent on upgraded boxes, same pattern as
  snapraid-maint.conf). Hand-written shares in smb.conf are never
  parsed for editing, never rewritten, and always shown by `list`
  (via `testparm -s`, which is also how list gets effective values
  rather than trusting our own file).
- The generated file IS the state — one `[section]` per share, written
  only from the fixed template, so it round-trips safely:

```
[media]                         ; managed by nas share — edit via the command
path = /mnt/pool/media
valid users = ethan, kids
read list = kids
read only = no
```

- Guest shares: `add --guest` sets `guest ok = yes` and forces
  `read only = yes` unless `--guest-rw` is given explicitly (a
  world-writable guest share is a choice, not a default).
- Every mutation: validate the path is on a mounted data disk (the
  mountpoint-walk helper; a share on the RAM root is the classic
  footgun and `nas status` already fails on it) → write → `testparm -s`
  gate (a failed parse restores the previous file byte-for-byte) →
  `rc-service samba reload` → persistence-honesty warning until
  `nas commit`.
- `remove` deletes the section only; the data directory is never
  touched (say so in the output).

### Deliberately out (v1)

NFS exports (different auth model; the include-file pattern extends
later), per-directory permissions, quotas, recycle bins. All remain
reachable by hand-editing smb.conf, which the never-clobber contract
protects.

### Tests

Unit (stubbed testparm/smbpasswd/rc-service): add/list/remove
round-trip, mode + allow/--ro emit the right keys, revoke of the last
user, guest defaults to ro, RAM-root path refused, failed testparm
restores the previous file (mutation: break the restore — suite fails),
user add never passes the password on a command line.
QEMU: real end-to-end — user add, share add, `smbclient -U` write to an
rw share succeeds / write to an ro grant fails, reboot, both survive
(passdb + config via commit).

---

## 3. Config backup — tier 1 only [note]

Every commit mirrors the fresh overlay to the data disk. The
worst-case story ("the stick died") becomes: flash a new stick, copy
one file, boot — config, users and passwords intact.

### Mechanics

- At the end of a successful `cmd_commit`: copy the just-written
  overlay to `/mnt/nasdata/config-backups/<host>-<UTCstamp>.apkovl.tar.gz`
  (dir 0700, files 0600 — the overlay holds password hashes and host
  keys). Retention: newest 30. nasdata absent → skipped with a hint,
  never an error (commit already succeeded; the mirror is best-effort).
- One new line in commit's output: `mirrored to /mnt/nasdata/config-backups/ (30 kept)`.
- Protection card + `nas status` gain "Config mirror: <age>" (or
  "off — data disk absent"), same cheap-read pattern as every other row.
- **Restore is documentation, not code** — README + guide get a
  "Boot stick died" walkthrough: flash the release image, mount the new
  stick's MNASCFG on any machine (or boot the fresh box), copy the
  newest mirror to `MNASCFG/<host>.apkovl.tar.gz`, boot. Three steps,
  no tooling to maintain, works from any OS that reads ext4.
- **Off-site stays the user's job, and the design makes it free**
  [note]: because the mirror lives ON the data disk, any off-site
  backup of the data disk (restic/rclone/borg — all baked in) already
  includes the config. The docs say exactly that, plus one warning:
  the mirror contains password hashes and SSH host keys, so an off-site
  copy belongs in an ENCRYPTED backup (restic and borg encrypt by
  default; plain rclone copy does not).

### Tests

Unit: mirror written on commit, permissions 0700/0600, retention prunes
to 30, absent nasdata = hint not error (mutation: make it an error —
suite fails). QEMU: commit → mirror exists; the restore drill test
gains a variant that restores from the mirror instead of the full-USB
image (this is the money test: it proves the documented recovery).

---

## 4. Single-source manual — generation with a depth layer

### The terseness problem [note], resolved by two layers in one file

The concern is real: `help_snapraid` must stay terse (it renders in a
terminal, often over serial), but the guide wants paragraphs. Forcing
one text to serve both ruins both. The design keeps ONE FILE per
command as the single source, with two blocks in it:

```sh
# cmd/share.sh
help_share() {            # canonical: terminal help, README/guide tables
	cat <<EOF
nas share [add|remove|mode|allow|revoke|user|list]
  Samba shares without hand-editing smb.conf ...
EOF
}

doc_share() {             # OPTIONAL guide-only depth; never shown in a terminal
	cat <<EOF
Shares created here live in /etc/samba/mountnas-shares.conf, included
from smb.conf; anything you hand-write in smb.conf is left alone and
still listed. Users created by 'nas share user add' are SMB-only ...
EOF
}
```

- `help_*` stays the single source for usage + flags — it is the copy
  drift already keeps honest, because `nas x --help` makes errors
  user-visible.
- `doc_*` (optional, plain prose, no markup) is appended ONLY to the
  generated guide entry. No `doc_*` → the guide entry is just the help
  text, which for simple commands (version, about, history) is already
  enough. Terse-by-design commands stay terse in the terminal; the
  guide gets depth exactly where depth exists to give.
- Both blocks live in the same cmd/<name>.sh, so "document this
  command" is always an edit to one file — that is the whole
  single-source claim. Editing a command and its docs is one diff.

### Generation

- `scripts/gen-docs.sh` (plain sh, no toolchain): sources lib.sh +
  cmd/*.sh in a sandbox shell, captures `help_*`/`doc_*` output,
  HTML-escapes it, and rewrites the marked regions:

```
README.md:        <!-- generated:commands --> … <!-- /generated -->
web-guide.html:   <!-- generated:commands --> … <!-- /generated -->
```

  Output is checked in — users and GitHub readers never run anything.
- **ci-lint gains one guard**: run the generator into a temp copy,
  diff against the committed files; drift fails with "run
  scripts/gen-docs.sh". Identical shape to the completions guard.
- Prose sections (philosophy, storage walkthrough, failure recovery)
  stay hand-written per audience — README sells, guide teaches; only
  the thrice-copied mechanical reference is generated.
- Migration: first run replaces the guide's Command manual table and
  the README's command table; a diff review of that first generation
  IS the audit of today's drift.

### Tests

ci-lint drift guard (self-testing by construction); unit case: a
cmd file with doc_* renders both blocks, one without renders help only;
the generator is idempotent (second run = no diff).

---

## Effort and sequencing

| # | Change set | Size | Depends on |
|---|---|---|---|
| 3 | commit mirror + restore docs | S (~1 day incl. QEMU restore variant) | — |
| 2 | nas share (+ users) | M (the largest; smbpasswd/testparm plumbing + 2 QEMU tests) | — |
| 1 | disk init + nas mount + snapraid add | M | — |
| 4 | doc generation + guard | S | benefits from 1–3 landing first so their docs are born generated |

All four follow the house cycle: spec section frozen → implement →
unit with mutation checks → QEMU → docs → logical commits.
