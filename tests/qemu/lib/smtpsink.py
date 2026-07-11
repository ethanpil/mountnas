"""Tiny threaded SMTP sink (stdlib only).

Python's smtpd module was removed in 3.12 and aiosmtpd would be another pip
dep, so this implements the handful of verbs msmtp needs for a plaintext
delivery (HELO/EHLO, MAIL, RCPT, DATA, RSET, QUIT -- no TLS, no auth).
Guests reach it at 10.0.2.2:<port> through QEMU slirp.

Collected messages are exposed as ReceivedMail records for assertions.
"""

from __future__ import annotations

import logging
import socketserver
import threading
import time
from dataclasses import dataclass, field
from email import message_from_string

log = logging.getLogger("mountnas.smtpsink")


@dataclass
class ReceivedMail:
    mail_from: str
    rcpt_tos: list[str]
    data: str

    @property
    def subject(self) -> str:
        return message_from_string(self.data).get("Subject", "")

    @property
    def body(self) -> str:
        msg = message_from_string(self.data)
        if msg.is_multipart():
            parts = [p.get_payload(decode=False) for p in msg.walk()
                     if p.get_content_type() == "text/plain"]
            return "\n".join(str(p) for p in parts)
        return str(msg.get_payload())


def configure_guest_msmtp(guest, port: int,
                          alert_email: str = "alerts@test.local") -> None:
    """Point the guest's mail pipeline at the host-side sink (10.0.2.2).

    Overwrites /etc/msmtprc with a plaintext no-auth account (the shipped
    file is a commented template) and sets the disk-loss alert address.
    """
    guest.run(
        "cat > /etc/msmtprc <<'EOF'\n"
        "defaults\n"
        "auth off\n"
        "tls off\n"
        "account default\n"
        "host 10.0.2.2\n"
        f"port {port}\n"
        "from mountnas@test.local\n"
        "EOF\n"
        "chmod 600 /etc/msmtprc",
        check=True,
    )
    guest.run(f"printf '%s\\n' '{alert_email}' > /etc/mountnas/alert-email",
              check=True)


class _Handler(socketserver.StreamRequestHandler):
    def _reply(self, line: str) -> None:
        self.wfile.write((line + "\r\n").encode())

    def handle(self) -> None:  # noqa: C901 - simple state machine
        server: SMTPSink = self.server  # type: ignore[assignment]
        self._reply("220 mountnas-test-sink ESMTP")
        mail_from, rcpts, data_lines = "", [], []
        in_data = False
        while True:
            try:
                raw = self.rfile.readline()
            except OSError:
                return
            if not raw:
                return
            line = raw.decode(errors="replace").rstrip("\r\n")
            if in_data:
                if line == ".":
                    in_data = False
                    mail = ReceivedMail(mail_from, list(rcpts),
                                        "\n".join(data_lines))
                    with server.lock:
                        server.messages.append(mail)
                    log.info("sink: message for %s subj=%r",
                             rcpts, mail.subject)
                    mail_from, rcpts, data_lines = "", [], []
                    self._reply("250 OK: queued")
                else:
                    data_lines.append(line[1:] if line.startswith("..") else line)
                continue
            verb = line.split(":")[0].split(" ")[0].upper()
            if verb in ("HELO", "EHLO"):
                if verb == "EHLO":
                    self.wfile.write(b"250-mountnas-test-sink\r\n250 8BITMIME\r\n")
                else:
                    self._reply("250 mountnas-test-sink")
            elif verb == "MAIL":
                mail_from = line.partition(":")[2].strip()
                self._reply("250 OK")
            elif verb == "RCPT":
                rcpts.append(line.partition(":")[2].strip())
                self._reply("250 OK")
            elif verb == "DATA":
                in_data = True
                data_lines = []
                self._reply("354 End data with <CR><LF>.<CR><LF>")
            elif verb == "RSET":
                mail_from, rcpts = "", []
                self._reply("250 OK")
            elif verb == "NOOP":
                self._reply("250 OK")
            elif verb == "QUIT":
                self._reply("221 Bye")
                return
            else:
                self._reply(f"502 command not implemented: {verb}")


class SMTPSink(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, host: str = "0.0.0.0", port: int = 0):
        super().__init__((host, port), _Handler)
        self.messages: list[ReceivedMail] = []
        self.lock = threading.Lock()
        self.port = self.server_address[1]
        self._thread = threading.Thread(target=self.serve_forever, daemon=True)

    def start(self) -> "SMTPSink":
        self._thread.start()
        log.info("SMTP sink listening on %s:%d", *self.server_address)
        return self

    def stop(self) -> None:
        self.shutdown()
        self.server_close()

    def clear(self) -> None:
        with self.lock:
            self.messages.clear()

    def wait_for_mail(self, count: int = 1, timeout: float = 60.0) -> list[ReceivedMail]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self.lock:
                if len(self.messages) >= count:
                    return list(self.messages)
            time.sleep(0.5)
        with self.lock:
            got = list(self.messages)
        raise TimeoutError(
            f"expected {count} mail(s) within {timeout}s, got {len(got)}")
