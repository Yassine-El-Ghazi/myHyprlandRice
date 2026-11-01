#!/usr/bin/python3
"""Bound clipboard retention and remove entries through the provider API."""

import contextlib
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time


RETENTION_SECONDS = 24 * 60 * 60
MODES = {"show_combined", "show_images_only", "show_text_only", "show_pinned_only"}


def command(*arguments):
    return subprocess.run(arguments, capture_output=True, text=True, check=True,
                          timeout=5).stdout


def activate(action, identifier=""):
    command("elephant", "activate", f"clipboard;{identifier};{action};;")


def provider_state():
    response = json.loads(command("elephant", "state", "--json", "clipboard"))
    states = response.get("states")
    if not isinstance(states, list) or not any(mode in states for mode in MODES):
        raise ValueError("invalid clipboard state")
    return states


def set_state(action):
    activate(action)
    expected = "unpaused" if action == "unpause" else "paused" if action == "pause" else action
    for _ in range(20):
        if expected in provider_state():
            return
        time.sleep(0.025)
    raise ValueError("clipboard state change was not acknowledged")


@contextlib.contextmanager
def locked():
    root = Path(os.environ.get("XDG_RUNTIME_DIR", ""))
    if not root.is_absolute():
        raise ValueError("private runtime directory required")
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    fd = None
    try:
        metadata = os.fstat(directory)
        if metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
            raise ValueError("unsafe runtime directory")
        fd = os.open("myhypr-clipboard-policy.lock", os.O_RDWR | os.O_CREAT |
                     os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=directory)
        metadata = os.fstat(fd)
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
                or metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) != 0o600):
            raise ValueError("unsafe clipboard policy lock")
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        if fd is not None:
            os.close(fd)
        os.close(directory)


def items():
    # Always inventory every category, including pinned images. Query limits
    # are deliberately above the configured 1000 entries and common legacy stores.
    # Elephant 2.22.1's CLI crashes on empty-result frames. Use our framed
    # query reader so an empty store does not leave collection paused.
    response = command(sys.executable, str(Path(__file__).with_name("elephant-query.py")), "10000")
    result = []
    for line in response.splitlines():
        entry = json.loads(line).get("item")
        if not entry:
            continue
        if entry.get("provider") != "clipboard" or not re.fullmatch(
                r"[a-zA-Z0-9_-]+", entry.get("identifier", "")):
            raise ValueError("invalid clipboard response")
        result.append(entry)
    if len(result) >= 10000:
        raise ValueError("clipboard inventory limit reached")
    return result


def remove(entry):
    identifier = entry["identifier"]
    if "pinned" in entry.get("state", []):
        activate("unpin", identifier)
    activate("remove", identifier)


def expired(entry, now):
    timestamp = parsedate_to_datetime(entry.get("subtext", ""))
    if timestamp is None or timestamp.tzinfo is None:
        raise ValueError("invalid clipboard timestamp")
    return (now - timestamp).total_seconds() >= RETENTION_SECONDS


def maintain(wipe=False):
    states = provider_state()
    mode = next(mode for mode in MODES if mode in states)
    paused = "paused" in states
    set_state("pause")
    # On failure, leave collection paused. Never claim a completed privacy wipe
    # or immediately recapture the still-sensitive active selection.
    set_state("show_combined")
    if wipe:
        failures = []
        for arguments in (("wl-copy", "--clear"), ("wl-copy", "--primary", "--clear")):
            try:
                command(*arguments)
            except (OSError, subprocess.SubprocessError) as error:
                failures.append(error)
    else:
        failures = []
    now = datetime.now(timezone.utc)
    for entry in items():
        if not wipe and not expired(entry, now):
            continue
        remove(entry)
    # Activate requests may be dispatched asynchronously. Observe completion
    # instead of treating a successful CLI send as evidence of deletion.
    for _ in range(20):
        remaining = items()
        if not any(wipe or expired(entry, now) for entry in remaining):
            break
        time.sleep(0.025)
    else:
        raise ValueError("clipboard history remains")
    if failures:
        raise ValueError("active clipboard could not be cleared")
    set_state(mode)
    if not paused:
        set_state("unpause")


def main(arguments):
    if len(arguments) != 1 or arguments[0] not in {"wipe", "expire", "pause", "resume", "watch"}:
        raise ValueError("expected wipe, expire, pause, resume, or watch")
    action = arguments[0]
    if action == "watch":
        # A broken storage boundary must stop the worker, so its parent stops
        # the collector rather than running indefinitely without expiry.
        with locked():
            pass
        # Run under Elephant's service/fallback lifetime. No clipboard data is
        # written by this worker, including on provider failures.
        failed = False
        while True:
            time.sleep(30)
            try:
                with locked():
                    maintain()
                failed = False
            except (OSError, ValueError, TypeError, subprocess.SubprocessError):
                if not failed:
                    print("Clipboard expiry failed; collection may be paused. Check Elephant before resuming.",
                          file=sys.stderr)
                failed = True
    with locked():
        if action in {"pause", "resume"}:
            set_state("pause" if action == "pause" else "unpause")
        else:
            maintain(wipe=action == "wipe")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        print("Clipboard privacy action failed; collection may be paused. Check Elephant before resuming.",
              file=sys.stderr)
        sys.exit(1)
