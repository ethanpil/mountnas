"""Threaded HTTP file server for URL-upgrade tests.

Serves a directory on 0.0.0.0:<random port>; guests fetch from
http://10.0.2.2:<port>/<name> through QEMU slirp.
"""

from __future__ import annotations

import functools
import http.server
import logging
import threading
from pathlib import Path

log = logging.getLogger("mountnas.httpserv")


class _QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        log.debug("http: " + fmt, *args)


class DirServer:
    def __init__(self, directory: Path, host: str = "0.0.0.0", port: int = 0):
        handler = functools.partial(_QuietHandler, directory=str(directory))
        self.httpd = http.server.ThreadingHTTPServer((host, port), handler)
        self.port = self.httpd.server_address[1]
        self.directory = Path(directory)
        self._thread = threading.Thread(
            target=self.httpd.serve_forever, daemon=True)

    def start(self) -> "DirServer":
        self._thread.start()
        log.info("HTTP server for %s on port %d", self.directory, self.port)
        return self

    def stop(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()

    def guest_url(self, name: str) -> str:
        return f"http://10.0.2.2:{self.port}/{name}"
