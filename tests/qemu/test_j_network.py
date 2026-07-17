"""Category J -- networking niceties: the issue banner and mDNS."""

from __future__ import annotations

import time

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
    # discovery must return the LAN-REACHABLE address, not the docker bridge:
    # by default avahi advertises <host>.local on docker0 too (172.17.0.1),
    # unreachable off the box, and hands it out first (verified via
    # avahi-browse). The seed ships deny-interfaces=docker0 from 1.0rc2 —
    # apply it here against older images so the FIXED behavior is asserted
    # either way.
    if g.run("grep -rq 'deny-interfaces.*docker0' /etc/avahi/ 2>/dev/null").rc != 0:
        g.run("mkdir -p /etc/avahi && printf '[server]\\ndeny-interfaces=docker0"
              "\\n' > /etc/avahi/avahi-daemon.conf", check=True)
        g.run("rc-service avahi-daemon restart", timeout=60, check=True)
    # the address a LAN client would actually use == the default-route source
    primary = g.run("ip -4 route get 1.1.1.1 2>/dev/null "
                    "| sed -n 's/.*src \\([0-9.]*\\).*/\\1/p'", check=True).out.strip()
    assert primary, "no default-route source address on the guest"
    # poll: avahi re-probes the hostname after a config restart (~1-2s)
    resolved = ""
    for _ in range(20):
        r = g.run("avahi-resolve-host-name -4 \"$(hostname).local\"", timeout=30)
        if r.rc == 0 and r.out.split():
            resolved = r.out.split()[-1].strip()
            if resolved == primary:
                break
        time.sleep(1)
    assert resolved == primary, \
        f"mountnas.local resolved to {resolved!r}, not the LAN address {primary!r} " \
        "(avahi advertising the docker bridge?)"


def test_hostname_change_regenerates_banner(golden_guest):
    """gen-issue must pick up a hostname change (the wizard and the if-up
    hook both lean on it)."""
    g = golden_guest
    g.run("echo renamedbox > /etc/hostname && hostname renamedbox", check=True)
    g.run("/usr/libexec/mountnas/gen-issue", timeout=60, check=True)
    r = g.run("cat /etc/issue", check=True)
    assert "renamedbox" in r.out, f"banner not regenerated:\n{r.out}"
    assert C.GUEST_IP in r.out, r.out
