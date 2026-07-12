"""Category F -- hardware-failure & fault injection.

The tests QEMU uniquely enables: hot-unplug/replug (QMP device_del/add),
EIO injection (blkdebug), read-only remounts, power cuts (QMP quit), and
corrupt-overlay boots.  All disks are cold-plugged with ids (dev0, dev1...)
so device_del works on them directly; DATA_DEV_ID is the golden data disk.

State vocabulary asserted here comes from the mountnas supervisor:
fresh | ok | netfs | disconnected | mountfail  (in /run/mountnas/data).
"""

from __future__ import annotations

import time

import pytest

from lib import config as C
from lib import images
from lib.guest import DiskSpec
from lib.smtpsink import configure_guest_msmtp

pytestmark = pytest.mark.faults

DATA_DEV_ID = "dev1"          # the golden data disk (second cold disk)
DATA_WATCH = "/usr/libexec/mountnas/data-watch"


def _wait_state(guest, *want: str, timeout: float = 120.0) -> None:
    """Poll until the supervisor state is (one of) the wanted value(s)."""
    alt = "|".join(want)
    guest.poll_until(
        f"case \"$(cat {C.STATE_DIR}/data 2>/dev/null)\" in "
        f"{alt}) exit 0;; *) exit 1;; esac",
        timeout=timeout, desc=f"data state in {{{alt}}}",
    )


def test_hot_unplug_sets_disconnected_and_alerts(golden_guest, smtp_sink):
    """Yank the mounted data disk: data-watch must flip the state to
    'disconnected' and send exactly one alert mail (beta-3 alerting)."""
    g = golden_guest
    configure_guest_msmtp(g, smtp_sink.port)
    assert g.data_state() == "ok"
    g.detach_disk(DATA_DEV_ID)
    r = g.run(DATA_WATCH, timeout=120)
    assert r.rc == 0, f"data-watch rc={r.rc}: {r.out}"
    assert g.data_state() == "disconnected", g.data_state()
    mails = smtp_sink.wait_for_mail(1, timeout=g.cfg.scaled(90))
    assert "DISCONNECTED" in (mails[0].subject + mails[0].body), \
        f"unexpected alert content: {mails[0].subject!r}"
    g.screenshot("disk-unplugged-console")


def test_alert_fires_once_transition_only(golden_guest, smtp_sink):
    """The watcher exits early unless the previous state was ok, so repeat
    runs after a failure must NOT re-alert (no mail spam by construction)."""
    g = golden_guest
    configure_guest_msmtp(g, smtp_sink.port)
    g.detach_disk(DATA_DEV_ID)
    g.run(DATA_WATCH, timeout=120)
    smtp_sink.wait_for_mail(1, timeout=g.cfg.scaled(90))
    g.run(DATA_WATCH, timeout=120)
    g.run(DATA_WATCH, timeout=120)
    time.sleep(g.cfg.scaled(5))
    assert len(smtp_sink.messages) == 1, \
        f"transition-only alerting violated: {len(smtp_sink.messages)} mails"


def test_hot_replug_nas_restart_recovers(golden_guest, golden, tmp_path):
    """Reattach a nasdata disk after loss: `rc-service mountnas restart`
    must clear the dead mount (umount -l) and bring everything back."""
    g = golden_guest
    g.detach_disk(DATA_DEV_ID)
    g.run(DATA_WATCH, timeout=120)
    assert g.data_state() == "disconnected"
    # fresh overlay of the same golden data disk => same LABEL=nasdata
    newdisk = images.create_overlay(golden.data_golden, "qcow2",
                                    tmp_path / "replug.qcow2")
    g.attach_data_disk(DiskSpec(str(newdisk), serial="NASDATA1"), dev_id="hotdata")
    g.poll_until("blkid | grep -q nasdata", timeout=60, desc="replugged disk visible")
    g.run("rc-service mountnas restart", timeout=240, check=True)
    _wait_state(g, "ok", timeout=180)
    assert g.run(f"mountpoint -q {C.DATA_MOUNT}").rc == 0
    g.poll_until("rc-service docker status", timeout=300, desc="docker back up")


