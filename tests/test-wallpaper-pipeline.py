#!/usr/bin/env python3
import importlib.util
import contextlib
import fcntl
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
SCRIPTS = REPO / "dotfiles/.config/hypr/scripts"
spec = importlib.util.spec_from_file_location("wallpaper_transaction", SCRIPTS / "wallpaper.py")
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)


class WallpaperPipelineTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="myhypr-pipeline-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.home = self.root / "home"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.scripts = self.home / ".config/hypr/scripts"
        self.scripts.mkdir(parents=True)
        for name in ("wallpaper.sh", "wallpaper.py", "waypaper.sh", "wallpaper-effects.sh",
                     "wallpaper-effect.sh", "wallpaper-restore.sh", "wallpaper-automation.sh"):
            (self.scripts / name).symlink_to(SCRIPTS / name)
        self.config = self.home / ".config"
        self.settings = self.config / "myhypr/settings"
        self.settings.mkdir(parents=True)
        (self.config / "myhypr/library.sh").symlink_to(REPO / "dotfiles/.config/myhypr/library.sh")
        self.folder = self.config / "myhypr/wallpapers"
        self.folder.mkdir()
        self.default = self.folder / "default.jpg"
        self.default.write_bytes(b"default")
        self.image = self.folder / 'space \' " $(touch INJECTED); 雪 \\ test\n.png'
        self.image.write_bytes(b"first")
        self.other = self.folder / "other.png"
        self.other.write_bytes(b"second")
        (self.settings / "wallpaper-effect.sh").write_text("blackwhite")
        self.cache = self.home / ".cache/myhypr/current_wallpaper"
        self.log = self.root / "calls"
        self.active = self.root / "active"
        self.env = {**os.environ, "HOME": str(self.home), "XDG_CONFIG_HOME": str(self.config),
                    "PATH": f"{self.bin}:/usr/bin:/bin", "TEST_LOG": str(self.log),
                    "TEST_ACTIVE": str(self.active), "TEST_IMAGE": str(self.image),
                    "TEST_ROOT": str(self.root)}
        self.tool("awww", """
import json, os, pathlib, sys, time
args = sys.argv[1:]
with open(os.environ["TEST_LOG"], "a") as stream:
    stream.write(json.dumps(["awww", *args]) + "\\n")
if args[0] == "img":
    if os.environ.get("FAIL_BACKEND"):
        sys.exit(7)
    if os.environ.get("BLOCK_BACKEND"):
        root = pathlib.Path(os.environ["TEST_ROOT"])
        (root / "blocked").touch()
        for _ in range(1000):
            if (root / "release").exists():
                break
            time.sleep(0.01)
        else:
            sys.exit(9)
    pathlib.Path(os.environ["TEST_ACTIVE"]).write_bytes(pathlib.Path(args[1]).read_bytes())
""")
        self.tool("magick", """
import json, os, pathlib, sys
with open(os.environ["TEST_LOG"], "a") as stream:
    stream.write(json.dumps(["magick", *sys.argv[1:]]) + "\\n")
source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[-1])
if destination.name == "effect.png" and os.environ.get("FAIL_EFFECT"):
    sys.exit(17)
data = source.read_bytes()
destination.write_bytes(data + (b":effect" if destination.name == "effect.png" else b""))
""")
        self.tool("matugen", """
import json, os, sys
with open(os.environ["TEST_LOG"], "a") as stream:
    stream.write(json.dumps(["matugen", *sys.argv[1:]]) + "\\n")
if sys.argv[-2:] != ["--source-color-index", "0"]:
    sys.exit(23)
sys.exit(8 if os.environ.get("FAIL_MATUGEN") else 0)
""")
        self.tool("rofi", """
import os, pathlib, sys
pathlib.Path(os.environ["TEST_ROOT"], "picker-input").write_bytes(sys.stdin.buffer.read())
print(os.environ.get("PICK_INDEX", "0"))
""")
        self.tool("fzf", """
import os, sys
choices = sys.stdin.buffer.read().split(b"\\0")
selected = os.fsencode(os.environ["TEST_IMAGE"])
if selected not in choices:
    sys.exit(1)
sys.stdout.buffer.write(selected + b"\\0")
""")
        for name in ("notify-send", "pywalfox", "swaync-client"):
            self.tool(name, "")
        for name in ("waybar", "nwg-dock-hyprland"):
            folder = self.config / name
            folder.mkdir()
            launcher = folder / "launch.sh"
            launcher.write_text('#!/bin/sh\n[ -z "$FAIL_PANEL" ]\n')
            launcher.chmod(0o755)
        self.tool("waypaper", """
import json, os, pathlib, subprocess, sys
root = pathlib.Path(os.environ["TEST_ROOT"])
(root / "waypaper-called").touch()
args = sys.argv[1:]
image = args[args.index("--wallpaper") + 1] if "--wallpaper" in args else os.environ["TEST_IMAGE"]
if "--wallpaper" in args:
    (root / "waypaper-saved").write_text(image)
monitors = ("All",) if "--wallpaper" in args else ("DP-1", "DP-2")
for monitor in monitors:
    subprocess.run(["awww", "img", image, "--outputs", monitor], check=False)
if "--wallpaper" not in args:
    (root / "waypaper-saved").write_text(image)
if "--no-post-command" not in args:
    (root / "legacy-callback").touch()
if os.environ.get("SLIDESHOW") and "--restore" in args:
    subprocess.run([sys.executable, __file__, "--random"], check=False)
sys.exit(0)
""")

    def tool(self, name, code):
        path = self.bin / name
        path.write_text("#!/usr/bin/python3\n" + code)
        path.chmod(0o755)

    def command(self, *args, env=None, script="wallpaper.sh"):
        return subprocess.run([str(self.scripts / script), *map(str, args)],
                              env=env or self.env, cwd=self.root, capture_output=True, timeout=15)

    def successful(self, *args, **kwargs):
        result = self.command(*args, **kwargs)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        return self.state()

    def state(self):
        return json.loads(self.cache.read_bytes())

    def calls(self, name=None):
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return [call for call in calls if name is None or call[0] == name]

    def applications(self):
        return [call for call in self.calls("awww") if call[1] == "img"]

    def assert_private_diagnostics(self, result):
        output = result.stdout + result.stderr
        for value in (self.image, self.image.name, self.home, self.cache,
                      self.home / ".cache/myhypr/wallpaper-generated",
                      Path("/home") / "example-private-user/Pictures/private-name.png"):
            self.assertNotIn(os.fsencode(value), output)
            self.assertNotIn(repr(str(value)).encode(), output)
        self.assertNotIn(b"private-name.png", output)

    def noisy_tools(self):
        for name in ("awww", "magick", "matugen"):
            path = self.bin / name
            code = path.read_text()
            path.write_text(code.replace("\n", '\nimport sys\nprint("/home/" + "example-private-user/Pictures/private-name.png")\nprint(repr(sys.argv), file=sys.stderr)\n', 1))
        for name in ("waybar", "nwg-dock-hyprland"):
            launcher = self.config / name / "launch.sh"
            launcher.write_text('#!/bin/sh\nprintf "%s\\n" "$HOME"\nprintf "%s\\n" "$0" >&2\n[ -z "$FAIL_PANEL" ]\n')

    def inprocess_command(self, *arguments):
        output, errors = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, self.env, clear=True), \
                mock.patch.object(engine.sys, "argv", ["wallpaper.sh", *map(str, arguments)]), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            status = engine.main()
        return subprocess.CompletedProcess(arguments, status, output.getvalue().encode(), errors.getvalue().encode())

    def test_success_diagnostics_do_not_disclose_paths_or_child_output(self):
        self.noisy_tools()
        result = self.command(self.image)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"Wallpaper applied successfully.\n")
        self.assertEqual(result.stderr, b"")
        self.assert_private_diagnostics(result)
        self.assertFalse((self.home / ".cache/myhypr/wallpaper-panels.log").exists())

    def test_failure_diagnostics_distinguish_stages_without_paths(self):
        self.noisy_tools()
        for variable, stage in (("FAIL_EFFECT", b"Effect generation failed"),
                                ("FAIL_BACKEND", b"Backend application failed"),
                                ("FAIL_MATUGEN", b"Matugen refresh failed"),
                                ("FAIL_PANEL", b"Waybar refresh failed")):
            with self.subTest(variable=variable):
                result = self.command(self.image, env={**self.env, variable: "1"})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(stage, result.stderr)
                self.assertIn(b"status", result.stderr)
                self.assert_private_diagnostics(result)

    def test_missing_source_and_invalid_values_do_not_echo_private_input(self):
        private = str(Path("/home") / "example-private-user/Pictures/private-name.png")
        for arguments, stage in (((private,), b"Wallpaper source is missing"),
                                 ((str(self.image), "--effect", private), b"Unsupported wallpaper effect"),
                                 (("--unsupported-option", private), b"invalid arguments")):
            with self.subTest(stage=stage):
                result = self.command(*arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(stage, result.stderr)
                self.assert_private_diagnostics(result)

    def test_verbose_diagnostics_require_explicit_opt_in(self):
        self.noisy_tools()
        result = self.command(self.image, "--verbose", env={**self.env, "FAIL_BACKEND": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"private-name.png", result.stderr)
        self.assertIn(b"Backend application failed", result.stderr)
        self.assertIn(b"Traceback", result.stderr)

    def test_verbose_dock_log_is_opt_in_and_user_only(self):
        self.noisy_tools()
        result = self.command(self.image, "--verbose")
        self.assertEqual(result.returncode, 0)
        log = self.home / ".cache/myhypr/wallpaper-panels.log"
        self.assertIn(os.fsencode(self.home), log.read_bytes())
        self.assertEqual(log.stat().st_mode & 0o777, 0o600)

    def test_filesystem_and_publication_errors_do_not_render_exception_paths(self):
        private = str(Path("/home") / "example-private-user/Pictures/private-name.png")
        before = self.successful(self.image)
        for method, stage in (("read_state", b"Wallpaper state access failed"),
                              ("prepare_state", b"State preparation failed")):
            with self.subTest(method=method), mock.patch.object(
                    engine.Wallpaper, method, side_effect=PermissionError(13, private, private)):
                result = self.inprocess_command(self.other)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(stage, result.stderr)
                self.assertIn(b"Permission denied", result.stderr)
                self.assert_private_diagnostics(result)
        replace = engine.os.replace

        def fail_publication(source, destination):
            if Path(destination) == self.cache:
                raise PermissionError(13, private, private)
            return replace(source, destination)

        with mock.patch.object(engine.os, "replace", fail_publication):
            result = self.inprocess_command(self.other)
        self.assertIn(b"State publication failed", result.stderr)
        self.assert_private_diagnostics(result)
        self.assertEqual(self.state(), before)
        self.assertEqual(self.active.read_bytes(), b"first:effect")

    def test_timeout_diagnostics_do_not_echo_command_or_output(self):
        private = str(Path("/home") / "example-private-user/Pictures/private-name.png")
        run = engine.subprocess.run

        def timeout(arguments, **kwargs):
            if arguments[0] == "timeout" and "img" in arguments:
                raise subprocess.TimeoutExpired([private], 30, output=private, stderr=private)
            return run(arguments, **kwargs)

        with mock.patch.object(engine.subprocess, "run", timeout):
            result = self.inprocess_command(self.image)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"Backend application failed (timed out)", result.stderr)
        self.assert_private_diagnostics(result)
        self.assertFalse(self.cache.exists())

    def test_post_commit_sync_failure_reports_committed_state_without_paths(self):
        private = str(Path("/home") / "example-private-user/Pictures/private-name.png")
        fsync = engine.os.fsync

        def failed_sync(descriptor):
            if os.readlink(f"/proc/self/fd/{descriptor}") == str(self.cache.parent):
                raise OSError(5, private, private)
            return fsync(descriptor)

        with mock.patch.object(engine.os, "fsync", failed_sync):
            result = self.inprocess_command(self.image)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"state is committed", result.stderr)
        self.assertIn(b"directory sync failed", result.stderr)
        self.assert_private_diagnostics(result)
        self.assertEqual(self.state()["original"], str(self.image))
        self.assertEqual(self.active.read_bytes(), b"first:effect")
        self.assertFalse(self.calls("matugen"))
        self.successful("--restore")

    def test_effect_listing_and_empty_folder_diagnostics_do_not_echo_paths(self):
        helper = self.scripts / "wallpaper-effect.sh"
        helper.unlink()
        helper.write_text('#!/bin/sh\nprintf "%s\\n" "$HOME" >&2\nexit 9\n')
        helper.chmod(0o755)
        result = self.command(self.image)
        self.assertIn(b"Effect listing failed (exit status 9)", result.stderr)
        self.assert_private_diagnostics(result)
        (self.settings / "wallpaper-folder").write_text(str(Path("/home") / "example-private-user/Pictures"))
        result = self.command("--pick")
        self.assertIn(b"No supported wallpaper images found", result.stderr)
        self.assert_private_diagnostics(result)
        (self.settings / "wallpaper-folder").unlink()
        with mock.patch.object(engine.subprocess, "run", side_effect=FileNotFoundError(2, "picker unavailable")):
            result = self.inprocess_command("--pick")
        self.assertIn(b"Wallpaper picker failed", result.stderr)
        self.assert_private_diagnostics(result)

    def test_malformed_state_and_recovery_warning_do_not_echo_content(self):
        self.cache.parent.mkdir(parents=True)
        for content in (b"[" * 2000, b'{"private":"/home/' + b'example-private-user/Pictures/private-name.png"}'):
            self.cache.write_bytes(content)
            result = self.command("--restore")
            self.assertNotEqual(result.returncode, 0)
            self.assert_private_diagnostics(result)
            self.assertNotIn(b"Traceback", result.stderr)
        result = self.command(self.image)
        self.assertEqual(result.returncode, 0)
        self.assertIn(b"Ignoring invalid wallpaper state", result.stderr)
        self.assert_private_diagnostics(result)

    def test_interruption_diagnostics_do_not_print_tracebacks_by_default(self):
        with mock.patch.object(engine.Wallpaper, "transition", side_effect=KeyboardInterrupt):
            result = self.inprocess_command(self.image)
        self.assertEqual(result.returncode, 130)
        self.assertIn(b"interrupted", result.stderr)
        self.assertNotIn(b"Traceback", result.stderr)
        self.assert_private_diagnostics(result)

    def test_selection_prepares_effect_before_one_global_application(self):
        state = self.successful(self.image)
        self.assertEqual(os.fsencode(state["original"]), os.fsencode(self.image))
        self.assertEqual(self.active.read_bytes(), b"first:effect")
        self.assertEqual(self.applications(), [["awww", "img", state["applied"]]])
        self.assertEqual(len(self.calls("matugen")), 1)
        self.assertLess(self.calls().index(self.calls("magick")[0]), self.calls().index(self.applications()[0]))
        self.assertFalse((self.root / "INJECTED").exists())

    def test_filename_bytes_round_trip_and_restore(self):
        names = ["spaces and 'quotes\".png", "$(touch INJECTED); 雪 \\ literal.png",
                 "embedded\nnewline.png", "trailing.png\n\n", "%[0]\t.png",
                 os.fsdecode(b"nonutf8-\xff.png")]
        for name in names:
            with self.subTest(name=repr(name)):
                image = self.folder / name
                image.write_bytes(os.fsencode(name))
                state = self.successful(image, "--effect", "off")
                self.assertEqual(os.fsencode(state["original"]), os.fsencode(image))
                self.successful("--restore")
                self.assertEqual(os.fsencode(self.state()["original"]), os.fsencode(image))
                self.assertEqual(self.active.read_bytes(), os.fsencode(name))

    def test_retired_adapter_in_path_and_symlink_are_skipped(self):
        adapter = self.scripts / "wallpaper-backend"
        adapter.mkdir()
        trap = adapter / "awww"
        trap.write_text("#!/bin/sh\nexit 99\n")
        trap.chmod(0o755)
        alias = self.root / "adapter-alias"
        alias.symlink_to(adapter)
        self.successful(self.image, env={**self.env, "PATH": f"{adapter}:{alias}:{self.env['PATH']}"})
        self.assertEqual(len(self.applications()), 1)

    def test_backend_symlink_to_transaction_cannot_recurse(self):
        alternate = self.root / "real-bin"
        alternate.mkdir()
        (self.bin / "awww").rename(alternate / "awww")
        (self.bin / "awww").symlink_to(self.scripts / "wallpaper.sh")
        self.successful(self.image, env={**self.env, "PATH": f"{self.bin}:{alternate}:/usr/bin:/bin"})
        self.assertEqual(len(self.applications()), 1)

    def test_absolute_path_spelling_round_trips(self):
        spelling = str(self.folder) + "/./" + self.image.name
        state = self.successful(spelling)
        self.assertEqual(os.fsencode(state["original"]), os.fsencode(spelling))
        self.successful("--restore")
        self.assertEqual(os.fsencode(self.state()["original"]), os.fsencode(spelling))

    def test_newline_name_uses_image_header_for_safe_snapshot_extension(self):
        image = self.folder / "jpeg image\n\n"
        image.write_bytes(b"\xff\xd8\xffdata")
        state = self.successful(image, "--effect", "off")
        self.assertTrue(state["applied"].endswith(".jpg"))
        self.assertEqual(self.active.read_bytes(), image.read_bytes())

    def test_effect_generation_failure_never_applies_or_advances(self):
        before = self.successful(self.other)
        count = len(self.applications())
        result = self.command(self.image, env={**self.env, "FAIL_EFFECT": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.state(), before)
        self.assertEqual(len(self.applications()), count)
        self.assertEqual(self.active.read_bytes(), b"second:effect")
        self.assertEqual(len(self.calls("matugen")), 1)

    def test_effect_change_preference_commits_only_after_application(self):
        before = self.successful(self.image, "--effect", "off")
        result = self.command("--effect", "blackwhite", env={**self.env, "FAIL_EFFECT": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.state(), before)
        result = self.command("--effect", "blackwhite", env={**self.env, "FAIL_BACKEND": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.state(), before)
        after = self.successful("--effect", "blackwhite")
        self.assertEqual(after["effect"], "blackwhite")
        self.assertEqual(after["original"], before["original"])

    def test_failed_backend_and_untrusted_waypaper_state_cannot_trick_restore(self):
        before = self.successful(self.image)
        result = self.command(self.other, env={**self.env, "FAIL_BACKEND": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.state(), before)
        self.assertEqual(len(self.calls("matugen")), 1)
        config = self.config / "waypaper/config.ini"
        config.parent.mkdir()
        config.write_text("[Settings]\nwallpaper = " + str(self.other) + "\npost_command = old callback\n")
        self.successful("--restore", script="wallpaper-restore.sh")
        self.assertEqual(self.state()["original"], str(self.image))
        self.assertFalse((self.root / "waypaper-called").exists())

    def test_bootstrap_uses_default_not_waypaper(self):
        config = self.config / "waypaper/config.ini"
        config.parent.mkdir()
        config.write_text("[Settings]\nwallpaper = unverified.png\npost_command = old callback\n")
        state = self.successful("--restore", script="wallpaper-restore.sh")
        self.assertEqual(state["original"], str(self.default))

    def test_restore_reuses_committed_snapshot_after_source_disappears(self):
        before = self.successful(self.image)
        self.image.unlink()
        self.successful("--restore", script="wallpaper-restore.sh")
        self.assertEqual(self.state(), before)
        self.assertEqual(self.active.read_bytes(), b"first:effect")

    def test_real_image_preparation_is_safe_without_a_desktop(self):
        real_magick = shutil.which("magick", path="/usr/bin:/bin")
        if real_magick is None:
            self.skipTest("ImageMagick is not installed")
        image = subprocess.run([real_magick, "-size", "2x2", "xc:red", "png:-"],
                               check=True, capture_output=True).stdout
        self.image.write_bytes(image)
        (self.bin / "magick").unlink()
        (self.bin / "magick").symlink_to(real_magick)
        state = self.successful(self.image)
        self.assertTrue(self.active.read_bytes().startswith(b"\x89PNG"))
        self.assertNotEqual(Path(state["applied"]).read_bytes(), image)

    def test_post_apply_failures_keep_state_and_can_refresh(self):
        for variable in ("FAIL_MATUGEN", "FAIL_PANEL"):
            with self.subTest(variable=variable):
                result = self.command(self.image, env={**self.env, variable: "1"})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b"state is committed", result.stderr)
                self.assertEqual(self.state()["original"], str(self.image))
                self.assertEqual(self.active.read_bytes(), b"first:effect")
                count = len(self.applications())
                self.successful("--refresh")
                self.assertEqual(len(self.applications()), count)

    def test_all_wallpaper_actions_choose_the_legacy_dominant_source_color(self):
        self.successful(script="waypaper.sh")
        self.successful("--effect", "off")
        self.successful("reload", script="wallpaper-effects.sh")
        self.successful(script="wallpaper-restore.sh")
        self.successful("--refresh")
        self.successful("--random")
        self.assertEqual(len(self.calls("matugen")), 6)
        for call in self.calls("matugen"):
            self.assertEqual(call[-2:], ["--source-color-index", "0"])
            self.assertTrue(Path(call[2]).is_relative_to(self.home / ".cache/myhypr/wallpaper-generated"))

    def test_matugen_and_transaction_helpers_have_no_interactive_stdin(self):
        with mock.patch.object(engine.subprocess, "run", wraps=engine.subprocess.run) as run:
            result = self.inprocess_command(self.image)
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = [call for call in run.call_args_list if call.args[0][0] == "timeout"]
        self.assertTrue(commands)
        self.assertTrue(any("matugen" in call.args[0] for call in commands))
        for call in commands:
            self.assertEqual(call.kwargs.get("stdin"), subprocess.DEVNULL)

    def test_gtk_listener_uses_the_same_noninteractive_refresh_without_reapplication(self):
        self.successful(self.image)
        applications = len(self.applications())
        gtk = self.config / "gtk-3.0"
        gtk.mkdir()
        (gtk / "settings.ini").write_text("gtk-application-prefer-dark-theme=0\n")
        toolkit = self.scripts / "gtk.sh"
        toolkit.write_text('#!/bin/sh\nprintf "%s\\n" "$HOME"\n')
        toolkit.chmod(0o755)
        self.tool("inotifywait", 'print("fixture CLOSE_WRITE settings.ini")\n')
        listener = REPO / "dotfiles/.config/myhypr/listeners/gtk-theme-switcher.sh"
        result = subprocess.run([str(listener)], env=self.env, cwd=self.root,
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls("matugen")), 2)
        self.assertEqual(self.calls("matugen")[-1][-2:], ["--source-color-index", "0"])
        self.assertEqual(len(self.applications()), applications)
        self.assert_private_diagnostics(result)

    def test_installed_matugen_dominant_source_is_noninteractive_without_live_outputs(self):
        real_matugen = shutil.which("matugen", path="/usr/bin:/bin")
        real_magick = shutil.which("magick", path="/usr/bin:/bin")
        if real_matugen is None or real_magick is None:
            self.skipTest("Matugen and ImageMagick are required for the isolated CLI regression")
        help_result = subprocess.run([real_matugen, "image", "--help"], capture_output=True, check=True)
        if b"--source-color-index" not in help_result.stdout:
            self.skipTest("Installed Matugen predates explicit source-color selection")
        image = self.root / "synthetic-palette.png"
        subprocess.run([real_magick, "-size", "120x80", "xc:#e06030", "-fill", "#4060d0",
                        "-draw", "rectangle 0,0 29,79", "-fill", "#209030",
                        "-draw", "rectangle 30,0 49,79", str(image)], check=True, capture_output=True)
        config = self.root / "matugen.toml"
        config.write_text("[config]\n[templates]\n")
        arguments = [real_matugen, "image", str(image), "--config", str(config), "--dry-run"]
        result = subprocess.run([*arguments, "--source-color-index", "0"], env=self.env,
                                stdin=subprocess.DEVNULL, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        version = subprocess.run([real_matugen, "--version"], capture_output=True, check=True).stdout
        if version.strip() == b"matugen 4.2.0":
            result = subprocess.run(arguments, env=self.env, stdin=subprocess.DEVNULL,
                                    capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"source color", (result.stdout + result.stderr).lower())
            config.write_text("[config]\nsource_color_index = 0\n[templates]\n")
            result = subprocess.run(arguments, env=self.env, stdin=subprocess.DEVNULL,
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_failed_state_preparation_preserves_previous_bytes_before_apply(self):
        self.successful(self.image)
        before = self.cache.read_bytes()
        count = len(self.applications())
        real_fsync = engine.os.fsync

        def interrupted(descriptor):
            target = os.readlink(f"/proc/self/fd/{descriptor}")
            if ".wallpaper-state-" in target:
                raise OSError("simulated interrupted state write")
            return real_fsync(descriptor)

        with mock.patch.dict(os.environ, self.env, clear=True), mock.patch.object(engine.os, "fsync", interrupted):
            with self.assertRaisesRegex(engine.WallpaperError, "State preparation failed"):
                engine.Wallpaper().transition(self.other)
        self.assertEqual(self.cache.read_bytes(), before)
        self.assertEqual(len(self.applications()), count)

    def test_readers_observe_only_whole_atomic_states(self):
        self.successful(self.image)
        before = self.cache.read_bytes()
        observed = []
        stop = threading.Event()

        def read():
            while not stop.is_set():
                observed.append(self.cache.read_bytes())
                time.sleep(0.001)

        reader = threading.Thread(target=read)
        reader.start()
        try:
            self.successful(self.other)
        finally:
            stop.set()
            reader.join()
        after = self.cache.read_bytes()
        self.assertTrue(observed)
        self.assertTrue(all(data in (before, after) for data in observed))

    def test_failed_publication_rolls_back_and_releases_lock(self):
        self.successful(self.image)
        before = self.cache.read_bytes()
        real_replace = engine.os.replace

        def failed_publish(source, destination):
            if Path(destination) == self.cache:
                raise OSError("simulated state publication failure")
            return real_replace(source, destination)

        with mock.patch.dict(os.environ, self.env, clear=True), mock.patch.object(engine.os, "replace", failed_publish):
            with self.assertRaisesRegex(engine.WallpaperError, "State publication failed"):
                engine.Wallpaper().transition(self.other)
        self.assertEqual(self.cache.read_bytes(), before)
        self.assertEqual(self.active.read_bytes(), b"first:effect")
        self.successful(self.other)

    def test_long_running_dock_does_not_hold_transaction_lock(self):
        launcher = self.config / "nwg-dock-hyprland/launch.sh"
        launcher.write_text('#!/bin/sh\necho "$$" > "$TEST_ROOT/dock-pid"\nexec sleep 30\n')
        self.successful(self.image)
        pid = int((self.root / "dock-pid").read_text())
        try:
            launcher.write_text("#!/bin/sh\nexit 0\n")
            self.successful(self.other)
        finally:
            os.kill(pid, 15)

    def test_invalid_legacy_state_requires_explicit_selection(self):
        self.cache.parent.mkdir(parents=True)
        self.cache.write_bytes(b"unverified legacy wallpaper\n")
        self.assertNotEqual(self.command("--restore").returncode, 0)
        state = self.successful(self.image)
        self.assertEqual(state["original"], str(self.image))

    def test_concurrent_effect_uses_new_original_after_waiting_for_selection(self):
        self.successful(self.image)
        selection = subprocess.Popen([str(self.scripts / "wallpaper.sh"), str(self.other)],
                                     env={**self.env, "BLOCK_BACKEND": "1"}, cwd=self.root,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        effect = None
        try:
            for _ in range(300):
                if (self.root / "blocked").exists():
                    break
                time.sleep(0.01)
            self.assertTrue((self.root / "blocked").exists())
            effect = subprocess.Popen([str(self.scripts / "wallpaper.sh"), "--effect", "off"],
                                      env=self.env, cwd=self.root,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.assertIsNone(effect.poll())
            (self.root / "release").touch()
            self.assertEqual(selection.wait(timeout=10), 0)
            self.assertEqual(effect.wait(timeout=10), 0)
            self.assertEqual(self.state()["original"], str(self.other))
            self.assertEqual(self.state()["effect"], "off")
            self.assertEqual(self.active.read_bytes(), b"second")
        finally:
            (self.root / "release").touch()
            if selection.poll() is None:
                selection.kill()
            selection.wait()
            if effect is not None:
                if effect.poll() is None:
                    effect.kill()
                effect.wait()

    def test_crashed_owner_does_not_allow_orphan_backend_to_overwrite_later_state(self):
        self.successful(self.image)
        selection = subprocess.Popen([str(self.scripts / "wallpaper.sh"), str(self.other)],
                                     env={**self.env, "BLOCK_BACKEND": "1"}, cwd=self.root,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        restored = None
        try:
            for _ in range(300):
                if (self.root / "blocked").exists():
                    break
                time.sleep(0.01)
            self.assertTrue((self.root / "blocked").exists())
            selection.kill()
            selection.wait()
            with (self.cache.parent / "wallpaper-pipeline.lock").open("rb") as lock:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            restored = subprocess.Popen([str(self.scripts / "wallpaper.sh"), "--restore"],
                                        env=self.env, cwd=self.root,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.assertIsNone(restored.poll())
            (self.root / "release").touch()
            self.assertEqual(restored.wait(timeout=10), 0)
            self.assertEqual(self.state()["original"], str(self.image))
            self.assertEqual(self.active.read_bytes(), b"first:effect")
        finally:
            (self.root / "release").touch()
            if selection.poll() is None:
                selection.kill()
            selection.wait()
            if restored is not None:
                if restored.poll() is None:
                    restored.kill()
                restored.wait()

    def test_malformed_state_does_not_apply(self):
        self.cache.parent.mkdir(parents=True)
        for data in (b"legacy path\n", b"{}", b'{"version":1,"original":"\\u0000","applied":"/x","effect":"off"}'):
            with self.subTest(data=data):
                self.cache.write_bytes(data)
                result = self.command("--restore")
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.applications())

    def test_ui_terminal_effect_and_control_entry_points(self):
        self.successful(script="waypaper.sh")
        self.assertTrue((self.root / "picker-input").exists())
        picker = REPO / "dotfiles/.config/myhypr/bin/myhypr-wallpaper.sh"
        result = subprocess.run([str(picker)], env=self.env, cwd=self.root, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.state()["original"], str(self.image))
        self.successful(script="wallpaper-effects.sh")
        self.successful("reload", script="wallpaper-effects.sh")
        control = REPO / "dotfiles/.config/myhypr/bin/myhyprctl"
        result = subprocess.run([str(control), "wallpaper"], env=self.env, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_both_picker_sources_include_trailing_newline_names(self):
        image = self.folder / "trailing.png\n\n"
        image.write_bytes(b"image")
        choices = self.command("--list").stdout.split(b"\0")
        self.assertIn(os.fsencode(image), choices)
        picker = REPO / "dotfiles/.config/myhypr/bin/myhypr-wallpaper.sh"
        result = subprocess.run([str(picker)], env={**self.env, "TEST_IMAGE": str(image)},
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(os.fsencode(self.state()["original"]), os.fsencode(image))

    def test_waypaper_model_ignores_failure_and_spawns_unsafe_child_but_repository_never_runs_it(self):
        result = subprocess.run([str(self.bin / "waypaper"), "--wallpaper", str(self.other),
                                 "--no-post-command"], env={**self.env, "FAIL_BACKEND": "1"},
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertEqual((self.root / "waypaper-saved").read_text(), str(self.other))
        result = subprocess.run([str(self.bin / "waypaper"), "--restore", "--no-post-command"],
                                env={**self.env, "FAIL_BACKEND": "1", "SLIDESHOW": "1"},
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertEqual((self.root / "waypaper-saved").read_text(), str(self.image))
        self.assertTrue((self.root / "legacy-callback").exists())
        self.assertEqual(len(self.applications()), 5)
        for marker in ("waypaper-called", "legacy-callback"):
            (self.root / marker).unlink()
        count = len(self.applications())
        self.successful(script="waypaper.sh", env={**self.env, "SLIDESHOW": "1"})
        self.assertEqual(len(self.applications()), count + 1)
        self.assertEqual(len(self.calls("matugen")), 1)
        self.assertFalse((self.root / "legacy-callback").exists())
        self.assertFalse((self.root / "waypaper-called").exists())

    def test_automation_uses_one_global_transaction(self):
        (self.settings / "wallpaper-automation.sh").write_text("10\n")
        worker = subprocess.Popen([str(self.scripts / "wallpaper-automation.sh"), "--run"],
                                  env=self.env, cwd=self.root,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for _ in range(300):
                if self.cache.exists() and len(self.calls("matugen")) == 1:
                    break
                time.sleep(0.01)
            self.assertTrue(self.cache.exists())
            self.assertEqual(len(self.applications()), 1)
            self.assertEqual(len(self.calls("matugen")), 1)
            self.assertFalse((self.root / "waypaper-called").exists())
        finally:
            worker.terminate()
            worker.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
