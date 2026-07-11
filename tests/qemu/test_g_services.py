"""Category G -- data services (docker, samba, zerotier) & their persistence.

The docker test is deliberately network-free: the container image is built
by `docker import`-ing a tarball of the guest's own busybox, so no registry
access is needed inside the guest.
"""

from __future__ import annotations

from lib import config as C


def test_docker_container_survives_reboot(golden_guest):
    """A --restart unless-stopped container must come back by itself after a
    reboot (docker state lives on the data disk; the supervisor starts the
    daemon once /mnt/nasdata is up)."""
    g = golden_guest
    g.poll_until("rc-service docker status", timeout=300, desc="docker up")
    g.run(
        "mkdir -p /tmp/rootfs/bin && "
        "cp /bin/busybox /tmp/rootfs/bin/ && "
        "ln -sf busybox /tmp/rootfs/bin/sh && "
        "tar -c -C /tmp/rootfs . | docker import - mnq-busybox",
        timeout=120, check=True,
    )
    g.run("docker run -d --name persist --restart unless-stopped "
          "mnq-busybox /bin/busybox sleep 2147483", timeout=120, check=True)
    r = g.run("docker ps --format '{{.Names}} {{.Status}}'", check=True)
    assert "persist" in r.out and "Up" in r.out, r.out
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


def test_zerotier_identity_persists_reboot(golden_guest):
    """zerotier-one is off by default but its node identity (/var/lib/
    zerotier-one) is an lbu include -- once generated + committed it must
    survive a reboot (identity loss = new node ID = re-auth everywhere)."""
    g = golden_guest
    r = g.run("rc-service zerotier-one start", timeout=120)
    if r.rc != 0:
        # service present? (local apk) -- a missing initd is a packaging bug
        assert g.run("test -x /etc/init.d/zerotier-one").rc == 0, \
            "zerotier-one init script missing entirely"
        raise AssertionError(f"zerotier-one failed to start: {r.out}")
    ident = g.poll_until("cat /var/lib/zerotier-one/identity.public",
                         timeout=120, desc="identity generated")
    node_id = ident.out.strip()
    assert node_id, "empty zerotier identity"
    g.run("rc-service zerotier-one stop", timeout=60)
    g.run("nas commit -m 'zerotier identity probe'", timeout=120, check=True)
    g.reboot()
    after = g.run("cat /var/lib/zerotier-one/identity.public", check=True)
    assert after.out.strip() == node_id, \
        "zerotier identity changed across reboot -- lbu include broken"
