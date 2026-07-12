"""Suite-wide configuration: paths, timing, and the serial-console contract.

Everything that couples this suite to MountNAS's console output lives HERE
(prompt regexes, marker conventions) so a product-side wording change breaks
exactly one module.  The regexes are ported verbatim from the CI expect
scripts (scripts/ci-supervisor-test.exp, scripts/ci-upgrade-test.exp), which
the product deliberately keeps stable for CI's sake.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

# Bump whenever the golden-snapshot build recipe changes (wizard answers,
# data-disk layout, committed state...).  Invalidates every cached golden.
GOLDEN_SCHEMA_VERSION = 1

# GitHub repo the release images are downloaded from (same one the `nas` CLI
# uses -- see REPO= at the top of mountnas-tools/files/nas).
GITHUB_REPO = os.environ.get("MOUNTNAS_TEST_REPO", "ethanpil/mountnas")

# ---------------------------------------------------------------------------
# Serial-console contract (single source -- see module docstring)
# ---------------------------------------------------------------------------

# The root shell prompt.  busybox ash for root in ~ renders ":~# ".
PROMPT = r":~# "

# Login prompt printed by getty on ttyS0.
LOGIN = r"login: "

# First-boot wizard prompts, in on-screen order (nas cmd_setup, steps 1-5).
WIZARD_HOSTNAME = r"Hostname \["
WIZARD_PASSWORD = r"New [Pp]assword"
WIZARD_RETYPE = r"[Rr]etype"
WIZARD_TIMEZONE = r"Timezone"
WIZARD_NETWORK = r"HCP"          # "[D]HCP (default) / [S]tatic" -- matches either echo
WIZARD_DONE = r"Setup complete"

# nas upgrade console cues (cmd_upgrade).
UPGRADE_YES_GATE = r"Type YES"
UPGRADE_SUCCESS = r"Upgrade written successfully"
UPGRADE_RESTORE = r"RESTORE YOUR BACKUP"

# Guest-side addresses under QEMU slirp user networking.
GUEST_IP = "10.0.2.15"
HOST_FROM_GUEST = "10.0.2.2"

# Well-known guest paths asserted all over the suite.
STATE_DIR = "/run/mountnas"          # supervisor state ($STATE)
DATA_MOUNT = "/mnt/nasdata"
BOOTMNT = "/media/mnasboot"          # the mounted BOOT partition ($BOOTMNT)
SETUP_DONE = "/etc/mountnas/setup-done"
ALERT_EMAIL = "/etc/mountnas/alert-email"
VERSION_FILE = "/usr/share/mountnas/version"
RELEASE_FILE = "/usr/share/mountnas/release"

# Root password baked into the golden snapshot (recorded in meta.json too).
GOLDEN_PASSWORD = "mnastest1"
# Keep the image's DEFAULT hostname: renaming it orphans the seed's
# <host>.apkovl.tar.gz and makes `lbu commit` refuse ("use -d to replace").
# The CI supervisor test keeps the default for the same reason.
GOLDEN_HOSTNAME = "mountnas"

# fstab line the golden build (and the CI supervisor test) uses for the data
# disk.  LABEL-based so it survives bus/slot changes in overlay guests.
DATA_FSTAB_LINE = "LABEL=nasdata /mnt/nasdata ext4 rw,noatime,nofail 0 2"


def _default_time_scale() -> float:
    env = os.environ.get("MOUNTNAS_TEST_TIME_SCALE")
    if env:
        return float(env)
    return 1.0 if os.environ.get("MOUNTNAS_KVM") == "1" else 6.0


@dataclass
class SuiteConfig:
    """Resolved once per session (conftest `suite_config` fixture)."""

    run_dir: Path
    image_arg: str | None = None          # --image (path or empty -> download)
    previous_arg: str | None = None       # --previous (path or empty)
    keep_guests: bool = False
    gif_every_boot: bool = False
    kvm: bool = field(default_factory=lambda: os.environ.get("MOUNTNAS_KVM") == "1")
    time_scale: float = field(default_factory=_default_time_scale)
    ovmf: str = field(default_factory=lambda: os.environ.get("MOUNTNAS_OVMF", ""))
    # Optional cap on per-guest RAM (MB) for memory-constrained hosts.  A guest
    # requesting more (e.g. upgrades at 8192) is clamped down to this.  0/unset
    # = use each guest's requested size.  Upgrades still need real headroom, so
    # this is a debugging aid, not a way to run the full suite on a tiny box.
    mem_cap_mb: int = field(
        default_factory=lambda: int(os.environ.get("MOUNTNAS_TEST_MEM_MB", "0") or "0"))
    cache_dir: Path = field(
        default_factory=lambda: Path(
            os.environ.get(
                "MOUNTNAS_TEST_CACHE",
                os.path.expanduser("~/.cache/mountnas-qemu"),
            )
        )
    )

    def __post_init__(self) -> None:
        self.run_dir = Path(self.run_dir)
        self.artifacts_dir = self.run_dir / "artifacts"
        self.artifacts_dir.mkdir(parents=True, exist_ok=True)
        self.images_dir = self.cache_dir / "images"
        self.golden_dir = self.cache_dir / "golden"
        self.images_dir.mkdir(parents=True, exist_ok=True)
        self.golden_dir.mkdir(parents=True, exist_ok=True)

    def scaled(self, seconds: float) -> float:
        """Every timeout in the suite goes through this."""
        return seconds * self.time_scale

    @property
    def kvm_args(self) -> list[str]:
        # Mirrors build.yml: KVM="-enable-kvm -cpu host" when /dev/kvm exists.
        return ["-enable-kvm", "-cpu", "host"] if self.kvm else []


def qemu_binary() -> str:
    path = shutil.which("qemu-system-x86_64")
    if not path:
        raise RuntimeError(
            "qemu-system-x86_64 not found -- run via run-suite.sh, which "
            "installs/verifies dependencies"
        )
    return path


def qemu_version() -> str:
    try:
        out = subprocess.run(
            [qemu_binary(), "--version"],
            capture_output=True, text=True, timeout=10, check=True,
        ).stdout
        return out.splitlines()[0].strip()
    except Exception as exc:  # pragma: no cover - informational only
        return f"unknown ({exc})"
