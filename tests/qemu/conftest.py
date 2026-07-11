"""Fixtures + report hooks for the MountNAS QEMU test suite.

Layers (see tests/qemu/README.md):
  session:  suite_config, image_bundle, prev_image_bundle, golden, payload_disk
  module:   shared_cli_guest (read-only category-C tests share one guest)
  function: artifacts (autouse), guest_factory, golden_guest, pristine_guest,
            smtp_sink, http_server

The report hooks embed every screenshot (base64 PNG) and command transcript
into the pytest-html report, attach failure forensics, and write
summary.json next to the HTML at session end.
"""

from __future__ import annotations

import base64
import datetime
import json
import logging
import os
import urllib.request
from pathlib import Path

import pytest

from lib import config as C
from lib import golden as golden_mod
from lib import images
from lib.artifacts import Collector, test_id_slug
from lib.guest import DiskSpec, Guest
from lib.httpserv import DirServer
from lib.smtpsink import SMTPSink

log = logging.getLogger("mountnas.conftest")

try:
    from pytest_html import extras as html_extras
except ImportError:  # collection-only sanity runs without pytest-html
    html_extras = None


# ---------------------------------------------------------------------------
# CLI options
# ---------------------------------------------------------------------------

def pytest_addoption(parser):
    g = parser.getgroup("mountnas")
    g.addoption("--image", default="", help="local mountnas-<tag>.img.gz "
                "(default: download the latest GitHub release)")
    g.addoption("--previous", default="", help="local previous-release "
                ".img.gz for upgrade tests (default: download)")
    g.addoption("--run-dir", default="", help="output directory for report "
                "and artifacts")
    g.addoption("--keep-guests", action="store_true",
                help="keep overlay disks + socket dirs after each test")
    g.addoption("--gif-every-boot", action="store_true",
                help="capture a boot GIF for every guest (debug; slow)")


# ---------------------------------------------------------------------------
# Session fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def suite_config(request) -> C.SuiteConfig:
    run_dir = request.config.getoption("--run-dir") or os.path.expanduser(
        "~/mountnas-qemu-test-suite-result-"
        + datetime.date.today().isoformat()
    )
    cfg = C.SuiteConfig(
        run_dir=Path(run_dir),
        image_arg=request.config.getoption("--image") or None,
        previous_arg=request.config.getoption("--previous") or None,
        keep_guests=request.config.getoption("--keep-guests"),
        gif_every_boot=request.config.getoption("--gif-every-boot"),
    )
    log.info("suite config: kvm=%s time_scale=%.1f run_dir=%s cache=%s",
             cfg.kvm, cfg.time_scale, cfg.run_dir, cfg.cache_dir)
    return cfg


@pytest.fixture(scope="session")
def image_bundle(suite_config) -> images.ImageBundle:
    if suite_config.image_arg:
        b = images.local_image(suite_config.image_arg)
    else:
        b = images.fetch_release_image(suite_config, "latest")
    log.info("image under test: %s (tag=%s sha=%s)", b.img_gz, b.tag,
             b.sha256[:16])
    return b


@pytest.fixture(scope="session")
def prev_image_bundle(suite_config, image_bundle):
    """Previous release for upgrade tests, or None (tests then skip or
    fall back to self-upgrade)."""
    if suite_config.previous_arg:
        return images.local_image(suite_config.previous_arg)
    b = images.fetch_release_image(suite_config, "previous")
    if b and b.sha256 == image_bundle.sha256:
        log.warning("previous release == image under test; treating as None")
        return None
    return b


@pytest.fixture(scope="session")
def golden(suite_config, image_bundle) -> golden_mod.GoldenArtifacts:
    return golden_mod.load_or_build(suite_config, image_bundle)


@pytest.fixture(scope="session")
def payload_dir(suite_config, image_bundle) -> Path:
    """Raw ext4 payload disk carrying new.img.gz (session-built; tests boot
    qcow2 overlays of it so guest writes never touch the original)."""
    dest = suite_config.cache_dir / f"payload-{image_bundle.sha256[:16]}.img"
    if not dest.exists():
        staging = suite_config.cache_dir / "payload-staging"
        staging.mkdir(exist_ok=True)
        target = staging / "new.img.gz"
        if not target.exists() or target.stat().st_size != image_bundle.img_gz.stat().st_size:
            import shutil
            shutil.copyfile(image_bundle.img_gz, target)
        images.build_payload_disk(dest, staging, size="12G")
    return dest


def pytest_runtest_setup(item):
    if item.get_closest_marker("network"):
        ok = item.session._mnq_network_ok if hasattr(item.session, "_mnq_network_ok") else None
        if ok is None:
            try:
                urllib.request.urlopen("https://api.github.com", timeout=8).close()
                ok = True
            except Exception:
                ok = False
            item.session._mnq_network_ok = ok
        if not ok:
            pytest.skip("no internet connectivity (network marker)")


