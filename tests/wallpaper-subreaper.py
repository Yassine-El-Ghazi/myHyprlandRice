#!/usr/bin/env python3
"""Exercise wallpaper shutdown with an exited worker deliberately left unreaped."""

import ctypes
import os
from pathlib import Path
import subprocess
import sys

libc = ctypes.CDLL(None, use_errno=True)
if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
    raise OSError(ctypes.get_errno(), "Cannot enable test subreaper")

result = subprocess.run(
    ["bash", str(Path(__file__).with_name("test-wallpaper-automation.sh")),
     "--subreaper"], check=False,
)
# Only the shell test was waited for above. Its orphaned worker must remain a
# zombie until now, just as with the CI container's non-reaping tail PID 1.
reaped = 0
while True:
    try:
        pid, _ = os.waitpid(-1, os.WNOHANG)
    except ChildProcessError:
        break
    if pid == 0:
        raise RuntimeError("Wallpaper test left a live adopted child")
    reaped += 1
if result.returncode == 0 and reaped == 0:
    raise RuntimeError("Test did not exercise an unreaped worker")
sys.exit(result.returncode)
