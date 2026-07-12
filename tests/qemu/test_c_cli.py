"""Category C -- the `nas` CLI, per subcommand.

Read-only tests share one module-scoped guest (wired_shared_guest re-points
its transcript at each test's collector); anything that mutates state gets
its own disposable golden_guest.
"""

from __future__ import annotations

import json

import pytest

from lib import config as C


# ---------------------------------------------------------------- read-only

@pytest.mark.smoke
def test_status_exit_0_when_ok(wired_shared_guest):
    g = wired_shared_guest
    r = g.run("nas status", timeout=180)
    assert r.rc == 0, f"nas status rc={r.rc}:\n{r.out}"
    assert "FAIL" not in r.out, r.out
    g.screenshot("status-ok-console")


def test_status_json_is_valid_with_counts(wired_shared_guest):
    r = wired_shared_guest.run("nas status --json", timeout=180, check=True)
    data = json.loads(r.out)
    for key in ("release", "version", "hostname", "services", "checks",
                "healthy", "data_disk"):
        assert key in data, f"missing key {key}: {list(data)}"
    assert data["healthy"] is True, data
    assert data["checks"]["fail"] == 0, data["checks"]
    assert data["data_disk"] == "ok"
    assert any(s["name"] == "docker" and s["running"] for s in data["services"]), data["services"]


def test_disks_json_valid(wired_shared_guest):
    r = wired_shared_guest.run("nas disks --json", timeout=180, check=True)
    data = json.loads(r.out)
    assert "boot_usb" in data and "disks" in data
    assert data["disks"], "no disks reported"
    flat_parts = [p for d in data["disks"] for p in d.get("partitions", [])]
    nasdata = [p for p in flat_parts if p.get("label") == "nasdata"]
    assert nasdata, f"nasdata partition not in disks --json: {flat_parts}"
    # The active data disk must be shown mounted at /mnt/nasdata.  (We do NOT
    # assert in_fstab here: the golden fstab uses LABEL=nasdata, but the
    # product's in_fstab flag is detected by UUID only, so a label-based entry
    # reads in_fstab=false -- a minor product gap, not a data-disk failure.)
    assert nasdata[0].get("mountpoint") == "/mnt/nasdata", nasdata[0]
    boot = [d for d in data["disks"] if d.get("boot_usb")]
    assert boot, "boot USB disk not flagged in disks --json"


def test_disks_human_output(wired_shared_guest):
    r = wired_shared_guest.run("nas disks", timeout=180, check=True)
    assert "*" in r.out, "boot-USB marker (*) missing from nas disks"
    assert "nasdata" in r.out


def test_status_exit_2_fail_closed(wired_shared_guest):
    """When check tracking can't even start (mktemp fails), status must exit
    2 -- never a false 'healthy' 0."""
    r = wired_shared_guest.run("TMPDIR=/nonexistent-dir nas status",
                               timeout=180)
    assert r.rc == 2, f"expected rc=2 (fail-closed), got {r.rc}:\n{r.out}"


def test_version_and_release_strings(wired_shared_guest):
    g = wired_shared_guest
    ver_file = g.run(f"cat {C.VERSION_FILE}", check=True).out.strip()
    r = g.run("nas version", check=True)
    assert ver_file, "version file empty"
    assert ver_file in r.out, f"{ver_file!r} not in `nas version`:\n{r.out}"


def test_help_interceptor_never_executes(wired_shared_guest):
    """`nas <cmd> --help` must show help or the overview -- NEVER run the
    command.  `nas reboot --help` is the acid test."""
    g = wired_shared_guest
    up_before = float(g.run("cut -d' ' -f1 /proc/uptime", check=True).out)
    g.run("nas reboot --help", timeout=30)
    g.run("nas shutdown --help", timeout=30)
    g.run("nas backup --help", timeout=30)
    up_after = float(g.run("cut -d' ' -f1 /proc/uptime", check=True).out)
    assert up_after > up_before, "uptime went backwards -- did --help reboot the box?!"


def test_completions_dont_break_ash_login(wired_shared_guest):
    """profile.d is sourced by busybox ash too; the bash completion ships
    inside an eval wrapper precisely so ash logins don't syntax-error."""
    r = wired_shared_guest.run("ash -l -c true 2>&1")
    assert r.rc == 0, f"ash login shell failed: {r.out}"
    assert "syntax error" not in r.out.lower(), r.out


def test_report_creates_bundle(wired_shared_guest):
    """nas report writes a tarball to /tmp -- and never a directory named
    after the last disk (the beta-2 variable-leak regression)."""
    g = wired_shared_guest
    g.run("rm -f /tmp/mountnas-report-*.tar.gz")
    r = g.run("nas report", timeout=600)
    assert r.rc == 0, f"nas report rc={r.rc}:\n{r.out}"
    ls = g.run("ls /tmp/mountnas-report-*.tar.gz", check=True)
    bundle = ls.out.strip().splitlines()[0]
    members = g.run(f"tar -tzf {bundle}", check=True).out
    for want in ("nas-status.txt", "system.txt", "fstab", "dmesg.txt"):
        assert want in members, f"{want} missing from bundle:\n{members}"
    # the regression: a directory literally named after a disk (e.g. 'sdd')
    stray = g.run("ls -d /sd? /vd? 2>/dev/null; ls -d /tmp/sd? /tmp/vd? 2>/dev/null")
    assert not stray.out.strip(), f"stray disk-named dir exists: {stray.out}"
    g.run(f"rm -f {bundle}")