# ---------------------------------------------------------------------------
# Per-test artifacts + guest factories
# ---------------------------------------------------------------------------

@pytest.fixture(autouse=True)
def artifacts(request, suite_config) -> Collector:
    slug = test_id_slug(request.node.nodeid)
    collector = Collector(test_id=slug,
                          out_dir=suite_config.artifacts_dir / slug)
    request.node._mnq_collector = collector
    yield collector
    collector.save_transcript()


@pytest.fixture
def guest_factory(request, suite_config, artifacts):
    """Create Guests wired to this test's artifact collector.

    Teardown: on failure, gather forensics from every still-live guest, then
    kill everything and delete throwaway disks (unless --keep-guests).
    """
    created: list[tuple[Guest, list[Path]]] = []
    seq = {"n": 0}
    # _mnq_guests: read by pytest_runtest_makereport so failure forensics are
    # gathered while the guests are still ALIVE (the call-phase hook runs
    # before fixture teardown).  Shared across fixtures; teardown below only
    # closes the guests THIS factory created.
    if not hasattr(request.node, "_mnq_guests"):
        request.node._mnq_guests = []

    def make(disks: list[DiskSpec], *, name: str = "", mem_mb: int = 4096,
             firmware: str = "bios", ssh_key=None,
             throwaway: list[Path] | None = None) -> Guest:
        seq["n"] += 1
        gname = f"{artifacts.test_id}-{name or 'g'}{seq['n']}"[:80]
        guest = Guest(
            gname, disks, suite_config,
            mem_mb=mem_mb, firmware=firmware, ssh_key=ssh_key,
            log_dir=artifacts.out_dir / f"guest-{name or 'g'}{seq['n']}",
            transcript_cb=artifacts.on_command,
            screenshot_cb=artifacts.on_screenshot,
        )
        created.append((guest, throwaway or []))
        request.node._mnq_guests.append(guest)
        guest.launch()
        if suite_config.gif_every_boot:
            guest.start_gif_capture()
        return guest

    yield make

    for guest, throwaway in created:
        guest.close(keep_dirs=suite_config.keep_guests)
        if not suite_config.keep_guests:
            for p in throwaway:
                Path(p).unlink(missing_ok=True)


@pytest.fixture
def overlay_disks(tmp_path, golden):
    """Fresh qcow2 overlays on the golden system + data disks."""
    def make(prefix: str = "d") -> tuple[Path, Path]:
        sysd = images.create_overlay(golden.golden_qcow2, "qcow2",
                                     tmp_path / f"{prefix}-sys.qcow2")
        datad = images.create_overlay(golden.data_golden, "qcow2",
                                      tmp_path / f"{prefix}-data.qcow2")
        return sysd, datad
    return make


@pytest.fixture
def golden_guest(guest_factory, overlay_disks, golden) -> Guest:
    """A booted, SSH-ready guest on golden overlays (the workhorse)."""
    sysd, datad = overlay_disks()
    guest = guest_factory(
        [DiskSpec(str(sysd)), DiskSpec(str(datad), serial="NASDATA0")],
        name="golden", ssh_key=golden.ssh_key,
        throwaway=[sysd, datad],
    )
    guest.wait_ssh()
    # sshd is up well before the supervisor mounts nasdata + starts docker/
    # samba; health-asserting tests must not race that convergence.
    guest.wait_ready()
    return guest


@pytest.fixture
def pristine_guest(guest_factory, tmp_path, golden) -> Guest:
    """A guest booted from the pristine (wizard-not-run) image overlay.

    The SSH key is already on the BOOT partition (injected into base.img),
    but most pristine tests drive the serial console.
    """
    sysd = images.create_overlay(golden.base_img, "raw",
                                 tmp_path / "pristine-sys.qcow2")
    return guest_factory([DiskSpec(str(sysd))], name="pristine",
                         ssh_key=golden.ssh_key, throwaway=[sysd])


@pytest.fixture(scope="module")
def shared_cli_guest(request, suite_config, golden):
    """ONE golden guest shared by a module's read-only tests (category C)."""
    tmp = suite_config.run_dir / "shared" / request.module.__name__
    tmp.mkdir(parents=True, exist_ok=True)
    sysd = images.create_overlay(golden.golden_qcow2, "qcow2", tmp / "sys.qcow2")
    datad = images.create_overlay(golden.data_golden, "qcow2", tmp / "data.qcow2")
    guest = Guest(
        f"shared-{request.module.__name__}",
        [DiskSpec(str(sysd)), DiskSpec(str(datad), serial="NASDATA0")],
        suite_config, ssh_key=golden.ssh_key,
        log_dir=tmp,
    )
    guest.launch()
    guest.wait_ssh()
    guest.wait_ready()   # data plane converged before the read-only C tests run
    yield guest
    guest.close(keep_dirs=suite_config.keep_guests)
    if not suite_config.keep_guests:
        sysd.unlink(missing_ok=True)
        datad.unlink(missing_ok=True)


