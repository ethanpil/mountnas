"""Category J -- networking niceties: the issue banner and mDNS."""

from __future__ import annotations

import pytest

from lib import config as C


def test_banner_shows_dhcp_ip(golden_guest):
    """/etc/issue is regenerated with the box's address (gen-issue via the
    if-up hook); under slirp DHCP that is 10.0.2.15.  The banner is what a
    headless user reads off the monitor to find the box."""
    g = golden_guest
    r = g.run("cat /etc/issue", check=True)
    assert C.GUEST_IP in r.out, f"banner lacks the DHCP address:\n{r.out}"
    g.screenshot("issue-banner-vga")


def test_mdns_daemon_advertises_hostname(golden_guest):
    """avahi must be up and answering for <hostname>.local (the wizard's
    rename-and-announce step depends on it)."""
    g = golden_guest
    assert g.run("rc-service avahi-daemon status").rc == 0, \
        "avahi-daemon not running"
    if g.run("command -v avahi-resolve-host-name").rc != 0:
        pytest.skip("avahi-tools not shipped; daemon-status check only")
    r = g.run("avahi-resolve-host-name -4 \"$(hostname).local\"", timeout=60)
    assert r.rc == 0 and C.GUEST_IP in r.out, \
        f"mDNS resolution failed: rc={r.rc} {r.out}"


def test_hostname_change_regenerates_banner(golden_guest):
    """gen-issue must pick up a hostname change (the wizard and the if-up
    hook both lean on it)."""
    g = golden_guest
    g.run("echo renamedbox > /etc/hostname && hostname renamedbox", check=True)
    g.run("/usr/libexec/mountnas/gen-issue", timeout=60, check=True)
    r = g.run("cat /etc/issue", check=True)
    assert "renamedbox" in r.out, f"banner not regenerated:\n{r.out}"
    assert C.GUEST_IP in r.out, r.out
