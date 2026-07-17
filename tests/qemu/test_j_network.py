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
        # avahi-tools joins packages.list at beta-7; against older images,
        # fetch it from the CDN so RESOLUTION is verified instead of skipped
        r = g.run("apk add avahi-tools", timeout=300)
        if r.rc != 0:
            pytest.skip("avahi-tools not shipped and CDN unreachable; "
                        "daemon-status check only")
    # resolution must succeed and return an address the box ACTUALLY holds
    # (not asserting WHICH interface: with docker up the box legitimately has
    # both eth0 and the docker0 bridge, and avahi may answer with either --
    # the interface-preference nuance is tracked separately). This closes the
    # real gap: that <host>.local resolves end-to-end, which was only ever
    # skipped before avahi-tools shipped.
    r = g.run("avahi-resolve-host-name -4 \"$(hostname).local\"", timeout=60)
    assert r.rc == 0, f"mDNS resolution failed: rc={r.rc} {r.out}"
    resolved = r.out.split()[-1].strip()
    box_ips = g.run("ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1",
                    check=True).out.split()
    assert resolved in box_ips, \
        f"mountnas.local resolved to {resolved!r}, not a box address {box_ips}"


def test_hostname_change_regenerates_banner(golden_guest):
    """gen-issue must pick up a hostname change (the wizard and the if-up
    hook both lean on it)."""
    g = golden_guest
    g.run("echo renamedbox > /etc/hostname && hostname renamedbox", check=True)
    g.run("/usr/libexec/mountnas/gen-issue", timeout=60, check=True)
    r = g.run("cat /etc/issue", check=True)
    assert "renamedbox" in r.out, f"banner not regenerated:\n{r.out}"
    assert C.GUEST_IP in r.out, r.out
