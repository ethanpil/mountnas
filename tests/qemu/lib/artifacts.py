"""Per-test artifact collector.

One collector exists per test (autouse fixture).  Guests created by the
factories are wired to it via callbacks, so every screenshot and every
run()/run_serial() lands here automatically.  The conftest report hook then
embeds everything into the pytest-html report and copies raw files into
run_dir/artifacts/<test-id>/ for grep-ability outside the report.
"""

from __future__ import annotations

import logging
import re
import shutil
from dataclasses import dataclass, field
from pathlib import Path

from .transcript import Transcript

log = logging.getLogger("mountnas.artifacts")


@dataclass
class Screenshot:
    guest: str
    label: str
    path: Path


@dataclass
class AttachedFile:
    label: str
    path: Path
    mime: str = "text/plain"


@dataclass
class Collector:
    test_id: str
    out_dir: Path
    screenshots: list[Screenshot] = field(default_factory=list)
    transcript: Transcript = field(default_factory=Transcript)
    files: list[AttachedFile] = field(default_factory=list)

    def __post_init__(self) -> None:
        self.out_dir.mkdir(parents=True, exist_ok=True)

    # --- guest callbacks ----------------------------------------------------

    def on_screenshot(self, guest: str, label: str, path: Path) -> None:
        dest = self.out_dir / path.name
        try:
            if path.resolve() != dest.resolve():
                shutil.copyfile(path, dest)
        except OSError as exc:
            log.warning("could not copy screenshot %s: %s", path, exc)
            dest = path
        self.screenshots.append(Screenshot(guest=guest, label=label, path=dest))

    def on_command(self, guest: str, result) -> None:
        self.transcript.add(guest, result)

    # --- explicit attachments -------------------------------------------------

    def attach_file(self, label: str, path: Path, mime: str = "text/plain") -> None:
        p = Path(path)
        if p.exists():
            self.files.append(AttachedFile(label=label, path=p, mime=mime))

    def attach_forensics(self, forensics: dict) -> None:
        for key, path in forensics.items():
            p = Path(path)
            if not p.exists():
                continue
            if p.suffix == ".png":
                self.screenshots.append(
                    Screenshot(guest="forensics", label=key, path=p))
            else:
                self.attach_file(f"forensics: {key}", p)

    def save_transcript(self) -> None:
        if self.transcript.entries:
            (self.out_dir / "transcript.txt").write_text(
                self.transcript.to_text(), encoding="utf-8")


def test_id_slug(nodeid: str) -> str:
    """tests_qemu/test_a_boot.py::test_x[p] -> test_a_boot-test_x-p"""
    tail = nodeid.split("/")[-1].replace(".py::", "-")
    return re.sub(r"[^A-Za-z0-9_.-]+", "-", tail)[:120]
