"""Category H -- lbu / diskless config persistence.

Guards the beta-3 landmine: /etc/lbu/{include,exclude} are NOT lbu
interfaces -- the real one is /etc/apk/protected_paths.d/lbu.list with
+path/-path entries.  These tests assert the real mechanism works and the
one-time migration of the old files happens.
"""

from __future__ import annotations

import pytest

LBU_LIST = "/etc/apk/protected_paths.d/lbu.list"


def test_lbu_include_root_persists(golden_guest):
    """/root is a + entry in lbu.list; a file there must survive
    commit + reboot (this exact thing was broken alpha-1..beta-2)."""
    g = golden_guest
    inc = g.run(f"grep '^+' {LBU_LIST}", check=True).out
    assert "root" in inc, f"/root missing from lbu.list includes:\n{inc}"
    g.run("echo persist-me > /root/lbu-probe", check=True)
    g.run("nas commit -m 'lbu include probe'", timeout=120, check=True)
    g.reboot()
    r = g.run("cat /root/lbu-probe")
    assert r.rc == 0 and r.out.strip() == "persist-me", \
        "file under /root did not survive reboot -- lbu include broken"


def test_lbu_exclude_not_captured(golden_guest):
    """- entries (e.g. /etc/issue, regenerated at boot) must not show up as
    unsaved changes when modified."""
    g = golden_guest
    exc = g.run(f"grep '^-' {LBU_LIST}", check=True).out
    assert "issue" in exc, f"/etc/issue missing from lbu.list excludes:\n{exc}"
    g.run("echo TAMPERED >> /etc/issue", check=True)
    st = g.run("lbu status", check=True)
    assert "etc/issue" not in st.out, \
        f"excluded /etc/issue is being tracked by lbu:\n{st.out}"


def test_legacy_lbu_files_migrated_once(golden_guest):
    """Old-style /etc/lbu/include files (shipped by pre-beta-3 seeds) are
    merged into lbu.list by the mountnas service and parked as *.migrated."""
    g = golden_guest
    g.run("mkdir -p /etc/lbu && echo /root/legacy-probe > /etc/lbu/include",
          check=True)
    g.run("rc-service mountnas restart", timeout=180, check=True)
    parked = g.run("ls /etc/lbu/include.migrated 2>/dev/null")
    assert parked.rc == 0, "legacy include file was not parked as .migrated"
    merged = g.run(f"grep -F '+/root/legacy-probe' {LBU_LIST}")
    assert merged.rc == 0, \
        f"legacy include entry not merged into {LBU_LIST}"
    # migration must be one-time: another restart must not duplicate
    g.run("rc-service mountnas restart", timeout=180, check=True)
    count = g.run(f"grep -cF '+/root/legacy-probe' {LBU_LIST}", check=True)
    assert count.out.strip() == "1", f"migration ran twice: {count.out}"


def test_apk_shipped_etc_not_in_lbu_status(golden_guest):
    """apk-shipped files under /etc (profile.d snippets, periodic wrapper)
    must be lbu-excluded, or every commit would capture code the next apk
    upgrade should own."""
    st = golden_guest.run("lbu status", check=True).out
    for shipped in ("profile.d/nas", "periodic/15min/mountnas"):
        assert shipped not in st, \
            f"apk-shipped path {shipped} tracked by lbu:\n{st}"


@pytest.mark.network
def test_user_apk_add_persists_reboot(golden_guest):
    """User-installed packages survive a reboot: cache on MNASCFG + the
    world re-sync in the mountnas service."""
    g = golden_guest
    r = g.run("apk add figlet", timeout=300)
    if r.rc != 0:
        pytest.skip(f"apk add failed (CDN unreachable from guest?): {r.out[-500:]}")
    g.run("grep -qx figlet /etc/apk/world", check=True)
    g.run("nas commit -m 'apk persist probe'", timeout=120, check=True)
    g.reboot()
    got = g.poll_until("command -v figlet", timeout=180,
                       desc="figlet reinstalled after reboot")
    assert got.rc == 0
