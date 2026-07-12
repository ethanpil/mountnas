"""Serial console driver: unix-socket chardev + a background drainer.

CRITICAL design point: a QEMU serial chardev socket applies back-pressure to
the guest when the host stops reading it -- once the socket buffer fills, the
guest's UART write blocks and the guest's BOOT STALLS.  Guests we drive purely
over SSH (all of categories C/E/F/G/H/I/J) never call expect(), so an
on-demand reader (e.g. pexpect.fdspawn, which only reads inside expect())
would let the buffer fill and wedge those boots -- sshd never comes up.

So this reads the socket continuously on a background thread into an in-memory
buffer (and tees it to serial.log), and expect() searches that buffer.  The
guest is therefore always drained whether or not anyone is watching.

Conventions ported from scripts/ci-supervisor-test.exp / ci-upgrade-test.exp:
markers are sent QUOTE-SPLIT (``echo X"-OK"``) and matched unsplit (``X-OK``)
so a command's own terminal echo can't satisfy the expect; the root prompt is
matched as ``:~# ``.  The buffer is decoded latin-1 (1 byte = 1 char) so match
offsets map exactly back to bytes for consumption.
"""

from __future__ import annotations

import logging
import re
import socket
import threading
import time
from dataclasses import dataclass
from pathlib import Path

from . import config as C

log = logging.getLogger("mountnas.serial")


@dataclass
class SerialResult:
    rc: int
    output: str
    command: str
    duration: float


class SerialTimeout(TimeoutError):
    pass


class SerialConsole:
    def __init__(self, sock_path: str, log_path: Path, time_scale: float = 1.0):
        self.sock_path = sock_path
        self.log_path = Path(log_path)
        self.time_scale = time_scale
        self._seq = 0
        self.before = ""
        self.match: re.Match | None = None
        self._buf = bytearray()
        self._lock = threading.Lock()
        self._closed = False
        self._sock = self._connect()
        self._logfile = open(self.log_path, "ab")
        self._reader = threading.Thread(target=self._drain, daemon=True)
        self._reader.start()

    def _connect(self) -> socket.socket:
        deadline = time.monotonic() + 30
        last: Exception | None = None
        while time.monotonic() < deadline:
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(self.sock_path)
                return s
            except OSError as exc:
                last = exc
                time.sleep(0.2)
        raise RuntimeError(f"could not connect serial socket {self.sock_path}: {last}")

    def _drain(self) -> None:
        """Continuously read the socket so the guest never blocks on serial."""
        self._sock.settimeout(0.5)
        while not self._closed:
            try:
                data = self._sock.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                break
            if not data:
                break
            with self._lock:
                self._buf += data
            try:
                self._logfile.write(data)
                self._logfile.flush()
            except OSError:
                pass

    # -- primitives ----------------------------------------------------------

    def expect(self, pattern, timeout: float = 60.0):
        """Search the drained buffer for a regex (or list of regexes).

        Returns the matched index; sets .before (text before the match) and
        .match.  Consumes the buffer up to and including the match.
        """
        patterns = [pattern] if isinstance(pattern, str) else list(pattern)
        compiled = [re.compile(p) for p in patterns]
        deadline = time.monotonic() + timeout * self.time_scale
        while True:
            with self._lock:
                text = self._buf.decode("latin-1")
            for i, c in enumerate(compiled):
                m = c.search(text)
                if m:
                    self.before = text[: m.start()]
                    self.match = m
                    with self._lock:
                        del self._buf[: m.end()]
                    return i
            if time.monotonic() >= deadline:
                tail = text[-2000:]
                raise SerialTimeout(
                    f"serial expect {patterns!r} timed out after "
                    f"{timeout * self.time_scale:.0f}s; last output:\n{tail}"
                )
            if not self._reader.is_alive():
                raise ConnectionError(
                    f"serial reader died while expecting {patterns!r} "
                    "(guest gone?)"
                )
            time.sleep(0.1)

    def sendline(self, s: str = "") -> None:
        log.debug("serial >> %s", s)
        self._sock.sendall((s + "\n").encode("latin-1", "replace"))

    def send_ctrl_c(self) -> None:
        self._sock.sendall(b"\x03")

    # -- login ---------------------------------------------------------------

    def login(self, password: str | None = None, timeout: float = 420.0) -> None:
        """From power-on (or a fresh getty) to a root shell prompt.

        Handles the three console states: pristine (no password, wizard
        auto-starts -> Ctrl-C skips it), golden (password login), and an
        already-open shell.
        """
        self.expect(C.LOGIN, timeout=timeout)
        self.sendline("root")
        patterns = [C.WIZARD_HOSTNAME, r"[Pp]assword:", C.PROMPT]
        deadline = time.monotonic() + 120 * self.time_scale
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise SerialTimeout("login() never reached a shell prompt")
            idx = self.expect(patterns, timeout=max(5.0, remaining) / self.time_scale)
            if idx == 0:
                self.send_ctrl_c()
                continue
            if idx == 1:
                if password is None:
                    raise RuntimeError("guest asked for a password but none was provided")
                self.sendline(password)
                continue
            return  # prompt

    # -- command execution ----------------------------------------------------

    def run(self, cmd: str, timeout: float = 120.0) -> SerialResult:
        """Run a shell command at the serial prompt, capturing output + rc.

        The rc marker is quote-split on send so the command echo can't match.
        """
        self._seq += 1
        marker = f"MNASRC{self._seq}"
        start = time.monotonic()
        self.sendline(f'{cmd}; echo {marker}"="$?')
        self.expect(re.escape(marker) + r"=(\d+)", timeout=timeout)
        rc = int(self.match.group(1))
        raw = self.before or ""
        lines = raw.splitlines()
        if lines and marker in lines[0]:
            lines = lines[1:]
        output = "\n".join(lines).strip("\r\n")
        self.expect(C.PROMPT, timeout=30)
        dur = time.monotonic() - start
        log.debug("serial rc=%d cmd=%s", rc, cmd)
        return SerialResult(rc=rc, output=output, command=cmd, duration=dur)

    def close(self) -> None:
        self._closed = True
        try:
            self._reader.join(timeout=2)
        except RuntimeError:
            pass
        try:
            self._logfile.flush()
            self._logfile.close()
        except OSError:
            pass
        try:
            self._sock.close()
        except OSError:
            pass
