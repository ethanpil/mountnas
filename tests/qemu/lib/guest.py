"""Guest: one QEMU MountNAS VM -- lifecycle, serial, SSH, QMP, faults, capture.

Launch conventions mirror the proven CI invocations in
.github/workflows/build.yml (virtio-only disks -- the kernel cmdline module
list has no IDE; KVM args when /dev/kvm is present; -m 8192 for upgrades).

Sockets (QMP, serial, SSH ControlPath) live in a short /tmp directory to stay
under the 108-byte AF_UNIX path limit; logs and screenshots live in the run
directory so they survive for the report.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Optional

from . import config as C
from .qmp import QMPClient
from .serial_console import SerialConsole, SerialResult

log = logging.getLogger("mountnas.guest")

VALID_BUSES = ("virtio-blk", "virtio-scsi", "ahci", "nvme")


def _pdeathsig_preexec():
    """Ask the kernel to SIGKILL this child when its parent (the test process)
    dies -- so a crashed/killed pytest can never leak running QEMU guests.

    Without this, qemu children are reparented to init and keep consuming RAM;
    on a memory-constrained host a few orphans will thrash the box into
    unresponsiveness.  Linux-only (PR_SET_PDEATHSIG=1); a no-op elsewhere.
    """
    try:
        import ctypes
        import signal
        ctypes.CDLL("libc.so.6", use_errno=True).prctl(1, signal.SIGKILL, 0, 0, 0)
    except Exception:
        pass


@dataclass
class DiskSpec:
    path: str
    fmt: str = "qcow2"                 # raw | qcow2
    bus: str = "virtio-blk"
    serial: str = ""                   # stable /dev/disk/by-id identity
    blkdebug: Optional[dict] = None    # e.g. {"event": "read_aio", "errno": 5}


@dataclass
class RunResult:
    rc: int
    out: str
    command: str
    duration: float
    channel: str = "ssh"

    def __bool__(self) -> bool:
        return self.rc == 0


class GuestError(RuntimeError):
    pass


class Guest:
    def __init__(
        self,
        name: str,
        disks: list[DiskSpec],
        cfg,                                  # SuiteConfig
        *,
        mem_mb: int = 4096,
        firmware: str = "bios",               # bios | uefi
        ssh_key: Optional[Path] = None,
        log_dir: Optional[Path] = None,
        transcript_cb: Optional[Callable] = None,
        screenshot_cb: Optional[Callable] = None,
    ):
        if firmware == "uefi" and not cfg.ovmf:
            raise GuestError("UEFI requested but MOUNTNAS_OVMF is not set")
        for d in disks:
            if d.bus not in VALID_BUSES:
                raise GuestError(f"unknown bus {d.bus!r}")
        self.name = name
        self.disks = disks
        self.cfg = cfg
        cap = getattr(cfg, "mem_cap_mb", 0)
        self.mem_mb = min(mem_mb, cap) if cap else mem_mb
        if cap and mem_mb > cap:
            log.warning("guest %s: capping RAM %dMB -> %dMB (MOUNTNAS_TEST_MEM_MB)",
                        name, mem_mb, cap)
        self.firmware = firmware
        self.ssh_key = Path(ssh_key) if ssh_key else None
        self.transcript_cb = transcript_cb
        self.screenshot_cb = screenshot_cb

        self.log_dir = Path(log_dir) if log_dir else cfg.run_dir / "guests" / name
        self.log_dir.mkdir(parents=True, exist_ok=True)
        # short-path socket dir (AF_UNIX 108-byte limit)
        self._sock_dir = Path(tempfile.mkdtemp(prefix="mnq-", dir="/tmp"))
        self.qmp_path = str(self._sock_dir / "qmp.sock")
        self.serial_path = str(self._sock_dir / "ser.sock")
        self.ssh_ctl = str(self._sock_dir / "ssh.ctl")

        self.ssh_port = _free_port()
        self.proc: Optional[subprocess.Popen] = None
        self.qmp: Optional[QMPClient] = None
        self.serial: Optional[SerialConsole] = None
        self._shot_seq = 0
        self._hot_seq = 0
        self._gif_stop: Optional[threading.Event] = None
        self._gif_thread: Optional[threading.Thread] = None
        self._gif_frames: list[Path] = []
        self._png_ok: Optional[bool] = None  # screendump png support probe

    # ------------------------------------------------------------------ launch

    def _disk_args(self) -> list[str]:
        args: list[str] = []
        need_scsi = any(d.bus == "virtio-scsi" for d in self.disks)
        need_ahci = any(d.bus == "ahci" for d in self.disks)
        if need_scsi:
            args += ["-device", "virtio-scsi-pci,id=scsi0"]
        if need_ahci:
            args += ["-device", "ahci,id=ahci0"]
        ahci_slot = 0
        for i, d in enumerate(self.disks):
            file_node = f"file{i}"
            fmt_node = f"disk{i}"
            args += ["-blockdev", json.dumps({
                "driver": "file", "filename": str(d.path),
                "node-name": file_node, "discard": "unmap",
            })]
            # blkdebug wraps the PROTOCOL (file) node, with the format node on
            # top of it -- the standard layering, so injected read errors reach
            # the guest instead of being masked by the format layer above.
            fmt_child = file_node
            if d.blkdebug:
                dbg_node = f"dbg{i}"
                args += ["-blockdev", json.dumps({
                    "driver": "blkdebug", "image": file_node,
                    "node-name": dbg_node, "inject-error": [d.blkdebug],
                })]
                fmt_child = dbg_node
            args += ["-blockdev", json.dumps({
                "driver": d.fmt, "file": fmt_child, "node-name": fmt_node,
            })]
            serial = d.serial or f"MNQ{i}"
            dev_id = f"dev{i}"
            # Pin the boot disk (always disk 0) so SeaBIOS boots it regardless
            # of what other controllers/buses are present -- a scsi-hd/ide-hd
            # data disk otherwise perturbs the boot order and the box hangs in
            # the BIOS (nvme happened not to, which masked this).
            boot = ",bootindex=1" if i == 0 else ""
            if d.bus == "virtio-blk":
                args += ["-device",
                         f"virtio-blk-pci,drive={fmt_node},id={dev_id},serial={serial}{boot}"]
            elif d.bus == "virtio-scsi":
                args += ["-device",
                         f"scsi-hd,drive={fmt_node},id={dev_id},bus=scsi0.0,serial={serial}{boot}"]
            elif d.bus == "ahci":
                args += ["-device",
                         f"ide-hd,drive={fmt_node},id={dev_id},bus=ahci0.{ahci_slot},serial={serial}{boot}"]
                ahci_slot += 1
            elif d.bus == "nvme":
                args += ["-device", f"nvme,drive={fmt_node},id={dev_id},serial={serial}{boot}"]
        return args

    def _build_argv(self) -> list[str]:
        argv = [
            C.qemu_binary(), *self.cfg.kvm_args,
            "-m", str(self.mem_mb),
            "-machine", "pc",
            "-display", "none", "-vga", "std",
            "-qmp", f"unix:{self.qmp_path},server=on,wait=off",
            "-chardev", f"socket,id=ser0,path={self.serial_path},server=on,wait=off",
            "-serial", "chardev:ser0",
            "-netdev", f"user,id=net0,hostfwd=tcp:127.0.0.1:{self.ssh_port}-:22",
            "-device", "virtio-net-pci,netdev=net0",
        ]
        if self.firmware == "uefi":
            argv += ["-bios", self.cfg.ovmf]
        argv += self._disk_args()
        return argv

    def launch(self) -> "Guest":
        # _free_port() is a TOCTOU probe: the port can be taken between the
        # probe closing and QEMU binding hostfwd (two guests alive at once).
        # Retry on that specific failure with a fresh port before giving up.
        for attempt in range(4):
            argv = self._build_argv()
            log.info("launching guest %s: %s", self.name, " ".join(argv))
            (self.log_dir / "qemu-cmdline.txt").write_text(" \\\n  ".join(argv))
            self.proc = subprocess.Popen(
                argv,
                stdout=open(self.log_dir / "qemu-stdout.log", "ab"),
                stderr=open(self.log_dir / "qemu-stderr.log", "ab"),
                preexec_fn=_pdeathsig_preexec if os.name == "posix" else None,
            )
            # fail fast BEFORE the (up-to-30s) QMP connect: an immediate exit
            # means bad args / bad image / port clash.
            time.sleep(0.3)
            if self.proc.poll() is not None:
                err = self._read_qemu_stderr()
                if attempt < 3 and ("forward" in err.lower() or "bind" in err.lower()
                                    or "address already in use" in err.lower()):
                    log.warning("guest %s: hostfwd port %d clashed, retrying",
                                self.name, self.ssh_port)
                    self.ssh_port = _free_port()
                    continue
                log.error("qemu stderr for %s:\n%s", self.name, err[-4000:])
                raise GuestError(f"qemu exited rc={self.proc.returncode} at launch")
            break

        try:
            self.qmp = QMPClient(self.qmp_path)
            self.serial = SerialConsole(
                self.serial_path, self.log_dir / "serial.log",
                time_scale=self.cfg.time_scale,
            )
        except Exception:
            self._dump_qemu_stderr()
            self.kill()
            raise
        return self

    def _read_qemu_stderr(self) -> str:
        try:
            return (self.log_dir / "qemu-stderr.log").read_text(errors="replace")
        except OSError:
            return ""

    def _dump_qemu_stderr(self) -> None:
        err = self._read_qemu_stderr()
        if err.strip():
            log.error("qemu stderr for %s:\n%s", self.name, err[-4000:])

    @property
    def alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    # ------------------------------------------------------------------ serial

    def expect(self, pattern, timeout: float = 60.0):
        return self.serial.expect(pattern, timeout)

    def sendline(self, s: str = "") -> None:
        self.serial.sendline(s)

    def login_serial(self, password: Optional[str] = None, timeout: float = 420.0) -> None:
        self.serial.login(password=password, timeout=timeout)

    def run_serial(self, cmd: str, timeout: float = 120.0) -> RunResult:
        res: SerialResult = self.serial.run(cmd, timeout=timeout)
        rr = RunResult(rc=res.rc, out=res.output, command=res.command,
                       duration=res.duration, channel="serial")
        if self.transcript_cb:
            self.transcript_cb(self.name, rr)
        return rr

    def run_wizard(
        self,
        hostname: str = "",
        password: str = C.GOLDEN_PASSWORD,
        timezone: str = "",
        network: str = "",          # "" -> accept DHCP default
        login_first: bool = True,
    ) -> None:
        """Drive the 5-step first-boot wizard over serial.

        The wizard auto-starts at the first root login (profile-nas-welcome.sh),
        but that is best-effort: if it doesn't fire (already logged in, or the
        auto-start raced the login), the interactive shell prompt appears
        instead -- in which case we kick `nas setup` by hand.  Either way we end
        up at the Hostname prompt.
        """
        s = self.serial
        if login_first:
            s.expect(C.LOGIN, timeout=420)
            s.sendline("root")
        idx = s.expect([C.WIZARD_HOSTNAME, C.PROMPT], timeout=180)
        if idx == 1:                      # shell prompt -> wizard didn't auto-start
            s.sendline("nas setup")
            s.expect(C.WIZARD_HOSTNAME, timeout=120)
        s.sendline(hostname)
        s.expect(C.WIZARD_PASSWORD, timeout=60)
        s.sendline(password)
        s.expect(C.WIZARD_RETYPE, timeout=60)
        s.sendline(password)
        s.expect(C.WIZARD_TIMEZONE, timeout=60)
        s.sendline(timezone)
        s.expect(C.WIZARD_NETWORK, timeout=60)
        s.sendline(network)
        s.expect(C.WIZARD_DONE, timeout=300)
        s.expect(C.PROMPT, timeout=120)

    # ------------------------------------------------------------------ ssh

    def _ssh_base(self) -> list[str]:
        if not self.ssh_key:
            raise GuestError("guest has no ssh_key configured")
        return [
            "ssh",
            "-i", str(self.ssh_key),
            "-p", str(self.ssh_port),
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "LogLevel=ERROR",
            "-o", "ControlMaster=auto",
            "-o", f"ControlPath={self.ssh_ctl}",
            "-o", "ControlPersist=120",
            "root@127.0.0.1",
        ]

    def wait_ssh(self, timeout: float = 300.0) -> None:
        deadline = time.monotonic() + self.cfg.scaled(timeout)
        last = ""
        while time.monotonic() < deadline:
            if not self.alive:
                raise GuestError(f"guest {self.name} died while waiting for SSH")
            p = subprocess.run(
                self._ssh_base() + ["true"],
                capture_output=True, text=True, timeout=30,
            )
            if p.returncode == 0:
                return
            last = (p.stderr or "").strip()
            time.sleep(2)
        raise TimeoutError(f"SSH to {self.name} not up after {timeout}s: {last}")

    def run(self, cmd: str, timeout: float = 120.0, check: bool = False) -> RunResult:
        start = time.monotonic()
        try:
            p = subprocess.run(
                self._ssh_base() + [cmd],
                capture_output=True, text=True,
                timeout=self.cfg.scaled(timeout),
            )
            rc, out = p.returncode, (p.stdout or "") + (p.stderr or "")
        except subprocess.TimeoutExpired:
            rc, out = 124, f"<host-side timeout after {timeout}s (scaled)>"
        rr = RunResult(rc=rc, out=out.rstrip("\n"), command=cmd,
                       duration=time.monotonic() - start)
        if self.transcript_cb:
            self.transcript_cb(self.name, rr)
        log.debug("ssh %s rc=%d: %s", self.name, rc, cmd)
        if check and rc != 0:
            raise GuestError(f"[{self.name}] `{cmd}` rc={rc}:\n{out[-3000:]}")
        return rr

    def poll_until(self, cmd: str, timeout: float = 120.0,
                   interval: float = 3.0, desc: str = "") -> RunResult:
        """Re-run `cmd` over SSH until rc==0 (scaled deadline)."""
        deadline = time.monotonic() + self.cfg.scaled(timeout)
        last: Optional[RunResult] = None
        while time.monotonic() < deadline:
            last = self.run(cmd, timeout=30)
            if last.rc == 0:
                return last
            time.sleep(interval)
        raise TimeoutError(
            f"poll_until {desc or cmd!r} failed after {timeout}s (scaled); "
            f"last rc={last.rc if last else '?'}:\n{last.out[-1500:] if last else ''}"
        )

    def data_state(self) -> str:
        """Supervisor state: fresh|ok|netfs|disconnected|mountfail (or '')."""
        return self.run(f"cat {C.STATE_DIR}/data 2>/dev/null", timeout=30).out.strip()

    def push(self, local: Path, remote: str) -> None:
        """scp a file into the guest (reuses the SSH control socket)."""
        argv = ["scp", "-i", str(self.ssh_key), "-P", str(self.ssh_port),
                "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                "-o", "LogLevel=ERROR", "-o", f"ControlPath={self.ssh_ctl}",
                str(local), f"root@127.0.0.1:{remote}"]
        subprocess.run(argv, check=True, capture_output=True,
                       timeout=self.cfg.scaled(120))

    def pull(self, remote: str, local: Path, timeout: float = 600.0) -> None:
        """scp a file out of the guest (reuses the SSH control socket).
        Default timeout is generous: the restore drill pulls a ~1 GB image."""
        argv = ["scp", "-i", str(self.ssh_key), "-P", str(self.ssh_port),
                "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                "-o", "LogLevel=ERROR", "-o", f"ControlPath={self.ssh_ctl}",
                f"root@127.0.0.1:{remote}", str(local)]
        subprocess.run(argv, check=True, capture_output=True,
                       timeout=self.cfg.scaled(timeout))

    def wait_ready(self, timeout: float = 300.0) -> None:
        """Wait for the mountnas supervisor to converge after boot.

        SSH (via sshd) comes up well before the supervisor finishes its disk
        wait + docker/samba start, so a guest that is merely wait_ssh()-ready
        can still fail a `nas status` health assertion.  Callers that assert a
        healthy box must wait for this first.
        """
        self.poll_until(f"[ \"$(cat {C.STATE_DIR}/data 2>/dev/null)\" = ok ]",
                        timeout=timeout, desc="data state ok")
        self.poll_until("rc-service docker status", timeout=timeout,
                        desc="docker up")
        self.poll_until("rc-service samba status", timeout=120, desc="samba up")

    def reboot(self, timeout: float = 420.0) -> None:
        """Reboot over SSH and wait until the guest is reachable again."""
        # detach so the dropped connection can't kill the reboot
        self.run("( sleep 1; /sbin/reboot ) >/dev/null 2>&1 &", timeout=15)
        deadline = time.monotonic() + self.cfg.scaled(60)
        while time.monotonic() < deadline:      # wait for it to go DOWN
            if self.run("true", timeout=10).rc != 0:
                break
            time.sleep(1)
        # the ssh master socket is dead now; drop it so new sessions reconnect
        subprocess.run(
            ["ssh", "-o", f"ControlPath={self.ssh_ctl}", "-O", "exit",
             "-p", str(self.ssh_port), "root@127.0.0.1"],
            capture_output=True, timeout=10,
        )
        self.wait_ssh(timeout=timeout)

    # ------------------------------------------------------------------ capture

    def screenshot(self, label: str) -> Optional[Path]:
        """QMP screendump of the VGA console -> PNG in the guest log dir."""
        if not self.qmp or not self.alive:
            return None
        self._shot_seq += 1
        base = f"{self._shot_seq:03d}-{_slug(label)}"
        png = self.log_dir / f"{base}.png"
        try:
            if self._png_ok is not False:
                try:
                    self.qmp.execute("screendump", filename=str(png), format="png")
                    self._png_ok = True
                except Exception:
                    if self._png_ok:  # worked before -> real failure
                        raise
                    self._png_ok = False
            if self._png_ok is False:
                ppm = self.log_dir / f"{base}.ppm"
                self.qmp.execute("screendump", filename=str(ppm))
                _ppm_to_png(ppm, png)
        except Exception as exc:
            log.warning("screenshot %s failed: %s", label, exc)
            return None
        if self.screenshot_cb:
            self.screenshot_cb(self.name, label, png)
        return png

    def start_gif_capture(self, interval: float = 2.0) -> None:
        self._gif_frames = []
        self._gif_stop = threading.Event()

        def _loop():
            n = 0
            while not self._gif_stop.is_set() and self.alive:
                n += 1
                frame = self.log_dir / f"gif-{n:04d}.png"
                try:
                    if self._png_ok is False:
                        ppm = self.log_dir / f"gif-{n:04d}.ppm"
                        self.qmp.execute("screendump", filename=str(ppm))
                        _ppm_to_png(ppm, frame)
                    else:
                        try:
                            self.qmp.execute("screendump", filename=str(frame), format="png")
                            self._png_ok = True
                        except Exception:
                            self._png_ok = False
                            continue
                    self._gif_frames.append(frame)
                except Exception:
                    pass
                self._gif_stop.wait(interval)

        self._gif_thread = threading.Thread(target=_loop, daemon=True)
        self._gif_thread.start()

    def stop_gif_capture(self) -> list[Path]:
        if self._gif_stop:
            self._gif_stop.set()
        if self._gif_thread:
            self._gif_thread.join(timeout=10)
        return list(self._gif_frames)

    # ------------------------------------------------------------------ faults

    def attach_data_disk(self, spec: DiskSpec, dev_id: str = "hot0") -> str:
        """Hot-plug a disk via QMP blockdev-add + device_add.  Returns dev_id."""
        self._hot_seq += 1
        file_node = f"hotfile{self._hot_seq}"
        fmt_node = f"hotdisk{self._hot_seq}"
        self.qmp.execute("blockdev-add", driver="file",
                         filename=str(spec.path),
                         **{"node-name": file_node})
        # blkdebug wraps the protocol node; format sits on top (see _disk_args)
        fmt_child = file_node
        if spec.blkdebug:
            dbg_node = f"hotdbg{self._hot_seq}"
            self.qmp.execute("blockdev-add", driver="blkdebug", image=file_node,
                             **{"node-name": dbg_node,
                                "inject-error": [spec.blkdebug]})
            fmt_child = dbg_node
        self.qmp.execute("blockdev-add", driver=spec.fmt, file=fmt_child,
                         **{"node-name": fmt_node})
        if spec.bus != "virtio-blk":
            raise GuestError("hot-plug is implemented for virtio-blk only")
        self.qmp.execute("device_add", driver="virtio-blk-pci",
                         drive=fmt_node, id=dev_id,
                         serial=spec.serial or f"HOT{self._hot_seq}")
        self._hot_nodes = getattr(self, "_hot_nodes", {})
        self._hot_nodes[dev_id] = fmt_node
        return dev_id

    def detach_disk(self, dev_id: str, timeout: float = 60.0) -> None:
        """Hot-unplug: device_del + wait for the guest to release it."""
        self.qmp.execute("device_del", id=dev_id)
        self.qmp.wait_event("DEVICE_DELETED", timeout=self.cfg.scaled(timeout))
        node = getattr(self, "_hot_nodes", {}).pop(dev_id, None)
        if node:
            try:
                self.qmp.execute("blockdev-del", **{"node-name": node})
            except Exception as exc:
                log.debug("blockdev-del %s: %s", node, exc)

    # ------------------------------------------------------------------ stop

    def poweroff(self, timeout: float = 180.0) -> None:
        """Clean shutdown via the guest's own /sbin/poweroff."""
        try:
            self.sendline("/sbin/poweroff")
        except Exception:
            pass
        self.wait_dead(timeout)

    def quit_hard(self) -> None:
        """Power cut: QMP quit kills the VM instantly, no guest flush."""
        try:
            self.qmp.execute("quit", timeout=10)
        except Exception:
            pass
        self.wait_dead(30)

    def wait_dead(self, timeout: float = 120.0) -> None:
        if not self.proc:
            return
        deadline = time.monotonic() + self.cfg.scaled(timeout)
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                return
            time.sleep(0.5)
        log.warning("guest %s did not exit; killing", self.name)
        self.kill()

    def kill(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.kill()
            try:
                self.proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                pass

    def close(self, keep_dirs: bool = False) -> None:
        self.stop_gif_capture()
        # tear down the ssh master so no orphan holds the control socket
        if self.ssh_key:
            subprocess.run(
                ["ssh", "-o", f"ControlPath={self.ssh_ctl}", "-O", "exit",
                 "-p", str(self.ssh_port), "root@127.0.0.1"],
                capture_output=True, timeout=10,
            )
        self.kill()
        if self.serial:
            self.serial.close()
        if self.qmp:
            self.qmp.close()
        if not keep_dirs:
            shutil.rmtree(self._sock_dir, ignore_errors=True)

    # ------------------------------------------------------------------ forensics

    def forensics(self) -> dict:
        """Best-effort evidence bundle for a failed test."""
        out: dict = {"serial_log": self.log_dir / "serial.log"}
        shot = self.screenshot("failure-final-screen")
        if shot:
            out["final_screen"] = shot
        if self.ssh_key and self.alive:
            try:
                dmesg = self.run("dmesg | tail -n 200", timeout=20)
                if dmesg.rc == 0:
                    p = self.log_dir / "failure-dmesg.txt"
                    p.write_text(dmesg.out, encoding="utf-8")
                    out["dmesg"] = p
            except Exception:
                pass
        qerr = self.log_dir / "qemu-stderr.log"
        if qerr.exists() and qerr.stat().st_size:
            out["qemu_stderr"] = qerr
        return out


# ---------------------------------------------------------------------------


def import_busybox_image(guest: "Guest", tag: str = "mnq-busybox") -> None:
    """Registry-free container image built from the guest's own busybox.

    Alpine's /bin/busybox is DYNAMICALLY linked against musl -- the loader
    (/lib/ld-musl-x86_64.so.1) must ride along in the rootfs, or every exec
    inside the container fails with the misleading
    'exec /bin/busybox: no such file or directory' and the container
    crash-loops. Found the hard way: the docker tests originally shipped the
    binary alone, and their point-in-time 'Up' checks kept landing in the
    brief running window of the crash loop -- always pair a container-running
    assertion with a RestartCount check.
    """
    guest.run(
        "rm -rf /tmp/rootfs && mkdir -p /tmp/rootfs/bin /tmp/rootfs/lib && "
        "cp /bin/busybox /tmp/rootfs/bin/ && "
        "cp /lib/ld-musl-x86_64.so.1 /tmp/rootfs/lib/ && "
        "ln -sf busybox /tmp/rootfs/bin/sh && "
        f"tar -c -C /tmp/rootfs . | docker import - {tag}",
        timeout=120, check=True)


def assert_container_stable(guest: "Guest", name: str,
                            timeout: float = 120.0,
                            settle: float = 5.0) -> None:
    """The container is Up, STAYS Up across a settle window, and has never
    restarted -- a crash-looper can pass a bare 'Up' grep during its brief
    running windows, and even an immediate RestartCount read can land inside
    the FIRST pre-crash Up window while the count is still 0."""
    up_cmd = (f"docker ps --format '{{{{.Names}}}} {{{{.Status}}}}' "
              f"| grep -E '{name} Up'")
    guest.poll_until(up_cmd, timeout=timeout, desc=f"container {name} up")
    time.sleep(guest.cfg.scaled(settle))
    r2 = guest.run(up_cmd)
    assert r2.rc == 0, \
        f"container {name} did not stay Up through the settle window"
    r = guest.run(
        f"docker inspect --format '{{{{.RestartCount}}}}' {name}", check=True)
    assert r.out.strip() == "0", \
        f"container {name} is crash-looping (restarts={r.out.strip()})"


def _free_port() -> int:
    import socket as _s
    with _s.socket(_s.AF_INET, _s.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _slug(label: str) -> str:
    return "".join(c if c.isalnum() or c in "-_" else "-" for c in label)[:60]


def _ppm_to_png(ppm: Path, png: Path) -> None:
    from PIL import Image
    with Image.open(ppm) as im:
        im.save(png)
    try:
        os.unlink(ppm)
    except OSError:
        pass
