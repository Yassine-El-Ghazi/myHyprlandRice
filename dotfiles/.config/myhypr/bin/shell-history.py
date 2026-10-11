#!/usr/bin/python3
"""Restrict a history file without following links or modifying shared inodes."""

import os
from pathlib import Path
import stat
import sys


def protect(raw):
    path = Path(raw)
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("history path must be absolute")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        root_owner = os.fstat(fd).st_uid
        for component in path.parts[1:-1]:
            try:
                os.mkdir(component, 0o700, dir_fd=fd)
            except FileExistsError:
                pass
            next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
            metadata = os.fstat(fd)
            if metadata.st_uid not in {root_owner, os.geteuid()} or (
                    metadata.st_mode & 0o022 and not (
                        metadata.st_uid == root_owner and metadata.st_mode & stat.S_ISVTX)):
                raise ValueError("unsafe history ancestor")
        history = os.open(path.name, os.O_RDONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                          0o600, dir_fd=fd)
        try:
            metadata = os.fstat(history)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() or metadata.st_nlink != 1:
                raise ValueError("unsafe history file")
            os.fchmod(history, 0o600)
        finally:
            os.close(history)
    finally:
        os.close(fd)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("expected history file")
        protect(sys.argv[1])
    except (OSError, ValueError):
        print("Shell history disabled: its storage could not be made private.", file=sys.stderr)
        sys.exit(1)
