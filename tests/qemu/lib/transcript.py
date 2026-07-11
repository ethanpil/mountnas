"""Command transcripts: the 'screenshot' of everything that has no screen.

nas commands run over SSH (or the serial line) never touch the VGA console,
so their evidence in the report is a rendered transcript: one block per
command with channel, exit code, duration, and ANSI-color-preserved output.

Rendering prefers `ansi2html` (pip); if it is unavailable the SGR escapes are
regex-stripped and the output emitted as plain <pre> -- reports must never
fail to generate because of a missing nicety.
"""

from __future__ import annotations

import html
import re
from dataclasses import dataclass, field

_SGR = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\r")

try:
    from ansi2html import Ansi2HTMLConverter
    _conv = Ansi2HTMLConverter(inline=True, scheme="xterm")

    def _render_ansi(text: str) -> str:
        return _conv.convert(text, full=False)
except ImportError:  # pragma: no cover - degraded mode
    _conv = None

    def _render_ansi(text: str) -> str:
        return html.escape(_SGR.sub("", text))


@dataclass
class Entry:
    guest: str
    channel: str      # ssh | serial
    command: str
    rc: int
    duration: float
    output: str


@dataclass
class Transcript:
    entries: list[Entry] = field(default_factory=list)

    def add(self, guest: str, result) -> None:
        """`result` is a guest.RunResult."""
        self.entries.append(Entry(
            guest=guest, channel=result.channel, command=result.command,
            rc=result.rc, duration=result.duration, output=result.out,
        ))

    def to_html(self) -> str:
        if not self.entries:
            return ""
        blocks = []
        for e in self.entries:
            ok = e.rc == 0
            badge = (
                f'<span style="color:{"#3c763d" if ok else "#a94442"};'
                f'font-weight:bold">rc={e.rc}</span>'
            )
            out = _render_ansi(e.output) if e.output else "<i>(no output)</i>"
            blocks.append(
                '<div style="margin:6px 0;border:1px solid #ddd;'
                'border-radius:4px;overflow:hidden">'
                '<div style="background:#f5f5f5;padding:4px 8px;'
                'font-family:monospace;font-size:12px">'
                f'<b>{html.escape(e.guest)}</b> [{e.channel}] {badge} '
                f'<span style="color:#888">{e.duration:.1f}s</span><br>'
                f'<span style="color:#204a87">$ {html.escape(e.command)}</span>'
                "</div>"
                '<pre style="margin:0;padding:6px 8px;background:#1c1c1c;'
                'color:#ddd;font-size:11px;max-height:400px;overflow:auto;'
                f'white-space:pre-wrap">{out}</pre>'
                "</div>"
            )
        return (
            '<details open style="margin-top:4px"><summary style="cursor:pointer">'
            f"Command transcript ({len(self.entries)} commands)</summary>"
            + "".join(blocks) + "</details>"
        )

    def to_text(self) -> str:
        lines = []
        for e in self.entries:
            lines.append(f"[{e.guest}/{e.channel}] $ {e.command}  "
                         f"(rc={e.rc}, {e.duration:.1f}s)")
            if e.output:
                lines.append(_SGR.sub("", e.output))
            lines.append("")
        return "\n".join(lines)
