#!/usr/bin/env python3
"""Defensive configuration checks; never execute wallpaper callbacks or power actions."""

import configparser
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


class SecurityBoundaryTests(unittest.TestCase):
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
