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

from lib.guest import assert_container_stable, import_busybox_image, push_nas_tree
from lib.smtpsink import configure_guest_msmtp

FILES_DIR = Path(__file__).resolve().parent.parent.parent / "mountnas-tools" / "files"

# the nas CLI tree (nas + lib.sh + cmd/*.sh) is pushed by push_nas_tree
_DEV_FILES = [
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
    ("profile-nas-aliases.sh", "/etc/profile.d/nas-aliases.sh", "644"),
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
    push_nas_tree(g, FILES_DIR)
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


# ---------------------------------------------------------------- notify

def test_notify_fans_out_to_webhook_and_email(dev_guest, smtp_sink, http_server):
    """One --test message must reach EVERY configured sink: a generic JSON
    webhook (host-side catcher) and an email (host-side SMTP sink)."""
    g = dev_guest
    configure_guest_msmtp(g, smtp_sink.port)
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


def test_rc_update_guard_redirects_data_services(dev_guest):
    """'rc-update del docker' cannot work — the data services sit in no
    runlevel — and OpenRC's bare "not in the runlevel" answer points nowhere.
    An interactive-shell function in /etc/profile.d/nas-aliases.sh intercepts
    add/del for the supervisor-managed set and prints the conf.d recipe
    instead. It must NOT touch anything else, and 'command rc-update' must
    still bypass it."""
    g = dev_guest

    # The snippet gates on `case $- in *i*)`, so the guard exists ONLY in an
    # interactive shell — which is the point (scripts and automation must be
    # untouched). Neither `ash -c` nor `set -i` produces that flag; running a
    # SCRIPT FILE under `ash -i` does. Hence the write-then-run dance.
    def run(cmd):
        g.run("printf '%s\\n' '. /etc/profile.d/nas-aliases.sh' "
              f"'{cmd}' > /tmp/guard.sh", check=True)
        return g.run("busybox ash -i /tmp/guard.sh", timeout=60)

    for cmd in ("rc-update del docker", "rc-update docker del",
                "rc-update add nfs default", "rc-update del samba"):
        r = run(cmd)
        assert r.rc == 1, f"{cmd!r} was not intercepted (rc={r.rc})"
        assert "managed by the mountnas supervisor" in r.out, r.out
        assert "/etc/conf.d/mountnas" in r.out, r.out

    # pass-through: unrelated subcommands and unrelated services are untouched
    assert "default" in run("rc-update show").out, \
        "rc-update show was swallowed by the guard"
    r = run("rc-update add chronyd default")
    assert r.rc == 0 and "managed by the mountnas supervisor" not in r.out, \
        f"guard fired on an ordinary runlevel service:\n{r.out}"

    # the escape hatch reaches the real binary (OpenRC's own error, not ours)
    r = run("command rc-update del docker")
    assert "managed by the mountnas supervisor" not in r.out, \
        "'command rc-update' did not bypass the guard function"


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
    # no anchor may TARGET the terminal. The old blanket checks (':22222/'
    # / 'termlink' substrings) now false-positive by design: the header
    # carries a User-guide termlink always, the off-pill links to the
    # guide's #ttyd section, and the page embeds a syslog tail where a
    # logged URL is legitimate content.
    assert not re.search(r'href="[^"]*:22222/"', idx2), \
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

# ------------------------------------------------- user-service boot heal

@pytest.mark.network
def test_user_service_starts_after_world_sync_heal(dev_guest):
    """A user-installed service ('apk add X && rc-update add X && nas commit')
    installs its init script MID-boot -- the supervisor's world re-sync runs
    after /cfg mounts, but openrc walked the runlevels earlier and skipped
    the then-dangling symlink.  The supervisor heal records the dangling
    links before the sync and starts exactly the ones the sync resolves.

    Validated via `nas restart` (runs the in-RAM repo supervisor), with the
    boot race manufactured for real: package absent + world entry present +
    runlevel symlink dangling is byte-for-byte the state a diskless boot
    hands the supervisor.  The boot-path half lands automatically once this
    supervisor is baked into an image (same caveat as the rpcbind test)."""
    g = dev_guest
    r = g.run("apk add rsync-openrc", timeout=300)   # tiny; caches to /cfg
    if r.rc != 0:
        pytest.skip(f"apk add rsync-openrc failed (offline?): {r.out[-300:]}")
    g.run("rc-update add rsyncd default", check=True)
    # a minimal daemon config so the started service stays up (the rsync
    # package's sample may not ship on every branch); /etc survives apk del
    g.run("printf 'pid file = /run/rsyncd.pid\\n' > /etc/rsyncd.conf",
          check=True)
    # manufacture the boot state: world wants it, filesystem lacks it.
    # BOTH packages must go: rsync-openrc is an install_if subpackage, so
    # deleting it alone while rsync stays installed re-selects it in the
    # SAME transaction and the init script never leaves (the rc9 validation
    # caught exactly that). World gets both names back by hand.
    g.run("apk del rsync-openrc rsync", check=True)
    g.run("test ! -e /etc/init.d/rsyncd", check=True)   # dangling confirmed
    g.run("printf 'rsync\\nrsync-openrc\\n' >> /etc/apk/world"
          " && sort -u -o /etc/apk/world /etc/apk/world", check=True)
    # the surgical control: an enabled service that is merely STOPPED (its
    # link resolves) must NOT be touched by the heal
    g.run("rc-service crond stop", check=True)

    g.run("rc-service mountnas restart", timeout=240, check=True)

    g.poll_until("test -e /etc/init.d/rsyncd", timeout=120,
                 desc="world sync reinstalled the package")
    g.poll_until("rc-service rsyncd status | grep -q started", timeout=120,
                 desc="heal started the skipped service")
    r = g.run("grep 'starting rsyncd' /var/log/mountnas.log", check=True)
    assert "after the runlevel walk" in r.out
    # the control did NOT get started
    r = g.run("rc-service crond status")
    assert r.rc != 0, f"heal must not start merely-stopped services:\n{r.out}"
    g.run("rc-service crond start && rc-update del rsyncd default"
          " && rc-service rsyncd stop", check=True)


# ------------------------------------------------------------- nas share

def test_share_end_to_end_with_real_samba(dev_guest):
    """'nas share' against the REAL samba stack: user add (SMB-only), share
    add via piped answers, an actual smbclient write, per-user read-only,
    the testparm gate, and the include landing where samba honors it.
    The rc9 image predates the feature, so _share_ensure_include exercises
    the UPGRADED-box path -- the include must land inside [global] even
    though this smb.conf ends with a hand-written share section."""
    g = dev_guest
    g.poll_until("rc-service samba status", timeout=300, desc="samba up")
    # an upgraded-box shape: a hand-written share at EOF
    g.run("printf '\n[handrolled]\n   path = /mnt/nasdata\n   read only = yes\n"
          "   guest ok = yes\n' >> /etc/samba/smb.conf && rc-service samba reload",
          check=True)
    g.run("printf 'pw1\npw1\n' | nas share user add alice", timeout=120,
          check=True)
    # let 'share add' CREATE the directory (answer y) — the chown to the
    # force-user account only runs on directories the command creates, so
    # a pre-made root-owned dir would give smbd ACCESS_DENIED by design
    r = g.run("printf 'y\n1\nalice\n1\n' | nas share add teamdocs /mnt/nasdata/teamdocs",
              timeout=120)
    assert r.rc == 0, f"share add rc={r.rc}:\n{r.out}"
    # the include must be in [global] scope or smbd ignores it silently
    r = g.run("awk '/^\[/{s=$0} /include = .*mountnas-shares/{print s; exit}'"
              " /etc/samba/smb.conf", check=True)
    assert "[handrolled]" not in r.out, \
        f"include landed inside a share section — samba ignores it there: {r.out}"
    r = g.run("testparm -s 2>/dev/null | grep -A3 '^\[teamdocs\]'", check=True)
    assert "teamdocs" in r.out, "managed share invisible to samba"
    # a REAL write through smbd as alice
    g.run("echo probe > /tmp/upload.txt", check=True)
    r = g.run("smbclient //127.0.0.1/teamdocs -U alice%pw1"
              " -c 'put /tmp/upload.txt upload.txt'", timeout=120)
    assert r.rc == 0, f"authenticated write failed:\n{r.out}"
    g.run("test -s /mnt/nasdata/teamdocs/upload.txt", check=True)
    # a second user, granted read-only: the write must FAIL, the read succeed
    g.run("printf 'pw2\npw2\n' | nas share user add bob", timeout=120,
          check=True)
    g.run("nas share allow teamdocs bob --ro", timeout=60, check=True)
    r = g.run("smbclient //127.0.0.1/teamdocs -U bob%pw2"
              " -c 'put /tmp/upload.txt blocked.txt'", timeout=120)
    assert r.rc != 0, "read-only grant accepted a write"
    r = g.run("smbclient //127.0.0.1/teamdocs -U bob%pw2 -c 'get upload.txt /tmp/dl.txt'",
              timeout=120)
    assert r.rc == 0, f"read-only user could not read:\n{r.out}"
    # list shows both worlds; hand-written stays untouched by remove
    r = g.run("NO_COLOR=1 nas share list", check=True)
    assert "teamdocs" in r.out and "handrolled" in r.out, r.out
    g.run("printf 'n\n' | nas share remove teamdocs", timeout=60, check=True)
    g.run("grep -q '^\[handrolled\]' /etc/samba/smb.conf", check=True)
    r = g.run("testparm -s 2>/dev/null | grep '^\[teamdocs\]'")
    assert r.rc != 0, "share still served after remove"
