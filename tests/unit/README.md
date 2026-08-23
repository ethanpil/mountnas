# nas CLI unit tests

Fast tests for `/usr/sbin/nas` and its sourced files (`lib.sh`, `cmd/*.sh`).
They run under **busybox ash on Alpine**, the shell the device uses. Hardware
and the Alpine services are stubs on `PATH`; the shell logic, `awk`, `jq` and
the file handling are real.

The tests install the CLI at its real paths and write real config files
(`/etc/fstab`, `/cfg/...`), so they must run in a **throwaway root**:

```sh
# in a container (what CI does)
docker run --rm -v "$PWD:/repo" alpine:3.24 sh /repo/tests/unit/run.sh
```

```sh
# on an Alpine host without docker: builds an apk root under /tmp and chroots
sh tests/unit/run.sh --chroot
```

`run.sh` refuses to run on a root it cannot tell is disposable.

## Layout

| File | Covers |
|---|---|
| `harness.sh` | `t`, `stub`, `run_nas`, `src_nas`, `assert_*`, `finish` (see its header) |
| `test_dispatch.sh` | help interception, unknown commands, usage errors, the prompt cache |
| `test_lib.sh` | `_uptime_h`, `_data_services`, the conf.d editors, `_snap_note`, `_ops_log`, disk helpers |
| `test_status.sh` | every `nas status` check, the exit code, `--json`, flag order |
| `test_commit_rollback.sh` | commit refusal gates, notes, rotation, `rollback`, `changes` |
| `test_disks.sh` | inventory rendering, paste-ready fstab lines, a hostile label, `--json` |
| `test_upgrade.sh` | argument gates, the YES gate, `--check`, the stage/commit helpers |

## Writing a test

```sh
#!/bin/sh
. "$(dirname "$0")/harness.sh"
stub lbu ':'                              # a fake on PATH; "$@" are its args
t "nas version prints the release"
run_nas version                           # sets OUT and RC
assert_rc 0
assert_match '^MountNAS' "$OUT"
finish
```

For function-level tests, `src_nas` sources `lib.sh` and every `cmd/*.sh` into
the current shell; do that inside `( ... )` so one test's state cannot leak
into the next. A failure inside the subshell is still counted.

Stubs replace commands found on `PATH` (`findfs`, `lsblk`, `rc-service`,
`lbu`, `mountpoint`, `curl`, ...). They do not replace absolute-path calls
such as `/usr/libexec/mountnas/notify`; those run for real.
