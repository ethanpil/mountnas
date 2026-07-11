"""Minimal synchronous QMP client (stdlib only).

QMP is JSON objects over a stream socket: the server sends a greeting, the
client must send {"execute": "qmp_capabilities"} once, then every
{"execute": ...} gets exactly one {"return"/"error": ...} reply.  Async
events ({"event": ...}) can arrive interleaved at any time; we buffer them
so callers can wait for e.g. DEVICE_DELETED or SHUTDOWN.
"""

from __future__ import annotations

import json
import logging
import socket
import threading
import time

log = logging.getLogger("mountnas.qmp")


class QMPError(RuntimeError):
    def __init__(self, cmd: str, error: dict):
        self.cmd = cmd
        self.error = error
        super().__init__(f"QMP {cmd}: {error.get('class')}: {error.get('desc')}")


class QMPClient:
    def __init__(self, sock_path: str, connect_timeout: float = 30.0):
        self.sock_path = sock_path
        self._buf = b""
        self._events: list[dict] = []
        # Reentrant so the background GIF-capture thread and the main thread
        # can never interleave reads on the shared socket/buffer (execute ->
        # take_events -> poll_events re-acquire on the same thread).
        self._lock = threading.RLock()
        self._sock = self._connect(connect_timeout)
        greeting = self._recv_obj(timeout=10.0)
        if "QMP" not in greeting:
            raise RuntimeError(f"unexpected QMP greeting: {greeting!r}")
        self.qemu_version = greeting["QMP"].get("version", {})
        self.execute("qmp_capabilities")

    def _connect(self, timeout: float) -> socket.socket:
        # QEMU creates the socket at startup (server=on,wait=off) but there
        # can be a beat between process launch and the socket existing.
        deadline = time.monotonic() + timeout
        last_err: Exception | None = None
        while time.monotonic() < deadline:
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(self.sock_path)
                s.settimeout(10.0)
                return s
            except OSError as exc:
                last_err = exc
                time.sleep(0.2)
        raise RuntimeError(f"could not connect QMP socket {self.sock_path}: {last_err}")

    # -- wire ---------------------------------------------------------------

    def _recv_obj(self, timeout: float) -> dict:
        """Read one JSON object (newline-delimited), buffering events aside."""
        deadline = time.monotonic() + timeout
        while True:
            nl = self._buf.find(b"\n")
            if nl >= 0:
                line, self._buf = self._buf[:nl], self._buf[nl + 1:]
                if not line.strip():
                    continue
                return json.loads(line)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"QMP read timeout ({timeout}s)")
            self._sock.settimeout(min(remaining, 10.0))
            try:
                chunk = self._sock.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
                raise ConnectionError("QMP socket closed by QEMU")
            self._buf += chunk

    # -- API ----------------------------------------------------------------

    def execute(self, cmd: str, timeout: float = 30.0, **arguments) -> dict:
        req: dict = {"execute": cmd}
        if arguments:
            req["arguments"] = arguments
        log.debug("QMP >> %s %s", cmd, arguments or "")
        with self._lock:
            self._sock.sendall(json.dumps(req).encode() + b"\n")
            deadline = time.monotonic() + timeout
            while True:
                obj = self._recv_obj(timeout=max(0.1, deadline - time.monotonic()))
                if "event" in obj:
                    log.debug("QMP event %s", obj["event"])
                    self._events.append(obj)
                    continue
                if "error" in obj:
                    raise QMPError(cmd, obj["error"])
                if "return" in obj:
                    return obj["return"]
                log.debug("QMP ignoring %r", obj)

    def poll_events(self) -> None:
        """Drain anything already on the socket into the event buffer."""
        with self._lock:
            self._sock.settimeout(0.05)
            try:
                while True:
                    chunk = self._sock.recv(65536)
                    if not chunk:
                        break
                    self._buf += chunk
            except (socket.timeout, OSError):
                pass
            while True:
                nl = self._buf.find(b"\n")
                if nl < 0:
                    break
                line, self._buf = self._buf[:nl], self._buf[nl + 1:]
                if not line.strip():
                    continue
                obj = json.loads(line)
                if "event" in obj:
                    log.debug("QMP event %s", obj["event"])
                    self._events.append(obj)

    def take_events(self, name: str | None = None) -> list[dict]:
        with self._lock:
            self.poll_events()
            if name is None:
                taken, self._events = self._events, []
                return taken
            taken = [e for e in self._events if e["event"] == name]
            self._events = [e for e in self._events if e["event"] != name]
            return taken

    def wait_event(self, name: str, timeout: float = 60.0) -> dict:
        """Block until the named async event arrives (or was already buffered)."""
        with self._lock:
            got = self.take_events(name)
            if got:
                return got[0]
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                try:
                    obj = self._recv_obj(timeout=max(0.1, deadline - time.monotonic()))
                except TimeoutError:
                    break
                if "event" in obj:
                    if obj["event"] == name:
                        return obj
                    self._events.append(obj)
                # replies with no outstanding execute shouldn't happen; ignore
        raise TimeoutError(f"QMP event {name} not seen within {timeout}s")

    def close(self) -> None:
        try:
            self._sock.close()
        except OSError:
            pass
