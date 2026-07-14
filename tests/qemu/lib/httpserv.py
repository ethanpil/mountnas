"""Threaded HTTP file server for URL-upgrade tests + webhook-sink capture.

Serves a directory on 0.0.0.0:<random port>; guests fetch from
http://10.0.2.2:<port>/<name> through QEMU slirp.  POST bodies (webhook
notification sinks under test) are recorded on `server.posts`.
"""

from __future__ import annotations

import functools
import http.server
import logging
import threading
import time
from dataclasses import dataclass
from pathlib import Path

log = logging.getLogger("mountnas.httpserv")


@dataclass
class PostRecord:
    path: str
    body: bytes
    content_type: str


class _QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        log.debug("http: " + fmt, *args)

    def do_POST(self) -> None:  # noqa: N802 - stdlib naming
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else b""
        rec = PostRecord(path=self.path, body=body,
                         content_type=self.headers.get("Content-Type", ""))
        srv = self.server
        with srv._post_lock:            # type: ignore[attr-defined]
            srv.posts.append(rec)       # type: ignore[attr-defined]
        log.info("http: POST %s (%d bytes)", self.path, len(body))
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")


class DirServer:
    def __init__(self, directory: Path, host: str = "0.0.0.0", port: int = 0):
        handler = functools.partial(_QuietHandler, directory=str(directory))
        self.httpd = http.server.ThreadingHTTPServer((host, port), handler)
        self.httpd.posts = []                      # type: ignore[attr-defined]
        self.httpd._post_lock = threading.Lock()   # type: ignore[attr-defined]
        self.port = self.httpd.server_address[1]
        self.directory = Path(directory)
        self._thread = threading.Thread(
            target=self.httpd.serve_forever, daemon=True)

    @property
    def posts(self) -> list[PostRecord]:
        with self.httpd._post_lock:                # type: ignore[attr-defined]
            return list(self.httpd.posts)          # type: ignore[attr-defined]

    def wait_for_post(self, count: int = 1, timeout: float = 60.0) -> list[PostRecord]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            got = self.posts
            if len(got) >= count:
                return got
            time.sleep(0.5)
        raise TimeoutError(
            f"expected {count} POST(s) within {timeout}s, got {len(self.posts)}")

    def start(self) -> "DirServer":
        self._thread.start()
        log.info("HTTP server for %s on port %d", self.directory, self.port)
        return self

    def stop(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()

    def guest_url(self, name: str) -> str:
        return f"http://10.0.2.2:{self.port}/{name}"
