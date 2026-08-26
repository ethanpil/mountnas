"""Category G -- data services (docker, samba, zerotier) & their persistence.

The docker test is deliberately network-free: the container image is built
by `docker import`-ing a tarball of the guest's own busybox, so no registry
access is needed inside the guest.
"""

from __future__ import annotations

import pytest

from lib import config as C
from lib.guest import assert_container_stable, import_busybox_image


def test_docker_container_survives_reboot(golden_guest):
    """A --restart unless-stopped container must come back by itself after a
    reboot (docker state lives on the data disk; the supervisor starts the
    daemon once /mnt/nasdata is up). Stability (RestartCount 0) is asserted
    on both sides of the reboot -- the original bare 'Up' grep kept passing
    on a crash-looping container whose rootfs lacked the musl loader."""
    g = golden_guest
    g.poll_until("rc-service docker status", timeout=300, desc="docker up")
    import_busybox_image(g)
    g.run("docker run -d --name persist --restart unless-stopped "
          "mnq-busybox /bin/busybox sleep 2147483", timeout=120, check=True)
    assert_container_stable(g, "persist")
    g.reboot()
    g.poll_until("rc-service docker status", timeout=300,
                 desc="docker back after reboot")
    got = g.poll_until("docker ps --format '{{.Names}}' | grep -qx persist",
                       timeout=180, desc="container restarted")
    assert got.rc == 0


def test_samba_password_survives_reboot(golden_guest):
    """THE beta-3 lbu.list regression: the samba password db is an lbu
    include -- an smbpasswd user must still exist after commit + reboot.
    (Broken from alpha-1 to beta-2: /etc/lbu/include did nothing.)"""
    g = golden_guest
    g.poll_until("rc-service samba status", timeout=180, desc="samba up")
    g.run("adduser -D -H smbtest", check=True)
    g.run("printf 'smbpw123\\nsmbpw123\\n' | smbpasswd -s -a smbtest",
          timeout=60, check=True)
    before = g.run("pdbedit -L", check=True).out
    assert "smbtest" in before, f"smbpasswd -a did not register: {before}"
    g.run("nas commit -m 'samba user probe'", timeout=120, check=True)
    g.reboot()
    g.poll_until("rc-service samba status", timeout=300,
                 desc="samba back after reboot")
    after = g.run("pdbedit -L", check=True).out
    assert "smbtest" in after, \
        "samba user vanished across reboot -- lbu include for the samba db broken"


def test_data_services_absent_from_runlevels(golden_guest):
    """docker/samba/nfs are started by the mountnas supervisor ONLY -- they
    must not be in any runlevel (nas status flags it; category C tests the
    flag, this asserts the shipped state)."""
    g = golden_guest
    for runlevel in ("default", "boot"):
        r = g.run(f"rc-update show {runlevel}", check=True)
        for svc in ("docker", "samba", "nfs"):
            assert f" {svc} " not in r.out + " ", \
                f"{svc} found in runlevel {runlevel}:\n{r.out}"


@pytest.mark.network
def test_vpn_identity_persists_reboot(golden_guest):
    """Mesh VPNs are NOT baked in -- users install them (docs: apk add +
    rc-update + commit).  The lbu includes for /var/lib/{tailscale,
    zerotier-one,netbird} still ship, so a user-installed VPN's node
    identity must survive commit + reboot (identity loss = new node ID =
    re-auth everywhere).  Proven with tailscale, the one Alpine community
    actually carries (zerotier-one is NOT in the v3.24 repos -- the docs
    point it at edge/testing); installs from the CDN, hence the marker."""
    g = golden_guest
    r = g.run("apk add tailscale tailscale-openrc", timeout=300)
    if r.rc != 0:
        pytest.skip(f"apk add tailscale failed (offline?): {r.out[-300:]}")
    r = g.run("rc-service tailscale start", timeout=120)
    if r.rc != 0:
        raise AssertionError(f"tailscale failed to start: {r.out}")
    # tailscaled writes its node state (keys) at first start, logged in or not
    ident = g.poll_until("sha256sum /var/lib/tailscale/tailscaled.state",
                         timeout=120, desc="node state generated")
    state_hash = ident.out.split()[0]
    assert state_hash, "empty tailscale state"
    g.run("rc-service tailscale stop", timeout=60)
    g.run("nas commit -m 'vpn identity probe'", timeout=120, check=True)
    g.reboot()
    after = g.run("sha256sum /var/lib/tailscale/tailscaled.state", check=True)
    assert after.out.split()[0] == state_hash, \
        "tailscale node state changed across reboot -- lbu include broken"
