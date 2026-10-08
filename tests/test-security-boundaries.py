#!/usr/bin/env python3
"""Defensive configuration checks; never execute wallpaper callbacks or power actions."""

import configparser
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


class SecurityBoundaryTests(unittest.TestCase):
    def elephant_fixture(self, home, option="--prepare"):
        return subprocess.run(
            ["/usr/bin/python3", str(REPO / "dotfiles/.config/myhypr/bin/elephant-storage.py"), option],
            env={"HOME": str(home), "PATH": f"{home / 'bin'}:/usr/bin:/bin"},
            capture_output=True, text=True, umask=0o022,
        )

    def test_elephant_repairs_legacy_image_permissions(self):
        # A checkout may have foreign-owned mounted ancestors in CI. The
        # storage guard intentionally rejects those; fixture homes belong
        # beneath the root-owned sticky temporary directory instead.
        with tempfile.TemporaryDirectory(prefix="myhypr-elephant-private-", dir="/tmp") as directory:
            home = Path(directory)
            images = home / ".cache/elephant/clipboardimages"
            images.mkdir(parents=True, mode=0o755)
            image = images / "synthetic.png"
            image.write_bytes(b"synthetic image")
            image.chmod(0o644)
            result = self.elephant_fixture(home)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(images.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual(images.stat().st_mode & 0o777, 0o700)
            self.assertEqual(image.stat().st_mode & 0o777, 0o600)
            self.assertEqual(image.read_bytes(), b"synthetic image")

    def test_elephant_rejects_unsafe_cache_and_log_entries(self):
        for location in (".cache/elephant/clipboardimages", ".local/state/myhypr/elephant.log",
                         ".local/state/myhypr/elephant.log.1", ".local/state/myhypr/elephant.lock"):
            for kind in ("symlink", "hardlink", "fifo"):
                with self.subTest(location=location, kind=kind), tempfile.TemporaryDirectory(
                    prefix="myhypr-elephant-unsafe-", dir="/tmp"
                ) as directory:
                    home = Path(directory)
                    external = home / "external"
                    external.write_bytes(b"untouched")
                    external.chmod(0o644)
                    target = home / location
                    target.parent.mkdir(parents=True)
                    if kind == "symlink":
                        target.symlink_to(external)
                    elif kind == "hardlink":
                        os.link(external, target)
                    else:
                        os.mkfifo(target)
                    result = self.elephant_fixture(home, "--fallback")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(external.read_bytes(), b"untouched")
                    self.assertEqual(external.stat().st_mode & 0o777, 0o644)

    def test_elephant_rejects_linked_or_shared_ancestors(self):
        for kind in ("symlink", "shared"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory(prefix="myhypr-elephant-ancestor-", dir="/tmp") as directory:
                home = Path(directory)
                cache = home / ".cache"
                if kind == "symlink":
                    outside = home / "outside"
                    outside.mkdir(mode=0o755)
                    cache.symlink_to(outside)
                else:
                    cache.mkdir(mode=0o777)
                    cache.chmod(0o777)
                self.assertNotEqual(self.elephant_fixture(home).returncode, 0)

    def test_elephant_fallback_uses_private_umask_and_bounded_logs(self):
        with tempfile.TemporaryDirectory(prefix="myhypr-elephant-fallback-", dir="/tmp") as directory:
            home = Path(directory)
            tools = home / "bin"
            tools.mkdir()
            command = tools / "elephant"
            command.write_text(
                "#!/usr/bin/python3\nimport os, pathlib, sys\n"
                "p = pathlib.Path.home() / '.cache/elephant/clipboardimages'\n"
                "p.mkdir(mode=0o755)\n(p / 'synthetic.png').write_bytes(b'synthetic')\n"
                "sys.stdout.write('synthetic diagnostics\\n' * 160000)\n"
            )
            command.chmod(0o700)
            result = self.elephant_fixture(home, "--fallback")
            self.assertEqual(result.returncode, 0, result.stderr)
            image = home / ".cache/elephant/clipboardimages/synthetic.png"
            self.assertEqual(image.stat().st_mode & 0o777, 0o600)
            self.assertEqual(image.parent.stat().st_mode & 0o777, 0o700)
            logs = home / ".local/state/myhypr"
            self.assertEqual(logs.stat().st_mode & 0o777, 0o700)
            for log in (logs / "elephant.log", logs / "elephant.log.1"):
                self.assertEqual(log.stat().st_mode & 0o777, 0o600)
                self.assertLessEqual(log.stat().st_size, 1024 * 1024)

    def test_elephant_service_prepares_storage_with_private_umask(self):
        config = configparser.ConfigParser(interpolation=None)
        config.read(REPO / "dotfiles/.config/systemd/user/elephant.service")
        self.assertEqual(config.get("Service", "UMask"), "0077")
        self.assertEqual(config.get("Service", "ExecStartPre"),
                         "/usr/bin/python3 %h/.config/myhypr/bin/elephant-storage.py --prepare")

    def test_elephant_fallback_serializes_collectors_and_rotation(self):
        with tempfile.TemporaryDirectory(prefix="myhypr-elephant-lock-", dir="/tmp") as directory:
            home = Path(directory)
            state = home / ".local/state/myhypr"
            state.mkdir(parents=True)
            with (state / "elephant.lock").open("w") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                # No Elephant executable exists here: a second startup must
                # return before attempting to launch it or rotate diagnostics.
                result = self.elephant_fixture(home, "--fallback")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse((state / "elephant.log").exists())

    def test_shell_init_modules_remove_relative_search(self):
        for shell in ("bash", "zsh"):
            with self.subTest(shell=shell), tempfile.TemporaryDirectory(prefix="myhypr-shell-init-") as directory:
                home = Path(directory)
                (home / "relative").mkdir()
                script = REPO / f"dotfiles/.config/{shell}rc/00-init"
                args = [shutil.which(shell), "--norc", "-c"] if shell == "bash" else [shutil.which(shell), "-f", "-c"]
                result = subprocess.run([*args, 'source "$INIT"; printf "%s\\n" "$PATH"'], cwd=home, env={
                    "HOME": str(home), "PATH": "relative:.:/usr/bin///::/bin", "GOTELEMETRY": "off",
                    "INIT": str(script),
                }, capture_output=True, text=True, check=True)
                paths = result.stdout.strip().split(":")
                self.assertTrue(all(os.path.isabs(path) for path in paths))
                self.assertEqual(len(paths), len(set(paths)))

    def test_shell_loaders_remove_relative_search_before_and_after_modules(self):
        for shell in ("bash", "zsh"):
            with self.subTest(shell=shell), tempfile.TemporaryDirectory(prefix="myhypr-shell-path-") as directory:
                home = Path(directory)
                modules = home / f".config/{shell}rc"
                modules.mkdir(parents=True)
                relative = home / "relative"
                relative.mkdir()
                marker = relative / "myhypr-relative-fixture"
                marker.write_text("lookup fixture, never executed\n")
                marker.chmod(0o700)
                (modules / "00-fixture").write_text(
                    "if command -v myhypr-relative-fixture >/dev/null; then exit 91; fi\n"
                )
                (home / f".{shell}rc_custom").write_text('export PATH=".:relative::$PATH"\n')
                script = REPO / f"dotfiles/.{shell}rc"
                command = 'source "$LOADER"; printf "%s\\n" "$PATH"'
                args = [shutil.which(shell), "--norc", "-c", command] if shell == "bash" else [shutil.which(shell), "-f", "-c", command]
                result = subprocess.run(args, cwd=home, env={
                    "HOME": str(home), "PATH": "relative:.:/usr/bin///::/bin",
                    "LOADER": str(script),
                }, capture_output=True, text=True, check=True)
                paths = result.stdout.strip().split(":")
                self.assertTrue(all(os.path.isabs(path) for path in paths))
                self.assertEqual(len(paths), len(set(paths)))
                self.assertEqual(paths[:3], ["/usr/local/sbin", "/usr/local/bin", "/usr/bin"])

    def test_early_shell_startup_normalizes_before_and_after_cargo(self):
        for shell in ("bash", "sh", "zsh"):
            with self.subTest(shell=shell), tempfile.TemporaryDirectory(prefix="myhypr-early-path-") as directory:
                home = Path(directory)
                (home / ".cargo").mkdir()
                (home / "relative").mkdir()
                marker = home / "relative/myhypr-relative-fixture"
                marker.write_text("lookup fixture, never executed\n")
                marker.chmod(0o700)
                (home / ".cargo/env").write_text(
                    'if command -v myhypr-relative-fixture >/dev/null; then\n'
                    '    printf unsafe > "$HOME/unsafe-lookup"\n'
                    'fi\n'
                    'export PATH="relative:.:/usr/bin///::$PATH"\n'
                )
                if shell == "bash":
                    args = [shutil.which(shell), "--noprofile", "--norc", "-c",
                            'source "$PROFILE"; printf "%s\\n" "$PATH"']
                elif shell == "sh":
                    args = [shutil.which(shell), "-c", '. "$PROFILE"; printf "%s\\n" "$PATH"']
                else:
                    shutil.copyfile(REPO / "dotfiles/.zshenv", home / ".zshenv")
                    args = [shutil.which(shell), "-c", 'printf "%s\\n" "$PATH"']
                result = subprocess.run(args, cwd=home, env={
                    "HOME": str(home), "PATH": "relative:.:/usr/bin///::/bin",
                    "PROFILE": str(REPO / "dotfiles/.profile"),
                }, capture_output=True, text=True, check=True)
                self.assertFalse((home / "unsafe-lookup").exists())
                paths = result.stdout.strip().split(":")
                self.assertTrue(all(os.path.isabs(path) for path in paths))
                self.assertEqual(len(paths), len(set(paths)))
                self.assertEqual(paths[:3], ["/usr/local/sbin", "/usr/local/bin", "/usr/bin"])

    def test_wallpaper_launchers_disable_existing_callbacks(self):
        with tempfile.TemporaryDirectory(prefix="myhypr-wallpaper-launch-") as directory:
            home = Path(directory)
            fake_bin = home / "bin"
            fake_bin.mkdir()
            waypaper = fake_bin / "waypaper"
            waypaper.write_text(
                "#!/usr/bin/python3\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n"
            )
            waypaper.chmod(0o700)
            env = {"HOME": str(home), "PATH": f"{fake_bin}:/usr/bin:/bin"}
            for relative, arguments in (
                ("dotfiles/.config/hypr/scripts/waypaper.sh", []),
                ("dotfiles/.config/hypr/scripts/waypaper.sh", ["--random"]),
                ("dotfiles/.config/myhypr/bin/myhyprctl", ["wallpaper"]),
            ):
                with self.subTest(launcher=relative, arguments=arguments):
                    result = subprocess.run(
                        ["/bin/bash", str(REPO / relative), *arguments], env=env,
                        capture_output=True, text=True, check=True,
                    )
                    passed = json.loads(result.stdout)
                    self.assertIn("--no-post-command", passed)
                    self.assertEqual(passed[:2], ["--backend", "awww"])
                    if "--random" in arguments:
                        self.assertIn("--random", passed)

    def test_wallpaper_restore_prefers_saved_selection_without_callback(self):
        with tempfile.TemporaryDirectory(prefix="myhypr-wallpaper-restore-") as directory:
            home = Path(directory)
            fake_bin = home / "bin"
            fake_bin.mkdir()
            (fake_bin / "awww").write_text("#!/bin/sh\nexit 0\n")
            (fake_bin / "waypaper").write_text(
                "#!/usr/bin/python3\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n"
            )
            for tool in fake_bin.iterdir():
                tool.chmod(0o700)
            config = home / ".config/waypaper/config.ini"
            config.parent.mkdir(parents=True)
            config.write_text("[Settings]\nwallpaper = ~/chosen image.png\npost_command =\n")
            default = home / ".config/myhypr/wallpapers/default.jpg"
            default.parent.mkdir(parents=True)
            env = {"HOME": str(home), "PATH": f"{fake_bin}:/usr/bin:/bin"}
            script = REPO / "dotfiles/.config/hypr/scripts/wallpaper-restore.sh"
            result = subprocess.run(["/bin/bash", str(script)], env=env,
                                    capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(result.stdout.splitlines()[-1]),
                             ["--backend", "awww", "--restore", "--no-post-command"])
            config.unlink()
            default.write_text("fixture")
            result = subprocess.run(["/bin/bash", str(script)], env=env,
                                    capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(result.stdout.splitlines()[-1]),
                             ["--backend", "awww", "--wallpaper", str(default),
                              "--no-post-command"])

    def test_wallpaper_defaults_do_not_enable_shell_callbacks(self):
        config = configparser.ConfigParser(interpolation=None)
        config.read(REPO / "defaults/.config/waypaper/config.ini")
        self.assertEqual(config.get("Settings", "post_command", fallback=""), "")

    def test_suspend_configuration_requires_lock_notification(self):
        config = (REPO / "dotfiles/.config/hypr/hypridle.conf").read_text()
        general = config.split("general {", 1)[1].split("}", 1)[0]
        options = {}
        for line in general.splitlines():
            key, separator, value = line.split("#", 1)[0].partition("=")
            if separator:
                options[key.strip()] = value.strip()
        self.assertEqual(options.get("inhibit_sleep"), "3")

    @unittest.skipUnless(shutil.which("fish"), "fish is unavailable")
    def test_fish_keeps_system_commands_before_local_tools(self):
        with tempfile.TemporaryDirectory(prefix="myhypr-fish-path-") as directory:
            home = Path(directory)
            local_bin = home / ".local/bin"
            local_bin.mkdir(parents=True)
            # The init module queries Go's GOPATH. Disable telemetry only in
            # this fixture so its background writer cannot race home cleanup.
            telemetry = home / ".config/go/telemetry"
            telemetry.mkdir(parents=True)
            (telemetry / "mode").write_text("off\n")
            env = {
                "HOME": str(home),
                "XDG_CONFIG_HOME": str(home / ".config"),
                "XDG_CACHE_HOME": str(home / ".cache"),
                "PATH": f"{local_bin}:/usr/bin/:.:relative::/bin",
                "INIT_FILE": str(REPO / "dotfiles/.config/fish/conf.d/00_init.fish"),
            }
            result = subprocess.run(
                [shutil.which("fish"), "--no-config", "-c",
                 'source "$INIT_FILE"; printf "%s\\n" $PATH'],
                env=env, capture_output=True, text=True, check=True,
            )
            paths = result.stdout.splitlines()
            self.assertEqual(paths[:3], ["/usr/local/sbin", "/usr/local/bin", "/usr/bin"])
            self.assertLess(paths.index("/usr/bin"), paths.index(str(local_bin)))
            self.assertTrue(all(os.path.isabs(path) for path in paths))
            self.assertEqual(len(paths), len(set(paths)))


if __name__ == "__main__":
    unittest.main()
