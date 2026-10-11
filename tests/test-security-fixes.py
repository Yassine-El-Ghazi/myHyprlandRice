#!/usr/bin/env python3
"""Exercise privacy boundaries with synthetic provider state and disposable homes."""

import contextlib
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import tomllib
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[1]
BIN = REPO / "dotfiles/.config/myhypr/bin"


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), BIN / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


idle = load("idle-control")
clipboard = load("clipboard-control")
history = load("shell-history")


class IdleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="myhypr-idle-privacy-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.runtime = self.root / "run"
        self.runtime.mkdir(mode=0o700)
        self.env = patch.dict(os.environ, {"XDG_RUNTIME_DIR": str(self.runtime),
                                          "HYPRLAND_INSTANCE_SIGNATURE": "first", "WAYLAND_DISPLAY": "wayland-1"})
        self.env.start()
        self.addCleanup(self.env.stop)

    def run_action(self, action):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            result = idle.main([action])
        return result, output.getvalue()

    def test_toggle_keeps_daemon_and_lock_path_enabled(self):
        with patch.object(idle, "daemon_pids", return_value=[100]), patch.object(
                idle, "restart_daemon") as restart, patch.object(idle.subprocess, "run") as run:
            result, output = self.run_action("toggle")
            self.assertEqual(result, 0)
            self.assertEqual(json.loads(output)["text"], "PRESENTING")
            for action in ("dim", "display-off", "suspend"):
                self.assertEqual(self.run_action(action)[0], 0)
            run.assert_not_called()
            restart.assert_not_called()
        config = (REPO / "dotfiles/.config/hypr/hypridle.conf").read_text()
        self.assertIn("inhibit_sleep = 3", config)
        self.assertIn("timeout = 300", config)
        self.assertIn("on-timeout = loginctl lock-session", config)
        self.assertIn("before_sleep_cmd = loginctl lock-session", config)

    def test_presentation_is_bounded_and_session_local(self):
        with patch.object(idle, "daemon_pids", return_value=[100]):
            self.run_action("toggle")
            with patch.dict(os.environ, {"HYPRLAND_INSTANCE_SIGNATURE": "second"}):
                with idle.state() as fd:
                    self.assertFalse(idle.presentation(fd))
            with idle.state() as fd:
                self.assertTrue(idle.presentation(fd))
                idle.write_deadline(fd, time.monotonic() - 1)
            with patch.object(idle.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
                self.run_action("dim")
                run.assert_called_once_with(["brightnessctl", "-s", "set", "10"], check=False)
            with idle.state() as fd:
                idle.write_deadline(fd, "nan")
                self.assertFalse(idle.presentation(fd))

    def test_daemon_identity_requires_both_session_identifiers(self):
        proc = self.root / "proc"
        for number, signature, display in ((101, "first", "wayland-1"), (102, "second", "wayland-2"),
                                            (103, "first", "wayland-2")):
            process = proc / str(number)
            process.mkdir(parents=True)
            (process / "comm").write_text("hypridle\n")
            (process / "environ").write_bytes(
                f"HYPRLAND_INSTANCE_SIGNATURE={signature}\0WAYLAND_DISPLAY={display}\0".encode())
        real_path = Path
        with patch.object(idle, "Path", side_effect=lambda path: proc if path == "/proc" else real_path(path)):
            self.assertEqual(idle.daemon_pids(), [101])

    def test_private_state_rejects_links_and_shared_files(self):
        name = "myhypr-idle-" + hashlib.sha256(b"first\0wayland-1").hexdigest()
        target = self.runtime / name
        outside = self.root / "unrelated"
        outside.write_text("untouched")
        for kind in ("symlink", "hardlink", "fifo"):
            with self.subTest(kind=kind):
                if kind == "symlink":
                    target.symlink_to(outside)
                elif kind == "hardlink":
                    os.link(outside, target)
                else:
                    os.mkfifo(target)
                with self.assertRaises((OSError, ValueError)):
                    with idle.state():
                        pass
                target.unlink()
                self.assertEqual(outside.read_text(), "untouched")

    def test_missing_daemon_is_visible(self):
        with patch.object(idle, "daemon_pids", return_value=[]):
            self.assertEqual(json.loads(self.run_action("status")[1])["text"], "ERROR")
        with patch.object(idle, "daemon_pids", return_value=[]), patch.object(
                idle.subprocess, "Popen"), patch.object(idle.time, "sleep"):
            with self.assertRaises(ValueError):
                self.run_action("toggle")
            with idle.state() as fd:
                self.assertFalse(idle.presentation(fd))

    def test_display_off_uses_the_typed_dispatcher(self):
        with patch.object(idle.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
            self.run_action("display-off")
            run.assert_called_once_with(["hyprctl", "dispatch", "hl.dsp.dpms({ action = 'off' })"], check=False)


class ClipboardTests(unittest.TestCase):
    def setUp(self):
        self.entries = {}
        self.mode = "show_pinned_only"
        self.paused = False
        self.calls = []
        self.fail_action = None
        self.leave_entry = False
        self.patch = patch.object(clipboard, "command", side_effect=self.provider)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def entry(self, identifier, *, pinned=False, age=0, image=False):
        entry = {"identifier": identifier, "provider": "clipboard", "text": "synthetic text",
                 "state": ["pinned"] if pinned else [],
                 "subtext": format_datetime(datetime.now(timezone.utc) - timedelta(seconds=age))}
        if image:
            entry["preview"] = "synthetic image"
        self.entries[identifier] = entry

    def provider(self, *arguments):
        self.calls.append(arguments)
        if arguments[0] == "wl-copy":
            if self.fail_action == "wl-copy":
                raise subprocess.CalledProcessError(1, arguments)
            return ""
        if arguments[1] == "state":
            return json.dumps({"states": [self.mode, "paused" if self.paused else "unpaused"]})
        if arguments[1] == "query":
            values = list(self.entries.values())
            if self.mode == "show_pinned_only":
                values = [entry for entry in values if "pinned" in entry["state"]]
            return "\n".join(json.dumps({"item": entry}) for entry in values)
        _, identifier, action, _, _ = arguments[2].split(";")
        if action == self.fail_action:
            raise subprocess.CalledProcessError(1, arguments)
        if action == "pause":
            self.paused = True
        elif action == "unpause":
            self.paused = False
        elif action in clipboard.MODES:
            self.mode = action
        elif action == "unpin":
            self.entries[identifier]["state"] = []
        elif action == "remove" and not self.leave_entry:
            del self.entries[identifier]
        return ""

    def test_wipe_removes_pinned_text_images_and_both_active_selections(self):
        self.entry("plain")
        self.entry("pinned_text", pinned=True)
        self.entry("pinned_image", pinned=True, image=True)
        clipboard.maintain(wipe=True)
        self.assertEqual(self.entries, {})
        self.assertFalse(self.paused)
        self.assertEqual(self.mode, "show_pinned_only")
        self.assertIn(("wl-copy", "--clear"), self.calls)
        self.assertIn(("wl-copy", "--primary", "--clear"), self.calls)

    def test_expiry_removes_old_images_and_pins_but_keeps_recent_entries(self):
        self.entry("recent", age=10)
        self.entry("old", age=400)
        self.entry("old_image", age=400, pinned=True, image=True)
        clipboard.maintain()
        self.assertEqual(set(self.entries), {"recent"})
        self.assertFalse(any(call[0] == "wl-copy" for call in self.calls))
        self.assertFalse(self.paused)

    def test_previous_pause_is_preserved(self):
        self.paused = True
        clipboard.maintain(wipe=True)
        self.assertTrue(self.paused)

    def test_provider_or_active_selection_failure_stays_paused(self):
        for action in ("remove", "wl-copy"):
            with self.subTest(action=action):
                self.entries.clear()
                self.entry("private", pinned=True)
                self.fail_action = action
                self.paused = False
                with self.assertRaises((ValueError, subprocess.SubprocessError)):
                    clipboard.maintain(wipe=True)
                self.assertTrue(self.paused)

    def test_success_exit_without_removal_is_not_accepted(self):
        self.entry("retained", age=400)
        self.leave_entry = True
        with self.assertRaises(ValueError):
            clipboard.maintain(wipe=True)
        self.assertTrue(self.paused)

    def test_malformed_identifiers_are_never_activated(self):
        self.entry("bad;copy", age=400)
        with self.assertRaises(ValueError):
            clipboard.maintain(wipe=True)
        self.assertFalse(any("bad;copy" in " ".join(call) for call in self.calls))

    def test_collection_pause_is_acknowledged_before_deletion(self):
        self.entry("retained")
        original = self.provider
        def ignored_pause(*arguments):
            if arguments == ("elephant", "activate", "clipboard;;pause;;"):
                return ""
            return original(*arguments)
        with patch.object(clipboard, "command", side_effect=ignored_pause), patch.object(clipboard.time, "sleep"):
            with self.assertRaises(ValueError):
                clipboard.maintain(wipe=True)
        self.assertIn("retained", self.entries)
        self.assertFalse(any(call[0] == "wl-copy" for call in self.calls))

    def test_retention_policy_uses_image_aware_expiry(self):
        policy = tomllib.loads((REPO / "dotfiles/.config/elephant/clipboard.toml").read_text())
        self.assertEqual(policy["max_items"], 20)
        self.assertEqual(policy["auto_cleanup"], 0)
        self.assertEqual(clipboard.RETENTION_SECONDS, 300)
        service = (REPO / "dotfiles/.config/systemd/user/elephant.service").read_text()
        self.assertIn("ExecStart=/usr/bin/python3 %h/.config/myhypr/bin/elephant-storage.py --fallback", service)


class HistoryTests(unittest.TestCase):
    def test_existing_history_is_private_and_content_is_preserved(self):
        with tempfile.TemporaryDirectory(prefix="myhypr-history-") as root:
            path = Path(root) / "history"
            path.write_text("synthetic history\n")
            path.chmod(0o644)
            history.protect(str(path))
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.read_text(), "synthetic history\n")

    def test_shared_history_is_rejected_without_changing_target(self):
        with tempfile.TemporaryDirectory(prefix="myhypr-history-") as root:
            source = Path(root) / "unrelated"
            source.write_text("untouched")
            source.chmod(0o644)
            path = Path(root) / "history"
            for kind in ("symlink", "hardlink", "fifo"):
                with self.subTest(kind=kind):
                    if kind == "symlink":
                        path.symlink_to(source)
                    elif kind == "hardlink":
                        os.link(source, path)
                    else:
                        os.mkfifo(path)
                    with self.assertRaises((OSError, ValueError)):
                        history.protect(str(path))
                    path.unlink()
                    self.assertEqual(source.stat().st_mode & 0o777, 0o644)

    def test_shell_history_settings(self):
        for shell, location in (("bash", "bashrc/05-history"), ("zsh", "zshrc/05-history")):
            with self.subTest(shell=shell), tempfile.TemporaryDirectory(prefix="myhypr-shell-history-") as root:
                home = Path(root)
                tools = home / ".config/myhypr/bin"
                tools.mkdir(parents=True)
                (tools / "shell-history.py").symlink_to(BIN / "shell-history.py")
                module = REPO / "dotfiles/.config" / location
                check = ('[[ $HISTCONTROL == ignoreboth && $(umask) == 0077 ]]' if shell == "bash" else
                         '[[ -o hist_ignore_space && -o hist_save_by_copy && $(umask) == 077 ]]')
                result = subprocess.run([shell, "-c", 'source "$MODULE"; ' + check],
                                        env={"HOME": root, "PATH": "/usr/bin:/bin", "MODULE": str(module)},
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((home / f".{shell}_history").stat().st_mode & 0o777, 0o600)

    def test_fish_excludes_leading_space_and_uses_private_history(self):
        with tempfile.TemporaryDirectory(prefix="myhypr-fish-history-") as root:
            home = Path(root)
            tools = home / ".config/myhypr/bin"
            tools.mkdir(parents=True)
            (tools / "shell-history.py").symlink_to(BIN / "shell-history.py")
            result = subprocess.run(["fish", "--no-config", "-i", "-c",
                                     'source "$MODULE"; fish_should_add_to_history " public"; '
                                     'test $status -ne 0; and fish_should_add_to_history "public"'],
                                    env={"HOME": root, "PATH": "/usr/bin:/bin", "TERM": "xterm",
                                         "MODULE": str(REPO / "dotfiles/.config/fish/conf.d/05-history.fish")},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((home / ".local/share/fish/fish_history").stat().st_mode & 0o777, 0o600)


class CollectorTests(unittest.TestCase):
    def run_collector(self, unsafe_runtime=False):
        temporary = tempfile.TemporaryDirectory(prefix="myhypr-collector-lifetime-", dir="/tmp")
        self.addCleanup(temporary.cleanup)
        home = Path(temporary.name)
        tools = home / "bin"
        tools.mkdir()
        runtime = home / "run"
        runtime.mkdir(mode=0o700)
        if unsafe_runtime:
            runtime.chmod(0o777)
        marker = home / "collector.pid"
        tool = tools / "elephant"
        tool.write_text('#!/usr/bin/python3\nimport os, pathlib, time\n'
                        'pathlib.Path(os.environ["COLLECTOR_PID"]).write_text(str(os.getpid()))\n'
                        'time.sleep(30)\n')
        tool.chmod(0o700)
        process = subprocess.Popen(["/usr/bin/python3", str(BIN / "elephant-storage.py"), "--fallback"],
                                   env={"HOME": str(home), "PATH": f"{tools}:/usr/bin:/bin",
                                        "XDG_RUNTIME_DIR": str(runtime), "COLLECTOR_PID": str(marker)},
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   start_new_session=True)
        def cleanup():
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate(timeout=5)
        self.addCleanup(cleanup)
        deadline = time.monotonic() + 5
        while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(marker.exists(), "synthetic collector did not start")
        return process, int(marker.read_text())

    def test_stopping_wrapper_stops_and_reaps_collector(self):
        process, collector = self.run_collector()
        process.terminate()
        process.communicate(timeout=5)
        with self.assertRaises(ProcessLookupError):
            os.kill(collector, 0)

    def test_expiry_worker_failure_stops_collection(self):
        process, collector = self.run_collector(unsafe_runtime=True)
        _, error = process.communicate(timeout=5)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("clipboard retention worker stopped", error)
        with self.assertRaises(ProcessLookupError):
            os.kill(collector, 0)


if __name__ == "__main__":
    unittest.main()