@pytest.fixture
def wired_shared_guest(request, shared_cli_guest, artifacts) -> Guest:
    """The module-shared guest with callbacks pointed at THIS test's
    collector (so its commands/screenshots land in the right report row)."""
    shared_cli_guest.transcript_cb = artifacts.on_command
    shared_cli_guest.screenshot_cb = artifacts.on_screenshot
    if not hasattr(request.node, "_mnq_guests"):
        request.node._mnq_guests = []
    request.node._mnq_guests.append(shared_cli_guest)   # forensics on failure
    return shared_cli_guest


@pytest.fixture
def smtp_sink():
    sink = SMTPSink().start()
    yield sink
    sink.stop()


@pytest.fixture
def http_server(tmp_path):
    srv = DirServer(tmp_path).start()
    yield srv
    srv.stop()


# ---------------------------------------------------------------------------
# Report hooks
# ---------------------------------------------------------------------------

def pytest_configure(config):
    # environment table in the report header (pytest-metadata, if present)
    try:
        md = config._metadata  # pytest-metadata < 3
    except AttributeError:
        try:
            from pytest_metadata.plugin import metadata_key
            md = config.stash[metadata_key]
        except Exception:
            md = None
    if md is not None:
        md["QEMU"] = C.qemu_version()
        md["KVM"] = "yes" if os.environ.get("MOUNTNAS_KVM") == "1" else "NO (TCG)"
        md["Time scale"] = os.environ.get("MOUNTNAS_TEST_TIME_SCALE", "1.0")
        md["Repo"] = C.GITHUB_REPO
        for noisy in ("Packages", "Plugins", "JAVA_HOME"):
            md.pop(noisy, None)
    config._mnq_results = []


@pytest.hookimpl(optionalhook=True)
def pytest_html_report_title(report):
    report.title = ("MountNAS QEMU test suite -- "
                    + datetime.date.today().isoformat())


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    report = outcome.get_result()
    # Record exactly once per test: the call phase (normal pass/fail/body-skip),
    # or a setup phase that ended the test (marker/fixture skip, or setup error)
    # -- otherwise summary.json silently omits every setup-phase skip.
    is_call = report.when == "call"
    setup_terminal = report.when == "setup" and (report.failed or report.skipped)
    if not (is_call or setup_terminal):
        return

    # record for summary.json (before the collector guard, so skips still count)
    item.config._mnq_results.append({
        "nodeid": item.nodeid,
        "outcome": report.outcome,
        "when": report.when,
        "duration": round(report.duration, 2),
    })

    collector: Collector | None = getattr(item, "_mnq_collector", None)
    if collector is None:
        return

    if report.failed:
        # guests are still alive here (fixture teardown runs after this
        # hook) -- grab the evidence now so it lands in THIS report row
        for guest in getattr(item, "_mnq_guests", []):
            try:
                collector.attach_forensics(guest.forensics())
            except Exception as exc:
                log.warning("forensics failed for %s: %s", guest.name, exc)

    if html_extras is None:
        return
    ext = getattr(report, "extras", [])
    for shot in collector.screenshots:
        try:
            b64 = base64.b64encode(shot.path.read_bytes()).decode()
            ext.append(html_extras.png(b64, name=f"{shot.guest}: {shot.label}"))
        except OSError:
            pass
    tr_html = collector.transcript.to_html()
    if tr_html:
        ext.append(html_extras.html(tr_html))
    for f in collector.files:
        try:
            if f.mime.startswith("image/"):
                b64 = base64.b64encode(f.path.read_bytes()).decode()
                ext.append(html_extras.html(
                    f'<div><b>{f.label}</b><br>'
                    f'<img style="max-width:100%" '
                    f'src="data:{f.mime};base64,{b64}"></div>'))
            else:
                text = f.path.read_text(errors="replace")
                if len(text) > 200_000:
                    text = "<truncated>\n" + text[-200_000:]
                ext.append(html_extras.text(text, name=f.label))
        except OSError:
            pass
    report.extras = ext


def pytest_sessionfinish(session, exitstatus):
    config = session.config
    results = getattr(config, "_mnq_results", [])
    run_dir = config.getoption("--run-dir") or ""
    if not run_dir:
        return
    counts: dict = {}
    for r in results:
        counts[r["outcome"]] = counts.get(r["outcome"], 0) + 1
    summary = {
        "date": datetime.datetime.now().isoformat(timespec="seconds"),
        "exitstatus": int(exitstatus),
        "qemu": C.qemu_version(),
        "kvm": os.environ.get("MOUNTNAS_KVM") == "1",
        "time_scale": float(os.environ.get("MOUNTNAS_TEST_TIME_SCALE", "1.0")),
        "counts": counts,
        "tests": results,
    }
    try:
        (Path(run_dir) / "summary.json").write_text(
            json.dumps(summary, indent=2))
    except OSError as exc:
        log.warning("could not write summary.json: %s", exc)
