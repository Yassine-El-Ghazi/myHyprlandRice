#!/usr/bin/python3
"""Session-local idle controls; presentation mode never stops the lock daemon."""

import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import time


PRESENTATION_SECONDS = 3600


def session():
    signature = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    display = os.environ.get("WAYLAND_DISPLAY", "")
    if not signature or not display:
        raise ValueError("idle controls require a graphical Hyprland session")
    return signature, display


@contextlib.contextmanager
def state():
    signature, display = session()
    root = Path(os.environ.get("XDG_RUNTIME_DIR", ""))
    if not root.is_absolute():
        raise ValueError("a private runtime directory is required")
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    fd = None
    try:
        metadata = os.fstat(directory)
        if metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
            raise ValueError("runtime directory is not private")
        name = "myhypr-idle-" + hashlib.sha256(f"{signature}\0{display}".encode()).hexdigest()
        fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                     0o600, dir_fd=directory)
        metadata = os.fstat(fd)
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
                or metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) != 0o600):
            raise ValueError("idle state is not a private file")
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield fd
    finally:
        if fd is not None:
            os.close(fd)
        os.close(directory)


def presentation(fd):
    os.lseek(fd, 0, os.SEEK_SET)
    try:
        deadline = float(os.read(fd, 128).decode())
    except (ValueError, UnicodeError):
        return False
    remaining = deadline - time.monotonic()
    return 0 < remaining <= PRESENTATION_SECONDS


def write_deadline(fd, value):
    os.lseek(fd, 0, os.SEEK_SET)
    os.ftruncate(fd, 0)
    os.write(fd, str(value).encode())


def daemon_pids():
    signature, display = session()
    expected = {f"HYPRLAND_INSTANCE_SIGNATURE={signature}".encode(),
                f"WAYLAND_DISPLAY={display}".encode()}
    pids = []
    for process in Path("/proc").iterdir():
        if not process.name.isdecimal():
            continue
        try:
            if process.stat().st_uid != os.geteuid() or (process / "comm").read_text().strip() != "hypridle":
                continue
            if expected <= set((process / "environ").read_bytes().split(b"\0")):
                pids.append(int(process.name))
        except (OSError, UnicodeError):
            continue
    return pids


def ensure_daemon():
    if daemon_pids():
        return
    config = Path(os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config"))
    subprocess.Popen([str(config / "myhypr/bin/launch-app"), "hypridle"],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
    for _ in range(40):
        if daemon_pids():
            return
        time.sleep(0.05)
    raise ValueError("Hypridle did not start; locking needs attention")


def restart_daemon():
    # A pidfd binds signals to this process even if its numeric PID is reused.
    for pid in daemon_pids():
        try:
            fd = os.pidfd_open(pid)
        except ProcessLookupError:
            continue
        try:
            if pid in daemon_pids():
                signal.pidfd_send_signal(fd, signal.SIGTERM)
        finally:
            os.close(fd)
    for _ in range(40):
        if not daemon_pids():
            ensure_daemon()
            return
        time.sleep(0.05)
    raise ValueError("Hypridle did not stop; restart refused")


def main(arguments):
    if len(arguments) != 1 or arguments[0] not in {
        "status", "toggle", "start", "restart", "dim", "display-off", "suspend",
    }:
        raise ValueError("expected status, toggle, start, restart, dim, display-off, or suspend")
    action = arguments[0]
    with state() as fd:
        active = presentation(fd)
        if action in {"dim", "display-off", "suspend"}:
            if active:
                return 0
            commands = {
                "dim": ["brightnessctl", "-s", "set", "10"],
                "display-off": ["hyprctl", "dispatch", "hl.dsp.dpms({ action = 'off' })"],
                "suspend": ["systemctl", "suspend"],
            }
            # Do not hold the state lock while a power request waits for sleep.
            command = commands[action]
        else:
            if action == "restart":
                restart_daemon()
            elif action in {"start", "toggle"}:
                ensure_daemon()
            if action == "toggle":
                active = not active
                write_deadline(fd, time.monotonic() + PRESENTATION_SECONDS if active else 0)
            running = bool(daemon_pids())
            print(json.dumps({
                "text": "ERROR" if not running else "PRESENTING" if active else "RUNNING",
                "class": "notactive" if not running else "presentation" if active else "active",
                "tooltip": ("Hypridle is unavailable; click to start it" if not running else
                            "Presentation mode: dimming and automatic sleep paused for up to one hour\n"
                            "Locking remains enabled\nLeft: End presentation\nRight: Lock Screen" if active else
                            "Locking enabled\nLeft: Present for one hour\nRight: Lock Screen"),
            }))
            return 0
    return subprocess.run(command, check=False).returncode


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError, subprocess.SubprocessError):
        if sys.argv[1:] == ["status"]:
            print(json.dumps({"text": "ERROR", "class": "notactive",
                              "tooltip": "Idle controls unavailable; check the graphical session"}))
        else:
            print("Idle control failed; locking needs attention.", file=sys.stderr)
        sys.exit(1)
