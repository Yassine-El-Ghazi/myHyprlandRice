#!/usr/bin/python3
"""Prepare private Elephant storage and bound fallback diagnostics."""

import fcntl
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys


DIRECTORY = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
LIMIT = 1024 * 1024


def private_directory(path):
    """Walk without following links, then restrict only the requested directory."""
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('storage path must be absolute without parent traversal')
    fd = os.open('/', DIRECTORY)
    try:
        for part in path.parts[1:]:
            try:
                os.mkdir(part, 0o700, dir_fd=fd)
            except FileExistsError:
                pass
            next_fd = os.open(part, DIRECTORY, dir_fd=fd)
            os.close(fd)
            fd = next_fd
            metadata = os.fstat(fd)
            sticky_root = metadata.st_uid == 0 and metadata.st_mode & stat.S_ISVTX
            if metadata.st_uid not in (0, os.geteuid()) or (
                metadata.st_mode & 0o022 and not sticky_root
            ):
                raise ValueError('storage ancestor ownership or permissions are unsafe')
        if os.fstat(fd).st_uid != os.geteuid():
            raise ValueError('storage directory is not owned by this user')
        os.fchmod(fd, 0o700)
        return fd
    except BaseException:
        os.close(fd)
        raise


def private_contents(directory):
    """Repair legacy permissions; reject links, shared files, and special files."""
    for name in os.listdir(directory):
        metadata = os.stat(name, dir_fd=directory, follow_symlinks=False)
        if metadata.st_uid != os.geteuid():
            raise ValueError('cache entry is not owned by this user')
        if stat.S_ISDIR(metadata.st_mode):
            fd = os.open(name, DIRECTORY, dir_fd=directory)
            try:
                if os.fstat(fd).st_uid != os.geteuid():
                    raise ValueError('cache directory changed owner')
                os.fchmod(fd, 0o700)
                private_contents(fd)
            finally:
                os.close(fd)
        elif stat.S_ISREG(metadata.st_mode):
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
            try:
                actual = os.fstat(fd)
                if not stat.S_ISREG(actual.st_mode) or actual.st_uid != os.geteuid() or actual.st_nlink != 1:
                    raise ValueError('cache file is shared or unsafe')
                os.fchmod(fd, 0o600)
            finally:
                os.close(fd)
        else:
            raise ValueError('cache contains a link or special file')


def open_log(directory, name):
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK,
                 0o600, dir_fd=directory)
    metadata = os.fstat(fd)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() or metadata.st_nlink != 1:
        os.close(fd)
        raise ValueError('diagnostic log is shared or unsafe')
    os.fchmod(fd, 0o600)
    return fd


def rotate_log(directory, fd):
    os.close(fd)
    os.replace('elephant.log', 'elephant.log.1', src_dir_fd=directory, dst_dir_fd=directory)
    return open_log(directory, 'elephant.log')


def fallback():
    root = Path(os.environ.get('XDG_STATE_HOME') or str(Path.home() / '.local/state'))
    directory = private_directory(root / 'myhypr')
    fd = None
    lock = None
    try:
        lock = open_log(directory, 'elephant.lock')
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            # Another fallback owns the collector and diagnostic rotation.
            return 0
        # Validate both names before any rename or launch, including existing logs.
        for name in ('elephant.log.1', 'elephant.log'):
            checked = open_log(directory, name)
            os.close(checked)
        fd = open_log(directory, 'elephant.log')
        if os.fstat(fd).st_size > LIMIT:
            os.ftruncate(fd, LIMIT)
        previous = open_log(directory, 'elephant.log.1')
        try:
            if os.fstat(previous).st_size > LIMIT:
                os.ftruncate(previous, LIMIT)
        finally:
            os.close(previous)
        command = shutil.which('elephant')
        if not command:
            raise ValueError('Elephant command is unavailable')
        with subprocess.Popen([command], stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as process:
            while True:
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    break
                if os.fstat(fd).st_size + len(chunk) > LIMIT:
                    fd = rotate_log(directory, fd)
                remaining = memoryview(chunk)
                while remaining:
                    remaining = remaining[os.write(fd, remaining):]
            return process.wait()
    finally:
        if fd is not None:
            os.close(fd)
        if lock is not None:
            os.close(lock)
        os.close(directory)


def main():
    os.umask(0o077)
    if sys.argv[1:] not in (['--prepare'], ['--fallback']):
        raise ValueError('expected --prepare or --fallback')
    root = Path(os.environ.get('XDG_CACHE_HOME') or str(Path.home() / '.cache'))
    directory = private_directory(root / 'elephant')
    try:
        private_contents(directory)
    finally:
        os.close(directory)
    return fallback() if sys.argv[1] == '--fallback' else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        # Do not print filenames or clipboard content in diagnostics.
        reason = str(error) if isinstance(error, ValueError) else type(error).__name__
        print('Elephant private storage preparation failed: ' + reason, file=sys.stderr)
        sys.exit(1)
