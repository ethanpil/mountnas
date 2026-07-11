"""Golden snapshot: a fully set-up MountNAS frozen as qcow2 backing files.

Built once per (image sha256, GOLDEN_SCHEMA_VERSION) and cached; every test
then boots a throwaway overlay in seconds instead of re-running the wizard.

Build recipe (mirrors scripts/ci-supervisor-test.exp):
  boot pristine image + blank 8G data disk
  -> first-boot wizard over serial (hostname/password/tz/DHCP)
  -> over SSH: mkfs.ext4 -L nasdata /dev/vdb, fstab line, mountnas restart,
     wait for docker+samba, `nas status` rc 0, `nas commit`
  -> poweroff.
meta.json is written LAST via atomic rename: its presence marks the cache
entry valid.  Bump config.GOLDEN_SCHEMA_VERSION when this recipe changes.
"""

from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from . import config as C
from . import images
from .guest import DiskSpec, Guest, GuestError

log = logging.getLogger("mountnas.golden")


@dataclass
class GoldenArtifacts:
    dir: Path
    base_img: Path          # raw, key-injected, pristine (wizard NOT run)
    golden_qcow2: Path      # backing file: wizard done, data disk committed
    data_golden: Path       # backing file: the ext4 'nasdata' disk
    ssh_key: Path
    ssh_pub: Path
    password: str
    boot_gif: Optional[Path]
    meta: dict


def golden_key(bundle: images.ImageBundle) -> str:
    return f"{bundle.sha256[:16]}-v{C.GOLDEN_SCHEMA_VERSION}"


def load_or_build(cfg, bundle: images.ImageBundle, make_gif: bool = True) -> GoldenArtifacts:
    gdir = cfg.golden_dir / golden_key(bundle)
    meta_path = gdir / "meta.json"
    if meta_path.exists():
        try:
            meta = json.loads(meta_path.read_text())
            art = _artifacts_from(gdir, meta)
            log.info("golden cache HIT: %s (built %s)", gdir.name,
                     meta.get("created", "?"))
            return art
        except Exception as exc:
            log.warning("golden cache entry unreadable (%s); rebuilding", exc)
    return _build(cfg, bundle, gdir, make_gif)


def _artifacts_from(gdir: Path, meta: dict) -> GoldenArtifacts:
    art = GoldenArtifacts(
        dir=gdir,
        base_img=gdir / "base.img",
        golden_qcow2=gdir / "golden.qcow2",
        data_golden=gdir / "data-golden.qcow2",
        ssh_key=gdir / "id_ed25519",
        ssh_pub=gdir / "id_ed25519.pub",
        password=meta["password"],
        boot_gif=(gdir / "boot.gif") if (gdir / "boot.gif").exists() else None,
        meta=meta,
    )
    for p in (art.base_img, art.golden_qcow2, art.data_golden, art.ssh_key):
        if not p.exists():
            raise FileNotFoundError(p)
    return art


def _build(cfg, bundle: images.ImageBundle, gdir: Path, make_gif: bool) -> GoldenArtifacts:
    log.info("building golden snapshot in %s (one-time, ~6-8 min)", gdir)
    started = time.monotonic()
    gdir.mkdir(parents=True, exist_ok=True)
    # stale partial build -> clear the validity marker's friends
    for leftover in gdir.glob("*.part"):
        leftover.unlink()

    base_img = gdir / "base.img"
    if not base_img.exists():
        images.sparse_gunzip(bundle.img_gz, base_img)
    key, pub = images.generate_keypair(gdir)
    images.inject_ssh_key(base_img, pub)

    golden_qcow2 = images.create_overlay(base_img, "raw", gdir / "golden.qcow2")
    data_golden = images.create_blank_qcow2(gdir / "data-golden.qcow2", "8G")

    guest = Guest(
        "golden-build",
        [DiskSpec(str(golden_qcow2), fmt="qcow2"),
         DiskSpec(str(data_golden), fmt="qcow2", serial="NASDATA0")],
        cfg,
        ssh_key=key,
        log_dir=cfg.run_dir / "guests" / "golden-build",
    )
    boot_gif: Optional[Path] = None
    try:
        guest.launch()
        if make_gif:
            guest.start_gif_capture(interval=2.0)

        # ---- serial: first boot + wizard --------------------------------
        guest.run_wizard(
            hostname=C.GOLDEN_HOSTNAME,
            password=C.GOLDEN_PASSWORD,
            timezone="",
            network="",
        )
        frames = guest.stop_gif_capture()
        guest.screenshot("wizard-complete-console")

        # ---- ssh: storage + services + commit ----------------------------
        guest.wait_ssh(timeout=300)
        guest.run("mkfs.ext4 -Fq -L nasdata /dev/vdb", timeout=180, check=True)
        guest.run(f"printf '%s\\n' '{C.DATA_FSTAB_LINE}' >> /etc/fstab",
                  timeout=30, check=True)
        guest.run("rc-service mountnas restart", timeout=180, check=True)
        _wait_service(guest, "docker", 240)
        _wait_service(guest, "samba", 120)
        st = guest.run("nas status", timeout=180)
        if st.rc != 0:
            raise GuestError(f"nas status rc={st.rc} during golden build:\n{st.out}")
        nas_version = guest.run(f"cat {C.VERSION_FILE}", timeout=30).out.strip()
        guest.run("nas commit", timeout=180, check=True)
        guest.poweroff(timeout=180)

        if make_gif and frames:
            boot_gif = _assemble_gif(frames, gdir / "boot.gif")
    except Exception:
        guest.forensics()
        raise
    finally:
        guest.close()

    meta = {
        "tag": bundle.tag,
        "sha256": bundle.sha256,
        "schema": C.GOLDEN_SCHEMA_VERSION,
        "password": C.GOLDEN_PASSWORD,
        "hostname": C.GOLDEN_HOSTNAME,
        "nas_version": nas_version,
        "created": time.strftime("%Y-%m-%d %H:%M:%S"),
        "build_seconds": round(time.monotonic() - started, 1),
    }
    tmp = gdir / "meta.json.part"
    tmp.write_text(json.dumps(meta, indent=2))
    tmp.rename(gdir / "meta.json")   # atomic: cache entry now valid
    log.info("golden snapshot built in %.0fs", meta["build_seconds"])
    return _artifacts_from(gdir, meta)


def _wait_service(guest: Guest, svc: str, timeout: float) -> None:
    deadline = time.monotonic() + guest.cfg.scaled(timeout)
    while time.monotonic() < deadline:
        if guest.run(f"rc-service {svc} status", timeout=30).rc == 0:
            return
        time.sleep(5)
    raise GuestError(f"service {svc} not up within {timeout}s (scaled)")


def _assemble_gif(frames: list[Path], dest: Path) -> Optional[Path]:
    """Stitch boot screendumps into an animated GIF, deduping still frames."""
    try:
        from PIL import Image
    except ImportError:
        log.warning("Pillow unavailable; skipping boot GIF")
        return None
    kept: list = []
    prev_bytes: bytes | None = None
    for f in frames:
        try:
            data = f.read_bytes()
        except OSError:
            continue
        if data == prev_bytes:
            continue
        prev_bytes = data
        try:
            im = Image.open(f)
            im.load()
            kept.append(im.convert("P", palette=Image.ADAPTIVE))
        except Exception:
            continue
    if not kept:
        return None
    kept[0].save(
        dest, save_all=True, append_images=kept[1:],
        duration=700, loop=0, optimize=True,
    )
    log.info("boot GIF: %d frames -> %s (%d KB)", len(kept), dest,
             dest.stat().st_size // 1024)
    return dest
