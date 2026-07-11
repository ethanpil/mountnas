"""Serial console driver: unix-socket chardev + pexpect.

Conventions ported from scripts/ci-supervisor-test.exp / ci-upgrade-test.exp:

* Marker strings are sent QUOTE-SPLIT (``echo X"-OK"``) and matched unsplit
  (``X-OK``) so the terminal's echo of the typed command can never satisfy
  the expect -- only the command's actual output can.
* The root shell prompt is matched as ``:~# ``.

Every read byte is teed to ``serial.log`` in the guest's run directory, which
is the primary forensic artifact when a test fails.
"""

from __future__ import annotations

import logging
import re
import socket
import time
from dataclasses import dataclass
from pathlib import Path

import pexpect
import pexpect.fdpexpect

from . import config as C

log = logging.getLogger("mountnas.serial")


@dataclass
class SerialResult:
    rc: int
    output: str
    command: str
    duration: float


class SerialConsole:
    def __init__(self, sock_path: str, log_path: Path, time_scale: float = 1.0):
        self.sock_path = sock_path
        self.log_path = Path(log_path)
        self.time_scale = time_scale
        self._seq = 0
        self._sock = self._connect()
        self._logfile = open(self.log_path, "a", encoding="utf-8", errors="replace")
        self.child = pexpect.fdpexpect.fdspawn(
            self._sock.fileno(),
            encoding="utf-8",
            codec_errors="replace",
            timeout=int(60 * time_scale),
        )
        self.child.logfile_read = self._logfile

    def _connect(self) -> socket.socket:
        deadline = time.monotonic() + 30
        last: Exception | None = None
        while time.monotonic() < deadline:
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(self.sock_path)
                s.setblocking(True)
                return s
            except OSError as exc:
                last = exc
                time.sleep(0.2)
        raise RuntimeError(f"could not connect serial socket {self.sock_path}: {last}")

    # -- primitives ----------------------------------------------------------

    def expect(self, pattern, timeout: float = 60.0):
        """Expect a regex (or list). Timeout is scaled. Returns match index."""
        scaled = timeout * self.time_scale
        try:
            return self.child.expect(pattern, timeout=scaled)
        except pexpect.TIMEOUT:
            tail = (self.child.before or "")[-2000:]
            raise TimeoutError(
                f"serial expect {pattern!r} timed out after {scaled:.0f}s; "
                f"last output:\n{tail}"
            ) from None
        except pexpect.EOF:
            raise ConnectionError(
                f"serial EOF while expecting {pattern!r} (guest died?)"
            ) from None

    def sendline(self, s: str = "") -> None:
        log.debug("serial >> %s", s)
        self.child.sendline(s)

    def send_ctrl_c(self) -> None:
        self.child.send("\x03")

    # -- login ---------------------------------------------------------------

    def login(self, password: str | None = None, timeout: float = 420.0) -> None:
        """From power-on (or a fresh getty) to a root shell prompt.

        Handles all three states a MountNAS console can be in:
          * pristine image: no password, first-boot wizard auto-starts at
            login -> Ctrl-C skips it (ci-upgrade-test.exp login_to_shell);
          * golden image: password login;
          * already-logged-in shell (idempotent re-login attempt).
        """
        self.expect(C.LOGIN, timeout=timeout)
        self.sendline("root")
        patterns = [C.WIZARD_HOSTNAME, r"[Pp]assword:", C.PROMPT]
        deadline = time.monotonic() + 120 * self.time_scale
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                # a wizard that ignores Ctrl-C, or a password loop, must not
                # spin here forever and wedge the whole (untimed) suite
                raise TimeoutError("login() never reached a shell prompt "
                                   f"within {120 * self.time_scale:.0f}s")
            # expect() re-multiplies by time_scale, so divide it back out here
            idx = self.expect(patterns, timeout=max(5.0, remaining) / self.time_scale)
            if idx == 0:
                # wizard auto-started; bail out to the shell
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
        # Sent:    cmd; echo MNASRC1"="$?
        # Output:  MNASRC1=0        <- only real output can look like this
        self.sendline(f'{cmd}; echo {marker}"="$?')
        self.expect(re.escape(marker) + r"=(\d+)", timeout=timeout)
        rc = int(self.child.match.group(1))
        raw = self.child.before or ""
        # Drop the echoed command line (first line of `before`).
        lines = raw.splitlines()
        if lines and marker in lines[0]:
            lines = lines[1:]
        output = "\n".join(lines).strip("\r\n")
        self.expect(C.PROMPT, timeout=30)
        dur = time.monotonic() - start
        log.debug("serial rc=%d cmd=%s", rc, cmd)
        return SerialResult(rc=rc, output=output, command=cmd, duration=dur)

    def close(self) -> None:
        try:
            self._logfile.flush()
            self._logfile.close()
        except OSError:
            pass
        try:
            self._sock.close()
        except OSError:
            pass
