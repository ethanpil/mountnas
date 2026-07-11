"""Image acquisition and disk preparation.

* Download MountNAS release images (latest / previous) from GitHub via the
  unauthenticated API -- the same access pattern `nas upgrade --check` uses,
  so like it, this needs the repo to be public.
* Sparse-decompress .img.gz (mirrors build.yml's `dd conv=sparse` trick).
* Inject the suite's SSH public key onto the image's FAT BOOT partition with
  mtools `mcopy` (no root needed); the shipped `mountnas-sshkey` service
  installs any `authorized_keys` found there on EVERY boot.  Root-only
  losetup+mount fallback included.
* qemu-img overlay helpers and the ext4 payload disk for upgrade tests
  (`mkfs.ext4 -d` populates from a directory without mounting -- unprivileged).
"""

from __future__ import annotations

import gzip
import hashlib
import json
import logging
import os
import shutil
import subprocess
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from . import config as C

log = logging.getLogger("mountnas.images")

_UA = {"User-Agent": "mountnas-qemu-test-suite"}


@dataclass
class ImageBundle:
    img_gz: Path        # the compressed release artifact
    sha256: str         # of the .img.gz
    tag: str            # release tag ("local" for user-supplied files)


class ImageError(RuntimeError):
    pass


# ---------------------------------------------------------------------------
# GitHub release download
# ---------------------------------------------------------------------------