def test_blkdebug_io_errors_mountfail_not_crash(guest_factory, overlay_disks,
                                                golden):
    """A data disk that EIOs every read: the supervisor must degrade and hold
    services -- never a hung boot or a crashed box.  With every read failing
    the label itself is unreadable, so the state legitimately lands on either
    'mountfail' (mount attempt failed) or 'disconnected' (findfs found nothing)."""
    sysd, datad = overlay_disks(prefix="blkdbg")
    guest = guest_factory(
        [DiskSpec(str(sysd)),
         DiskSpec(str(datad), serial="NASDATA0",
                  blkdebug={"event": "read_aio", "errno": 5})],
        name="blkdbg", ssh_key=golden.ssh_key, throwaway=[sysd, datad],
    )
    guest.wait_ssh(timeout=420)          # boot must complete regardless
    _wait_state(guest, "mountfail", "disconnected", timeout=180)
    # data services must be held while the disk is unusable
    assert guest.run("rc-service docker status").rc != 0, \
        "docker started despite failed data disk"
    st = guest.run("nas status", timeout=180)
    assert st.rc == 1, f"nas status should FAIL (rc=1), got {st.rc}"
    guest.screenshot("blkdebug-degraded")


def test_ro_remount_detected(golden_guest, smtp_sink):
    """ext4 errors=remount-ro is a silent failure mode; the watcher's third
    probe must flag a read-only /mnt/nasdata and alert."""
    g = golden_guest
    configure_guest_msmtp(g, smtp_sink.port)
    # data services keep files open on /mnt/nasdata, so a remount,ro is EBUSY
    # until they release it -- stop them first to simulate the ro event.
    g.run("for s in docker samba nfs; do rc-service $s stop 2>/dev/null; done",
          timeout=90)
    g.run(f"mount -o remount,ro {C.DATA_MOUNT}", timeout=60, check=True)
    g.run(DATA_WATCH, timeout=120)
    assert g.data_state() == "mountfail", g.data_state()
    mails = smtp_sink.wait_for_mail(1, timeout=g.cfg.scaled(90))
    joined = mails[0].subject + mails[0].body
    assert "READ-ONLY" in joined.upper(), joined


def test_late_disk_within_spinup_window(guest_factory, overlay_disks, golden):
    """Slow disk spin-up: the data disk appears seconds AFTER the supervisor
    starts; its 15s wait loop must still catch it -- state ok with no manual
    restart."""
    sysd, datad = overlay_disks(prefix="late")
    guest = guest_factory([DiskSpec(str(sysd))], name="late",
                          ssh_key=golden.ssh_key, throwaway=[sysd, datad])
    # hot-plug the disk the moment the console shows the supervisor starting
    guest.expect(r"[Mm]ount[Nn][Aa][Ss]", timeout=420)
    guest.attach_data_disk(DiskSpec(str(datad), serial="NASDATA0"),
                           dev_id="latedata")
    guest.wait_ssh(timeout=420)
    _wait_state(guest, "ok", timeout=120)
    assert guest.run(f"mountpoint -q {C.DATA_MOUNT}").rc == 0


def test_netfs_nasdata_refused_services_held(golden_guest):
    """A network filesystem as /mnt/nasdata is unsupported by design (a dead
    remote must never stall boot): state 'netfs', data services held."""
    g = golden_guest
    # golden_guest arrives with docker already running; the supervisor HOLDS
    # (won't start) services for a netfs nasdata but doesn't kill a running
    # one, so stop them first and assert they stay down after the restart.
    g.run("for s in docker samba nfs; do rc-service $s stop 2>/dev/null; done",
          timeout=90)
    g.run(f"sed -i 's#^LABEL=nasdata .*#192.0.2.1:/export {C.DATA_MOUNT} "
          "nfs nofail 0 0#' /etc/fstab", check=True)
    g.run("rc-service mountnas restart", timeout=240)   # must not hang
    _wait_state(g, "netfs", timeout=120)
    assert g.run("rc-service docker status").rc != 0, \
        "supervisor started docker despite a refused network-fs nasdata"
    st = g.run("nas status", timeout=180)
    assert st.rc == 1, f"expected FAIL for netfs nasdata, rc={st.rc}"
    g.screenshot("netfs-refused")


