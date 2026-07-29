"""Category K -- the [Unreleased] features: notification sinks (nas notify),
the append-only operations log (nas history), and the read-only web
dashboard + guide (nas web).

These features exist in the repo but not in any PUBLISHED image, so every
test runs on `dev_guest`: a golden guest with the repo's current
mountnas-tools files pushed over the released ones (same install paths the
apk uses). The web test additionally installs busybox-extras (httpd) from
the CDN, hence its network marker.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from lib.guest import assert_container_stable, import_busybox_image
from lib.smtpsink import configure_guest_msmtp

FILES_DIR = Path(__file__).resolve().parent.parent.parent / "mountnas-tools" / "files"

_DEV_FILES = [
    ("nas",           "/usr/sbin/nas",                        "755"),
    ("mountnas",      "/etc/init.d/mountnas",                 "755"),
    ("data-watch",    "/usr/libexec/mountnas/data-watch",     "755"),
    ("notify",        "/usr/libexec/mountnas/notify",         "755"),
    ("smartd-notify", "/usr/libexec/mountnas/smartd-notify",  "755"),
    ("health-digest", "/usr/libexec/mountnas/health-digest",  "755"),
    ("gen-webstatus", "/usr/libexec/mountnas/gen-webstatus",  "755"),
    ("web-refresh",   "/usr/libexec/mountnas/web-refresh",    "755"),
    ("mountnas-web",  "/etc/init.d/mountnas-web",             "755"),
    ("mountnas-ttyd", "/etc/init.d/mountnas-ttyd",            "755"),
    ("web-guide.html", "/usr/share/mountnas/web/guide.html",  "644"),
    ("web-logo.png",  "/usr/share/mountnas/web/logo.png",     "644"),
]


@pytest.fixture
def dev_guest(golden_guest):
    """Golden guest running the REPO's current tools instead of the released
    ones -- how unreleased features get exercised end-to-end.

    DISKLESS CAVEAT: the push patches the RUNNING RAM root only. A reboot
    rebuilds the root from the released apk, so the dev tools vanish --
    post-reboot assertions must not invoke new commands (check raw files
    instead, or re-push)."""
    g = golden_guest
    g.run("mkdir -p /usr/share/mountnas/web /usr/libexec/mountnas", check=True)
    for src, dst, mode in _DEV_FILES:
        p = FILES_DIR / src
        if not p.is_file():
            raise FileNotFoundError(f"repo file missing: {p}")
        g.push(p, f"{dst}.new")
        g.run(f"mv {dst}.new {dst} && chmod {mode} {dst}", check=True)
    return g


def _set_sinks(guest, *sinks: str) -> None:
    # sinks go in as printf ARGUMENTS, never in the format string — a future
    # sink URL containing % (URL-encoded tokens) must not be format-parsed
    args = " ".join(f"'{s}'" for s in sinks)
    guest.run(f"printf '%s\\n' {args} > /etc/mountnas/notify.conf", check=True)
    # keep the legacy file quiet unless a test wants it explicitly
    guest.run("printf '# none\\n' > /etc/mountnas/alert-email", check=True)


# ---------------------------------------------------------------- notify

def test_notify_fans_out_to_webhook_and_email(dev_guest, smtp_sink, http_server):
    """One --test message must reach EVERY configured sink: a generic JSON
    webhook (host-side catcher) and an email (host-side SMTP sink)."""
    g = dev_guest
    configure_guest_msmtp(g, smtp_sink.port)   # msmtprc; also sets alert-email
    _set_sinks(g, f"webhook:http://10.0.2.2:{http_server.port}/hook",
               "email:probe@test.local")
    r = g.run("nas notify --test", timeout=90)
    assert r.rc == 0, f"nas notify --test rc={r.rc}:\n{r.out}"
    mails = smtp_sink.wait_for_mail(1, timeout=g.cfg.scaled(60))
    assert "test notification" in mails[0].subject
    posts = http_server.wait_for_post(1, timeout=g.cfg.scaled(60))
    payload = json.loads(posts[0].body)
    assert "test notification" in payload["title"]
    assert payload["host"], payload


def test_notify_lists_sinks_and_takes_piped_body(dev_guest, smtp_sink):
    g = dev_guest
    configure_guest_msmtp(g, smtp_sink.port)
    _set_sinks(g, "email:probe@test.local")
    lst = g.run("nas notify", check=True)
    assert "email:probe@test.local" in lst.out, lst.out
    g.run("echo K-BODY-MARKER | nas notify 'k pipe subject'", timeout=90,
          check=True)
    mails = smtp_sink.wait_for_mail(1, timeout=g.cfg.scaled(60))
    assert "k pipe subject" in mails[0].subject
    assert "K-BODY-MARKER" in mails[0].body


def test_data_watch_alerts_through_sinks(dev_guest, http_server):
    """The disk-loss watcher now delivers via the sink fan-out: a webhook-only
    config (no msmtp at all) must still get the DISCONNECTED alert."""
    g = dev_guest
    _set_sinks(g, f"webhook:http://10.0.2.2:{http_server.port}/alert")
    assert g.data_state() == "ok"
    g.detach_disk("dev1")
    g.run("/usr/libexec/mountnas/data-watch", timeout=120)
    assert g.data_state() == "disconnected"
    posts = http_server.wait_for_post(1, timeout=g.cfg.scaled(90))
    payload = json.loads(posts[0].body)
    assert "DISCONNECTED" in payload["title"] + payload["message"]


# ---------------------------------------------------------------- disable

def test_disable_data_service_via_conf(dev_guest):
    """Docker/Samba/NFS live in no runlevel, so the supported permanent
    disable is DATA_SERVICES= in /etc/conf.d/mountnas (the documented steps
    are exactly what this test runs). The supervisor must not start a
    disabled service, and nas status must report it as disabled — never as
    a 'not running' warning."""
    g = dev_guest
    g.poll_until("rc-service docker status", timeout=300, desc="docker up")
    g.run("rc-service docker stop", timeout=120)
    # /etc/conf.d/mountnas SHIPS seeded from 1.0rc7 (discoverability: it is the
    # switch users hunt for, and /etc/conf.d/ showed ufw + zram-init but no
    # trace of this one), with the setting commented out so the supervisor's
    # built-in default stays authoritative and a future data service still
    # reaches boxes whose owner never edited the file. Seed changes only land
    # in a BUILT image, never via a dev push, so this is conditional until
    # rc7 is the image under test — then it hard-asserts (same pattern as the
    # avahi-tools check in category C).
    if g.run("test -f /etc/conf.d/mountnas").rc == 0:
        assert g.run("grep -q '^#DATA_SERVICES=' /etc/conf.d/mountnas").rc == 0, \
            "seeded conf.d lost its commented DATA_SERVICES example"
        assert g.run("grep -q '^DATA_SERVICES=' /etc/conf.d/mountnas").rc != 0, \
            "seeded conf.d sets DATA_SERVICES live — it must ship commented out"
        # the documented recipe: uncomment the example to keep only samba+nfs
        g.run("sed -i 's/^#DATA_SERVICES=/DATA_SERVICES=/' /etc/conf.d/mountnas",
              check=True)
        assert "samba nfs" in g.run(
            "sed -n 's/^DATA_SERVICES=//p' /etc/conf.d/mountnas", check=True).out, \
            "the documented sed did not activate the seeded example line"
    else:
        g.run("printf 'DATA_SERVICES=\"samba nfs\"\\n' > /etc/conf.d/mountnas",
              check=True)
    g.run("rc-service mountnas restart", timeout=240, check=True)
    g.poll_until("rc-service samba status", timeout=180,
                 desc="kept service (samba) back up")
    assert g.run("rc-service docker status").rc != 0, \
        "supervisor started a service disabled via DATA_SERVICES"
    st = g.run("nas status", timeout=180)
    assert st.rc == 0, \
        f"a deliberate disable must not fail status (rc={st.rc}):\n{st.out}"
    assert "docker not running" not in st.out, st.out
    assert "disabled by /etc/conf.d/mountnas" in st.out and "docker" in st.out, st.out
    # the dashboard must agree: a deliberate off is "disabled via ...", never
    # the misleading "held until the data disk is up"
    g.run("/usr/libexec/mountnas/gen-webstatus", timeout=180, check=True)
    idx = g.run("cat /run/mountnas/web/index.html", check=True).out
    assert "disabled via /etc/conf.d/mountnas" in idx, \
        "dashboard docker card shows the wrong reason for a deliberate disable"

    # An EXPLICITLY EMPTY list means none at all. Until 1.0rc7 the expansion
    # was ${DATA_SERVICES:-...}, which treats set-but-empty as absent — so the
    # one value that reads as "run nothing" was the one value that ran
    # everything. Guard the fix in both directions below.
    # Stop them FIRST: the supervisor only manages what is currently listed,
    # so once the list is empty its stop() is a no-op by design and anything
    # already running would stay up (documented behaviour, not a regression).
    # The property under test is that it never STARTS them.
    for svc in ("docker", "samba", "nfs"):
        g.run(f"rc-service {svc} stop", timeout=120)
    g.run("printf 'DATA_SERVICES=\"\"\\n' > /etc/conf.d/mountnas", check=True)
    g.run("rc-service mountnas restart", timeout=240, check=True)
    for svc in ("docker", "samba", "nfs"):
        assert g.run(f"rc-service {svc} status").rc != 0, \
            f"{svc} started despite an empty DATA_SERVICES (the :- footgun is back)"
    st = g.run("nas status", timeout=180)
    assert st.rc == 0, f"disable-all must not fail status (rc={st.rc}):\n{st.out}"
    assert "disabled by /etc/conf.d/mountnas" in st.out, st.out
    for svc in ("docker not running", "samba not running", "nfs not running"):
        assert svc not in st.out, f"deliberate disable warned as a failure: {svc}"

    # ...but a conf.d that BREAKS under sourcing must fail SAFE to the built-in
    # set, not read as "the user disabled everything" — emptiness alone cannot
    # be the error signal once an empty list is meaningful.
    g.run("printf 'exit 3\\n' > /etc/conf.d/mountnas", check=True)
    st = g.run("nas status", timeout=180)
    assert "disabled by /etc/conf.d/mountnas" not in st.out, \
        "a broken conf.d was read as a deliberate disable-all (sentinel lost)"


# ---------------------------------------------------------------- ttyd

@pytest.mark.network
def test_ttyd_browser_terminal(dev_guest):
    """nas ttyd on -> a login-prompt terminal served over HTTP on 22222,
    linked from the dashboard render; nas ttyd off -> gone. ttyd itself is
    installed from the CDN (not in the beta-5 image), hence the marker."""
    g = dev_guest
    r = g.run("apk add ttyd", timeout=300)
    if r.rc != 0:
        pytest.skip(f"apk add ttyd failed (offline?): {r.out[-300:]}")

    on = g.run("nas ttyd on", timeout=180)
    assert on.rc == 0, f"nas ttyd on rc={on.rc}:\n{on.out}"
    assert "22222" in on.out
    # the enable must say the quiet part out loud: cleartext on the wire
    assert "cleartext" in on.out, on.out
    assert "NOT saved" in on.out, "missing commit-honesty warning"
    # root login: 'on' whitelists ptys in securetty exactly once (idempotent)
    assert "securetty" in on.out, on.out
    g.run("grep -qx pts/0 /etc/securetty && grep -qx pts/15 /etc/securetty",
          check=True)
    n_before = g.run("grep -c '^pts/' /etc/securetty", check=True).out.strip()
    g.run("nas ttyd on", timeout=180, check=True)   # second run must not re-append
    n_after = g.run("grep -c '^pts/' /etc/securetty", check=True).out.strip()
    assert n_before == n_after == "16", f"{n_before} -> {n_after}"

    g.poll_until("curl -fsS http://127.0.0.1:22222/ | grep -qi ttyd",
                 timeout=90, desc="ttyd serving")

    st = g.run("nas ttyd status", check=True)
    assert "running" in st.out and "NOT saved" in st.out, st.out

    # the dashboard render links to the running terminal (no httpd needed --
    # inspect the rendered file directly): clickable header pill + footer link
    g.run("/usr/libexec/mountnas/gen-webstatus", timeout=180, check=True)
    idx = g.run("cat /run/mountnas/web/index.html", check=True).out
    # a WELL-FORMED link: bare IP, no CIDR suffix (ips[] carries /24, which
    # once leaked into the href as http://10.0.2.15/24:22222/ — a dead link
    # the old ':22222/ in idx' substring check could never catch)
    assert re.search(r'href="http://\d+\.\d+\.\d+\.\d+:22222/"', idx), \
        "dashboard terminal link missing or malformed while ttyd is running"
    assert 'class="termlink"' in idx, "header terminal pill missing while ttyd runs"

    assert "ttyd" in g.run("nas history", check=True).out

    off = g.run("nas ttyd off", timeout=120)
    assert off.rc == 0
    gone = g.run("curl -fsS --max-time 5 http://127.0.0.1:22222/ >/dev/null 2>&1")
    assert gone.rc != 0, "ttyd still serving after nas ttyd off"
    # next render: the header indicates the terminal is OFF, and nothing on
    # the page links to it anymore (the state pill stays by design)
    g.run("/usr/libexec/mountnas/gen-webstatus", timeout=180, check=True)
    idx2 = g.run("cat /run/mountnas/web/index.html", check=True).out
    assert "Web terminal off" in idx2, "header off-indicator missing"
    # no anchor anywhere ('termlink' alone would false-positive: the CSS
    # class definition ships in every render)
    assert ":22222/" not in idx2 and 'class="termlink"' not in idx2, \
        "terminal still linked after nas ttyd off"


# ---------------------------------------------------------------- nfs boot

def test_supervisor_settles_rpcbind_before_nfs(dev_guest):
    """The nfs/rpcbind race: nfs needs rpcbind FULLY started, but at boot the
    supervisor could outrun rpcbind's own runlevel start ("cannot start nfs
    as rpcbind would not start") and nfs stayed down until a manual restart
    (the beta-6 validation dashboard caught it — nfs a grey pill on a healthy
    box). The fixed supervisor settles rpcbind before starting nfs.

    Tested via `nas restart` (runs the in-RAM fixed supervisor) from a
    fully-stopped rpcbind+nfs — the exact prerequisite gap. NB: the boot-time
    ORDERING half of the fix (`after rpcbind` in depend()) can only be
    validated once baked into an image, since a diskless reboot rebuilds the
    RAM root from the released apk; that half is checked by the beta-7
    release-validation run."""
    g = dev_guest
    g.run("grep -q 'after net rpcbind' /etc/init.d/mountnas", check=True)
    g.wait_ready()
    # premise: nfs must be a managed data service or this test exercises
    # nothing. Read the conf.d DATA_SERVICES line DIRECTLY — never source it
    # (a missing conf.d aborts busybox ash even behind `|| :`). No line / no
    # file => the default set (docker samba nfs) applies.
    ds_line = g.run("sed -n 's/^DATA_SERVICES=//p' /etc/conf.d/mountnas "
                    "2>/dev/null | tr -d '\"' | tail -n1", check=False).out.strip()
    assert (not ds_line) or ("nfs" in ds_line.split()), \
        f"conf.d DATA_SERVICES excludes nfs ({ds_line!r}) — premise void"
    # recreate the prerequisite gap: both down, then let the supervisor bring
    # the data plane back — it must settle rpcbind first and get nfs up
    g.run("rc-service nfs stop; rc-service rpcbind stop", timeout=120)
    g.poll_until("! rc-service nfs status >/dev/null 2>&1", timeout=60,
                 desc="nfs stopped")
    g.run("nas restart", timeout=240, check=True)
    assert g.poll_until("rc-service rpcbind status", timeout=60,
                        desc="rpcbind settled by supervisor").rc == 0
    assert g.poll_until("rc-service nfs status", timeout=120,
                        desc="nfs up via supervisor").rc == 0, \
        "supervisor did not bring nfs up after settling rpcbind"


# ---------------------------------------------------------------- ops log

def test_ops_log_history_and_no_commit_persistence(dev_guest):
    """Operations land in nas history with actor+timestamp, live on /cfg,
    and survive a reboot WITHOUT any commit."""
    g = dev_guest
    g.run("nas commit -m 'k-ops-probe'", timeout=120, check=True)
    h = g.run("nas history", check=True)
    assert "commit" in h.out and "k-ops-probe" in h.out, h.out
    raw = g.run("cat /cfg/mountnas-ops.log", check=True).out
    last = raw.strip().splitlines()[-1]
    fields = last.split("\t")
    assert len(fields) == 4, f"malformed record: {last!r}"
    assert fields[0].endswith("Z") and "@" in fields[2], last
    # the log is on the ext4 config partition -- a reboot with NO further
    # commit must keep it (the whole point of not living in the overlay).
    # NB: the reboot restores the RELEASED nas (diskless RAM root), so assert
    # on the raw file, not the new CLI command.
    g.reboot()
    h2 = g.run("cat /cfg/mountnas-ops.log", check=True)
    assert "k-ops-probe" in h2.out, "ops log lost across reboot"


# ---------------------------------------------------------------- web

@pytest.mark.network
def test_web_dashboard_guide_and_json(dev_guest, artifacts):
    """nas web on -> dashboard, guide and status.json served read-only;
    nas web off -> gone. busybox-extras (httpd) comes from the CDN, so
    this carries the network marker."""
    g = dev_guest
    r = g.run("apk add busybox-extras", timeout=300)
    if r.rc != 0:
        pytest.skip(f"apk add busybox-extras failed (offline?): {r.out[-300:]}")

    # a real container so the docker table has a row to render (registry-free:
    # the shared helper ships the musl loader in the rootfs -- without it the
    # container crash-loops with 'exec: no such file or directory', which is
    # exactly what the first version of this test rendered as a red
    # "Exited (255)" row while a weak assertion let it slide)
    g.poll_until("docker info >/dev/null 2>&1", timeout=300, desc="docker api up")
    import_busybox_image(g)
    g.run("docker run -d --name dashprobe --restart unless-stopped "
          "mnq-busybox /bin/busybox sleep 2147483", timeout=120, check=True)
    assert_container_stable(g, "dashprobe")

    on = g.run("nas web on", timeout=180)
    assert on.rc == 0, f"nas web on rc={on.rc}:\n{on.out}"
    assert "8080" in on.out

    g.poll_until("curl -fsS http://127.0.0.1:8080/ | grep -q MountNAS",
                 timeout=90, desc="dashboard serving")
    page = g.run("curl -fsS http://127.0.0.1:8080/", check=True).out
    host = g.run("hostname", check=True).out.strip()
    assert host in page and "Services" in page and "Disk" in page, page[:500]
    # the system detail lives at the bottom of the ONE page: hardware,
    # added packages, a collapsed syslog tail, and the hardware inventory
    # (lsusb -tv / lspci / DIMMs)
    for marker in ("Syslog", "Your added packages", "Machine", "<details",
                   "Hardware inventory", "lsusb -tv", "lspci"):
        assert marker in page, f"{marker!r} missing from dashboard"
    # the docker containers table: our probe container with its state pill,
    # image and created columns. The pill class is extracted from the probe's
    # OWN row -- "running" appears in the summary counts too, so a bare
    # substring check cannot catch a crashed probe.
    for marker in ("dashprobe", "mnq-busybox", "Container"):
        assert marker in page, f"docker table marker {marker!r} missing"
    m = re.search(r"dashprobe.*?pill (p-\w+)", page, re.S)
    assert m and m.group(1) == "p-ok", \
        f"probe container not rendered as running: {m.group(1) if m else 'row missing'}"

    sj = g.run("curl -fsS http://127.0.0.1:8080/status.json", check=True)
    data = json.loads(sj.out)
    assert data.get("hostname") == host

    guide = g.run("curl -fsS http://127.0.0.1:8080/guide.html", check=True).out
    assert "MountNAS User Guide" in guide and "nas commit" in guide

    logo = g.run("curl -fsS -o /dev/null -w '%{http_code}' "
                 "http://127.0.0.1:8080/logo.png", check=True)
    assert logo.out.strip() == "200"

    # persistence honesty: enabled but uncommitted must WARN, and the
    # warning must clear once the setting is committed
    st = g.run("nas web status", check=True)
    assert "running" in st.out
    assert "NOT saved" in st.out, f"missing unsaved warning:\n{st.out}"
    g.run("nas commit -m 'web on'", timeout=120, check=True)
    st2 = g.run("nas web status", check=True)
    assert "NOT saved" not in st2.out, f"warning survived a commit:\n{st2.out}"

    # the enable/disable pair is itself an operation worth auditing
    hist = g.run("nas history", check=True)
    assert "web" in hist.out

    # keep the rendered page as a report artifact for visual review
    (artifacts.out_dir / "dashboard.html").write_text(page, encoding="utf-8")
    artifacts.attach_file("rendered dashboard", artifacts.out_dir / "dashboard.html")

    off = g.run("nas web off", timeout=120)
    assert off.rc == 0
    gone = g.run("curl -fsS --max-time 5 http://127.0.0.1:8080/ >/dev/null 2>&1")
    assert gone.rc != 0, "dashboard still serving after nas web off"