def _api(url: str, timeout: int = 30) -> dict | list:
    req = urllib.request.Request(url, headers=_UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def _download(url: str, dest: Path, timeout: int = 60) -> None:
    log.info("downloading %s -> %s", url, dest)
    tmp = dest.with_suffix(dest.suffix + ".part")
    req = urllib.request.Request(url, headers=_UA)
    with urllib.request.urlopen(req, timeout=timeout) as r, open(tmp, "wb") as f:
        shutil.copyfileobj(r, f, length=1 << 20)
    tmp.rename(dest)


def _release_img_asset(release: dict) -> Optional[dict]:
    for a in release.get("assets", []):
        if a["name"].endswith(".img.gz"):
            return a
    return None


def fetch_release_image(cfg, which: str = "latest") -> Optional[ImageBundle]:
    """which='latest' -> newest release; 'previous' -> the one before it.

    Returns None (rather than raising) for 'previous' when no earlier release
    with an image asset exists -- mirrors the CI upgrade test's first-release
    escape hatch.
    """
    # The /releases/latest endpoint excludes prereleases (alpha/beta tags may
    # be marked as such), so list releases and pick by position instead.
    base = f"https://api.github.com/repos/{C.GITHUB_REPO}/releases"
    try:
        releases = [r for r in _api(f"{base}?per_page=15")
                    if not r.get("draft") and _release_img_asset(r)]
        if which == "latest":
            if not releases:
                raise ImageError(f"{C.GITHUB_REPO} has no release with a .img.gz asset")
            release = releases[0]
        else:
            if len(releases) < 2:
                log.warning("no previous release with an image asset found")
                return None
            release = releases[1]
    except ImageError:
        raise
    except Exception as exc:
        if which == "previous":
            log.warning("previous-release lookup failed: %s", exc)
            return None
        raise ImageError(
            f"could not query {C.GITHUB_REPO} releases ({exc}); is the repo "
            "public?  Pass a local image path instead."
        ) from exc

    asset = _release_img_asset(release)
    if not asset:
        raise ImageError(f"release {release.get('tag_name')} has no .img.gz asset")
    tag = release["tag_name"]
    dest = cfg.images_dir / asset["name"]
    if not dest.exists() or dest.stat().st_size != asset.get("size", -1):
        _download(asset["browser_download_url"], dest)

    digest = sha256_file(dest)
    # verify against SHA256SUMS when the release ships one
    sums = next((a for a in release.get("assets", [])
                 if a["name"] == "SHA256SUMS"), None)
    if sums:
        sums_path = cfg.images_dir / f"SHA256SUMS-{tag}"
        if not sums_path.exists():
            _download(sums["browser_download_url"], sums_path)
        for line in sums_path.read_text().splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[-1].lstrip("*") == asset["name"]:
                if parts[0] != digest:
                    dest.unlink(missing_ok=True)
                    raise ImageError(
                        f"SHA256 mismatch for {asset['name']}: "
                        f"expected {parts[0]}, got {digest}"
                    )
                log.info("SHA256 verified for %s", asset["name"])
    return ImageBundle(img_gz=dest, sha256=digest, tag=tag)


def local_image(path: str) -> ImageBundle:
    p = Path(path).expanduser().resolve()
    if not p.is_file():
        raise ImageError(f"image not found: {p}")
    with open(p, "rb") as f:
        if f.read(2) != b"\x1f\x8b":
            raise ImageError(f"{p} is not gzip data (bad magic)")
    tag = p.name
    for suffix in (".img.gz", ".gz"):
        if tag.endswith(suffix):
            tag = tag[: -len(suffix)]
            break
    if tag.startswith("mountnas-"):
        tag = tag[len("mountnas-"):]
    return ImageBundle(img_gz=p, sha256=sha256_file(p), tag=tag or "local")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Decompress + key injection
# ---------------------------------------------------------------------------

def sparse_gunzip(img_gz: Path, dest: Path) -> None:
    """Decompress, seeking over zero blocks so the raw file stays sparse."""
    log.info("decompressing %s -> %s (sparse)", img_gz, dest)
    tmp = dest.with_suffix(".part")
    zero = bytes(1 << 20)
    with gzip.open(img_gz, "rb") as zf, open(tmp, "wb") as out:
        while True:
            chunk = zf.read(1 << 20)
            if not chunk:
                break
            if chunk == zero[: len(chunk)]:
                out.seek(len(chunk), os.SEEK_CUR)
            else:
                out.write(chunk)
        out.truncate()  # materialize the final hole
    tmp.rename(dest)


def boot_partition_offset(img: Path) -> int:
    """Byte offset of partition 1 (the FAT BOOT partition) via sfdisk --json."""
    out = subprocess.run(
        ["sfdisk", "--json", str(img)],
        capture_output=True, text=True, check=True, timeout=30,
    ).stdout
    table = json.loads(out)["partitiontable"]
    sector = int(table.get("sectorsize", 512))
    parts = table["partitions"]
    first = min(parts, key=lambda p: int(p["start"]))
    return int(first["start"]) * sector


def inject_ssh_key(img: Path, pubkey: Path) -> None:
    """Drop `authorized_keys` onto the FAT root of partition 1.

    mountnas-sshkey (init.d) mounts LABEL=BOOT ro at every boot and appends
    the file's keys to /root/.ssh/authorized_keys -- so this single write
    gives every overlay/derived guest SSH access.
    """
    off = boot_partition_offset(img)
    env = dict(os.environ, MTOOLS_SKIP_CHECK="1")
    try:
        subprocess.run(
            ["mcopy", "-o", "-i", f"{img}@@{off}",
             str(pubkey), "::authorized_keys"],
            capture_output=True, text=True, check=True, timeout=60, env=env,
        )
        log.info("SSH key injected via mcopy at offset %d", off)
        return
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        detail = getattr(exc, "stderr", "") or str(exc)
        log.warning("mcopy injection failed (%s); trying losetup fallback",
                    detail.strip()[:300])
    if os.geteuid() != 0:
        raise ImageError(
            "mcopy failed and the losetup fallback needs root -- install "
            "mtools or run the suite as root"
        )
    _inject_via_losetup(img, pubkey)


def _inject_via_losetup(img: Path, pubkey: Path) -> None:
    loop = subprocess.run(
        ["losetup", "-fP", "--show", str(img)],
        capture_output=True, text=True, check=True, timeout=30,
    ).stdout.strip()
    mnt = Path("/tmp") / f"mnq-boot-{os.getpid()}"
    mnt.mkdir(exist_ok=True)
    try:
        subprocess.run(["mount", f"{loop}p1", str(mnt)], check=True, timeout=30)
        try:
            shutil.copyfile(pubkey, mnt / "authorized_keys")
        finally:
            subprocess.run(["umount", str(mnt)], check=True, timeout=30)
    finally:
        subprocess.run(["losetup", "-d", loop], timeout=30)
        mnt.rmdir()
    log.info("SSH key injected via losetup fallback")


def generate_keypair(dest_dir: Path) -> tuple[Path, Path]:
    key = dest_dir / "id_ed25519"
    pub = dest_dir / "id_ed25519.pub"
    if not key.exists():
        subprocess.run(
            ["ssh-keygen", "-t", "ed25519", "-N", "", "-q",
             "-C", "mountnas-qemu-test-suite", "-f", str(key)],
            check=True, capture_output=True, timeout=30,
        )
    os.chmod(key, 0o600)
    return key, pub


# ---------------------------------------------------------------------------
# qemu-img helpers
# ---------------------------------------------------------------------------

def create_overlay(backing: Path, backing_fmt: str, dest: Path) -> Path:
    """Throwaway qcow2 overlay on an absolute backing path."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["qemu-img", "create", "-q", "-f", "qcow2",
         "-b", str(Path(backing).resolve()), "-F", backing_fmt, str(dest)],
        check=True, capture_output=True, text=True, timeout=60,
    )
    return dest


def create_blank_qcow2(dest: Path, size: str = "8G") -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["qemu-img", "create", "-q", "-f", "qcow2", str(dest), size],
        check=True, capture_output=True, text=True, timeout=60,
    )
    return dest


def build_payload_disk(dest: Path, staging_dir: Path, size: str = "12G") -> Path:
    """Sparse raw ext4 disk pre-populated from staging_dir (no mounting).

    Upgrade guests mount this as /dev/vdb: it carries new.img.gz and doubles
    as TMPDIR scratch space (the CI upgrade test sizes it 12G for the same
    reason -- the guest unpacks ~6 GB into it).
    """
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(".part")
    with open(tmp, "wb") as f:
        f.truncate(_size_bytes(size))
    subprocess.run(
        ["mkfs.ext4", "-Fq", "-m0", "-d", str(staging_dir), str(tmp)],
        check=True, capture_output=True, text=True, timeout=600,
    )
    tmp.rename(dest)
    return dest


def _size_bytes(size: str) -> int:
    mult = {"G": 1 << 30, "M": 1 << 20, "K": 1 << 10}
    if size[-1] in mult:
        return int(size[:-1]) * mult[size[-1]]
    return int(size)