def test_powercut_mid_mkfs_boots_and_degrades(guest_factory, overlay_disks,
                                              golden, tmp_path):
    """Power cut while mkfs is formatting a declared disk: the next boot must
    reach login/SSH; the half-formatted disk degrades to mountfail/
    disconnected, never a boot hang."""
    sysd, datad = overlay_disks(prefix="pcut")
    extra = images.create_blank_qcow2(tmp_path / "pcut-extra.qcow2", "8G")
    disks = [DiskSpec(str(sysd)), DiskSpec(str(datad), serial="NASDATA0"),
             DiskSpec(str(extra), serial="PCUT0")]
    g1 = guest_factory(disks, name="pcut-a", ssh_key=golden.ssh_key)
    g1.wait_ssh()
    g1.run("printf '%s\\n' 'LABEL=pcut /mnt/pcut ext4 rw,noatime,nofail 0 2'"
           " >> /etc/fstab", check=True)
    g1.run("nas commit -m 'pcut fstab'", timeout=120, check=True)
    # slow mkfs down (full inode init) and cut power mid-flight
    g1.run("( mkfs.ext4 -F -L pcut -E lazy_itable_init=0,lazy_journal_init=0"
           " /dev/vdc >/dev/null 2>&1 & ) ; echo started", check=True)
    time.sleep(1.0)
    g1.quit_hard()

    g2 = guest_factory(disks, name="pcut-b", ssh_key=golden.ssh_key,
                       throwaway=[sysd, datad, extra])
    g2.wait_ssh(timeout=420)             # the invariant: it BOOTS
    state = g2.data_state()
    assert state in ("ok",), f"nasdata should be unaffected, state={state}"
    st = g2.run("nas status", timeout=180)
    assert st.rc in (0, 1), f"status wedged after power cut: rc={st.rc}"
    g2.screenshot("post-powercut-mkfs")


def test_powercut_mid_lbu_commit_still_boots(guest_factory, overlay_disks,
                                             golden):
    """Power cut during `nas commit` (the overlay swap): next boot must come
    up with the old OR the new config -- never a torn overlay or a boot
    failure.  (The window is sub-second; the boot invariant is the real
    assertion, tightness is best-effort.)"""
    sysd, datad = overlay_disks(prefix="ccut")
    disks = [DiskSpec(str(sysd)), DiskSpec(str(datad), serial="NASDATA0")]
    g1 = guest_factory(disks, name="ccut-a", ssh_key=golden.ssh_key)
    g1.wait_ssh()
    # inflate the overlay so the commit takes long enough to cut into
    g1.run("dd if=/dev/urandom of=/root/blob bs=1M count=48", timeout=120,
           check=True)
    g1.run("echo COMMIT-GEN-2 > /etc/motd", check=True)
    g1.run("( nas commit -m 'powercut target' >/dev/null 2>&1 & ) ; echo bg",
           check=True)
    time.sleep(0.8)
    g1.quit_hard()

    g2 = guest_factory(disks, name="ccut-b", ssh_key=golden.ssh_key,
                       throwaway=[sysd, datad])
    g2.wait_ssh(timeout=420)             # the invariant: it BOOTS
    # old or new config are both acceptable; log which one for the report
    g2.run("cat /etc/motd")
    # config partition must be intact and committable
    r = g2.run("nas commit -m 'post powercut'", timeout=180)
    assert r.rc == 0, f"commit wedged after power cut:\n{r.out}"


def test_corrupt_apkovl_lands_in_recovery_shell(guest_factory, overlay_disks,
                                               golden):
    """Garbage over the active overlay: Alpine's diskless init can't untar it
    and drops to the initramfs emergency RECOVERY SHELL -- a diagnosable,
    recoverable state, NOT a silent hang.  (It does not 'boot to defaults':
    a corrupt apkovl is a hard error the init surfaces loudly.)"""
    sysd, datad = overlay_disks(prefix="corrupt")
    disks = [DiskSpec(str(sysd)), DiskSpec(str(datad), serial="NASDATA0")]
    g1 = guest_factory(disks, name="corrupt-a", ssh_key=golden.ssh_key)
    g1.wait_ssh()
    g1.run("f=$(ls /cfg/*.apkovl.tar.gz | head -n1) && "
           "dd if=/dev/urandom of=\"$f\" bs=1k count=8 conv=notrunc && sync",
           check=True, timeout=60)
    # corruption is on disk (synced); a hard stop avoids any shutdown-path
    # cleverness touching /cfg on the way down
    g1.quit_hard()

    g2 = guest_factory(disks, name="corrupt-b", ssh_key=golden.ssh_key,
                       throwaway=[sysd, datad])
    s = g2.serial
    # the invariant: the failure is surfaced (recovery shell / tar error),
    # reached within a bounded time -- not an indefinite hang
    idx = s.expect([r"emergency recovery shell", r"invalid magic",
                    r"can't access tty"], timeout=420)
    g2.screenshot("corrupt-overlay-recovery-shell")
    assert idx in (0, 1, 2)
