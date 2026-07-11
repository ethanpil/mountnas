"""Category B -- first-boot wizard (serial console, pristine image).

The wizard auto-starts at the first root login (profile-nas-welcome.sh) when
no root password is set and /etc/mountnas/setup-done is absent.  Prompt
regexes live in lib/config.py, ported from ci-supervisor-test.exp.
"""

from __future__ import annotations

import pytest

from lib import config as C

PW = "wiztest99"


@pytest.mark.smoke
def test_wizard_full_flow_prompt_order(pristine_guest):
    """All five steps in order, ending at 'Setup complete' and a shell."""
    pristine_guest.run_wizard(hostname="wiztest", password=PW)
    pristine_guest.screenshot("wizard-complete")
    r = pristine_guest.run_serial("hostname")
    assert r.out.strip() == "wiztest", r.out


def test_wizard_flips_permit_empty_passwords(pristine_guest):
    """Once a root password exists the wizard flips the shipped
    `PermitEmptyPasswords yes` to `no` (the one sshd change the wizard is
    allowed to make -- alpha-2 exception)."""
    pristine_guest.run_wizard(password=PW)
    r = pristine_guest.run_serial(
        "grep -i '^PermitEmptyPasswords' /etc/ssh/sshd_config")
    assert r.rc == 0, "PermitEmptyPasswords line missing entirely"
    assert "no" in r.out.lower().split(), f"not flipped: {r.out!r}"


def test_wizard_writes_setup_done_marker(pristine_guest):
    pristine_guest.run_wizard(password=PW)
    r = pristine_guest.run_serial(f"cat {C.SETUP_DONE}")
    assert r.rc == 0 and r.out.strip(), "setup-done marker missing/empty"


def test_wizard_rejects_invalid_hostname(pristine_guest):
    """Hostname validation: an illegal name must re-prompt, not proceed."""
    s = pristine_guest.serial
    s.expect(C.LOGIN, timeout=420)
    s.sendline("root")
    s.expect(C.WIZARD_HOSTNAME, timeout=120)
    s.sendline("bad name!")
    # must come back to the hostname prompt instead of moving to passwd
    idx = s.expect([C.WIZARD_HOSTNAME, C.WIZARD_PASSWORD], timeout=60)
    assert idx == 0, "wizard accepted an invalid hostname"
    pristine_guest.screenshot("invalid-hostname-reprompt")
    # finish cleanly so teardown gets a sane console
    s.sendline("okname")
    s.expect(C.WIZARD_PASSWORD, timeout=60)
    s.sendline(PW)
    s.expect(C.WIZARD_RETYPE, timeout=60)
    s.sendline(PW)
    s.expect(C.WIZARD_TIMEZONE, timeout=60)
    s.sendline("")
    s.expect(C.WIZARD_NETWORK, timeout=60)
    s.sendline("")
    s.expect(C.WIZARD_DONE, timeout=300)


def test_wizard_static_network_path(pristine_guest):
    """The [S]tatic branch prompts interface/IP/gateway/DNS and writes an
    /etc/network/interfaces stanza.  We decline the immediate apply so the
    DHCP-configured console session stays reachable."""
    s = pristine_guest.serial
    s.expect(C.LOGIN, timeout=420)
    s.sendline("root")
    s.expect(C.WIZARD_HOSTNAME, timeout=120)
    s.sendline("")
    s.expect(C.WIZARD_PASSWORD, timeout=60)
    s.sendline(PW)
    s.expect(C.WIZARD_RETYPE, timeout=60)
    s.sendline(PW)
    s.expect(C.WIZARD_TIMEZONE, timeout=60)
    s.sendline("")
    s.expect(C.WIZARD_NETWORK, timeout=60)
    s.sendline("S")
    s.expect(r"[Ii]nterface", timeout=60)
    s.sendline("eth0")
    s.expect(r"IP address", timeout=60)
    s.sendline("10.0.2.15/24")
    s.expect(r"[Gg]ateway", timeout=60)
    s.sendline("10.0.2.2")
    s.expect(r"DNS", timeout=60)
    s.sendline("10.0.2.3")
    s.expect(r"[Aa]pply", timeout=60)
    s.sendline("n")
    s.expect(C.WIZARD_DONE, timeout=300)
    s.expect(C.PROMPT, timeout=120)
    r = pristine_guest.run_serial("cat /etc/network/interfaces")
    assert "static" in r.out, f"no static stanza written:\n{r.out}"
    assert "10.0.2.15" in r.out, r.out


def test_wizard_not_rerun_after_commit_reboot(pristine_guest):
    """After the wizard's closing commit, a reboot must land on a password
    login -- NOT the wizard again (ci-supervisor-test.exp persistence leg)."""
    pristine_guest.run_wizard(password=PW)
    pristine_guest.sendline("/sbin/reboot")
    s = pristine_guest.serial
    s.expect(C.LOGIN, timeout=420)
    s.sendline("root")
    idx = s.expect([C.WIZARD_HOSTNAME, r"[Pp]assword:"], timeout=120)
    assert idx == 1, "wizard re-ran after commit+reboot"
    s.sendline(PW)
    s.expect(C.PROMPT, timeout=60)
    r = pristine_guest.run_serial(f"[ -f {C.SETUP_DONE} ] && echo present")
    assert "present" in r.out


def test_doas_config_root_owned_and_valid(golden_guest):
    """Regression guard for the genapkovl/fakeroot lesson: overlay files must
    land root-owned or doas rejects /etc/doas.conf outright at runtime."""
    r = golden_guest.run("stat -c '%u:%g %a' /etc/doas.conf", check=True)
    assert r.out.split()[0] == "0:0", f"doas.conf not root-owned: {r.out}"
    chk = golden_guest.run("doas -C /etc/doas.conf")
    assert chk.rc == 0, f"doas rejected its config: {chk.out}"
    # a wheel user must actually be covered by a permit rule
    golden_guest.run("adduser -D doastest && adduser doastest wheel",
                     check=True)
    rule = golden_guest.run("doas -C /etc/doas.conf nas status")
    assert rule.rc == 0, f"doas -C evaluation failed: {rule.out}"
