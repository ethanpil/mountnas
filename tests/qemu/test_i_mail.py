"""Category I -- the mail pipeline (msmtp + mailx + smartd + alerts).

A host-side SMTP sink (lib/smtpsink.py) plays the relay; guests reach it at
10.0.2.2 through slirp.  The shipped glue under test: /etc/mail.rc points
mail(1) at msmtp (both sendmail= and mta=), /etc/msmtprc is the 0600
credential file, data-watch honours /etc/mountnas/alert-email.
"""

from __future__ import annotations

import pytest

from lib.guest import DiskSpec
from lib.smtpsink import configure_guest_msmtp


def test_msmtprc_shipped_permissions_0600(golden_guest):
    """msmtprc holds a relay password -- it must ship 0600 root:root."""
    r = golden_guest.run("stat -c '%a %u:%g' /etc/msmtprc", check=True)
    mode, owner = r.out.split()
    assert mode == "600", f"msmtprc mode {mode}, expected 600"
    assert owner == "0:0", f"msmtprc owner {owner}, expected 0:0"


@pytest.mark.smoke
def test_mail_pipeline_delivers_to_sink(golden_guest, smtp_sink):
    """`mail -s` end-to-end: mailx -> msmtp -> (slirp) -> host sink."""
    g = golden_guest
    configure_guest_msmtp(g, smtp_sink.port)
    r = g.run("echo 'qemu suite mail body' | "
              "mail -s 'qemu-suite-test-mail' probe@test.local", timeout=60)
    assert r.rc == 0, f"mail(1) failed rc={r.rc}: {r.out}"
    mails = smtp_sink.wait_for_mail(1, timeout=g.cfg.scaled(90))
    assert mails[0].subject == "qemu-suite-test-mail", mails[0].subject
    assert "qemu suite mail body" in mails[0].body


def test_smartd_test_mail_arrives(guest_factory, overlay_disks, golden,
                                  smtp_sink, tmp_path):
    """smartd's -M test mail must traverse the same pipeline.  virtio disks
    have no SMART, so the monitored device is an emulated NVMe drive (the
    one QEMU bus that exposes a health log)."""
    from lib import images
    sysd, datad = overlay_disks(prefix="smart")
    nvme = images.create_blank_qcow2(tmp_path / "smart-nvme.qcow2", "2G")
    g = guest_factory(
        [DiskSpec(str(sysd)), DiskSpec(str(datad), serial="NASDATA0"),
         DiskSpec(str(nvme), bus="nvme", serial="SMARTNVME")],
        name="smart", ssh_key=golden.ssh_key,
        throwaway=[sysd, datad, nvme],
    )
    g.wait_ssh()
    configure_guest_msmtp(g, smtp_sink.port)
    probe = g.run("smartctl -i /dev/nvme0 2>&1 || true", timeout=60)
    if "Unable to detect" in probe.out or probe.rc == 127:
        pytest.skip(f"no SMART-capable device in this QEMU: {probe.out[-300:]}")
    g.run("printf '%s\\n' '/dev/nvme0 -d nvme -m root@test.local -M test'"
          " > /etc/smartd.conf", check=True)
    r = g.run("smartd -q onecheck", timeout=180)
    assert r.rc == 0, f"smartd onecheck rc={r.rc}:\n{r.out[-2000:]}"
    mails = smtp_sink.wait_for_mail(1, timeout=g.cfg.scaled(120))
    joined = (mails[0].subject + mails[0].body).upper()
    assert "TEST" in joined and "SMART" in joined, mails[0].subject


def test_alert_email_comment_stripping(golden_guest, smtp_sink):
    """data-watch reads the FIRST non-comment line of alert-email -- comments
    and blanks must not break alerting."""
    from lib import config as C
    g = golden_guest
    configure_guest_msmtp(g, smtp_sink.port)
    g.run(f"printf '%s\\n' '# my alert address' '' 'ops@test.local' "
          f"> {C.ALERT_EMAIL}", check=True)
    g.run(f"mount -o remount,ro {C.DATA_MOUNT}", check=True)
    g.run("/usr/libexec/mountnas/data-watch", timeout=120)
    mails = smtp_sink.wait_for_mail(1, timeout=g.cfg.scaled(90))
    assert any("ops@test.local" in r for r in mails[0].rcpt_tos), \
        f"alert went to {mails[0].rcpt_tos}"