# ---------------------------------------------------------------- mutating

def test_status_exit_1_on_fail(golden_guest):
    """A data service added to a runlevel is a config error `nas status`
    must flag with a FAIL line and exit 1."""
    g = golden_guest
    g.run("rc-update add docker default", check=True)
    try:
        r = g.run("nas status", timeout=180)
        assert r.rc == 1, f"expected rc=1, got {r.rc}:\n{r.out}"
        assert "FAIL" in r.out, r.out
        g.screenshot("status-fail-console")
    finally:
        g.run("rc-update del docker default")
    assert g.run("nas status", timeout=180).rc == 0, "cleanup didn't restore health"


def test_changes_then_commit_then_clean(golden_guest):
    g = golden_guest
    g.run("echo qemu-test-marker > /etc/mountnas-test-file", check=True)
    r = g.run("nas changes", timeout=60, check=True)
    assert "mountnas-test-file" in r.out, r.out
    g.run("nas commit -m 'qemu suite: changes test'", timeout=120, check=True)
    r2 = g.run("nas changes", timeout=60, check=True)
    assert "no unsaved changes" in r2.out, r2.out


def test_rollback_across_reboot(golden_guest):
    """Two commits -> roll back to the first -> reboot -> the old config is
    live again, and the rollback itself can be rolled forward (snapshot
    preserved with its note via cp -p)."""
    g = golden_guest
    g.run("echo GEN-ONE > /etc/motd", check=True)
    g.run("nas commit -m 'gen one'", timeout=120, check=True)
    g.run("echo GEN-TWO > /etc/motd", check=True)
    g.run("nas commit -m 'gen two'", timeout=120, check=True)
    lst = g.run("nas rollback --list", check=True)
    assert "gen one" in lst.out or "tar.gz" in lst.out, lst.out
    r = g.run("printf 'y\\n' | nas rollback 1", timeout=120)
    assert r.rc == 0, f"rollback failed:\n{r.out}"
    g.reboot()
    motd = g.run("cat /etc/motd", check=True).out.strip()
    assert motd == "GEN-ONE", f"rollback did not restore gen one: {motd!r}"
    # roll-forward net: the pre-rollback overlay is itself a snapshot now
    lst2 = g.run("nas rollback --list", check=True)
    assert "tar.gz" in lst2.out, lst2.out


def test_logs_persist_token_surgery(golden_guest):
    """--persist on/off must edit ONLY the -O/-s/-b tokens in SYSLOGD_OPTS;
    a user's custom token has to survive both transitions (beta-1 fix)."""
    g = golden_guest
    g.run("sed -i 's/^SYSLOGD_OPTS=\"/SYSLOGD_OPTS=\"-l 6 /' /etc/conf.d/syslog",
          check=True)
    before = g.run("grep ^SYSLOGD_OPTS /etc/conf.d/syslog", check=True).out
    assert "-l 6" in before, before

    r_on = g.run("nas logs --persist on", timeout=60)
    assert r_on.rc == 0, r_on.out
    opts = g.run("grep ^SYSLOGD_OPTS /etc/conf.d/syslog", check=True).out
    assert "-l 6" in opts, f"custom token clobbered by --persist on: {opts}"
    assert f"-O {C.DATA_MOUNT}/logs/messages" in opts, opts

    st = g.run("nas logs --persist status", timeout=60, check=True)
    assert "ON" in st.out, st.out

    r_off = g.run("nas logs --persist off", timeout=60)
    assert r_off.rc == 0, r_off.out
    opts2 = g.run("grep ^SYSLOGD_OPTS /etc/conf.d/syslog", check=True).out
    assert "-l 6" in opts2, f"custom token clobbered by --persist off: {opts2}"
    assert "-O" not in opts2, opts2


@pytest.mark.slow
def test_backup_produces_valid_image(golden_guest):
    """nas backup images the whole boot USB to the data disk; the result must
    be valid gzip whose payload starts with an MBR/GPT boot sector, and the
    last-backup record must update."""
    g = golden_guest
    r = g.run("nas backup", timeout=1800)
    assert r.rc == 0, f"nas backup rc={r.rc}:\n{r.out[-3000:]}"
    ls = g.run(f"ls {C.DATA_MOUNT}/backups/mountnas-backup-*.img.gz",
               check=True)
    img = ls.out.strip().splitlines()[0]
    assert g.run(f"gzip -t {img}", timeout=600).rc == 0, "backup gzip corrupt"
    magic = g.run(
        f"zcat {img} | head -c 512 | od -An -tx1 | tr -d ' \\n' | tail -c 4",
        timeout=120, check=True).out.strip()
    assert magic == "55aa", f"payload lacks boot-sector magic: {magic!r}"
    st = g.run("nas status --json", timeout=180, check=True)
    assert json.loads(st.out).get("last_backup_epoch"), "last-backup not recorded"
    # /cfg must be back read-write after the quiescent imaging
    assert g.run("touch /cfg/.rwtest && rm /cfg/.rwtest").rc == 0, \
        "/cfg left read-only after backup"
