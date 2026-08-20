#!/usr/bin/env python3
"""Regression tests for the local, schema-constrained settings editor."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SETTINGSCTL = REPO_ROOT / "dotfiles/.config/myhypr/bin/settingsctl"


class SettingsCtlTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="myhypr-settingsctl-")
        self.root = Path(self.temporary.name) / "home"
        self.outside = Path(self.temporary.name) / "outside"
        self.root.mkdir()
        self.outside.mkdir()
        (self.root / "settings").mkdir()
        (self.root / "link").symlink_to(self.outside, target_is_directory=True)

        self.choice = self.root / "settings/choice"
        self.replace = self.root / "settings/replace.conf"
        self.replace.write_text("# before\n# marker\nvalue = old\n", encoding="utf-8")
        self.schema = Path(self.temporary.name) / "schema.json"
        self.schema.write_text(
            json.dumps(
                [
                    {
                        "group": "Tests",
                        "settings": [
                            {
                                "id": "choice",
                                "file": str(self.choice),
                                "type": "choose",
                                "options": ["one", "two"],
                                "default": "one",
                            },
                            {
                                "id": "replace",
                                "file": str(self.replace),
                                "type": "textfield",
                                "mode": "replace",
                                "match": "value = .*",
                                "checkpoint": "# marker",
                                "default": "missing",
                            },
                            {
                                "id": "outside",
                                "file": str(self.outside / "escaped"),
                                "default": "safe",
                            },
                            {
                                "id": "symlink_escape",
                                "file": str(self.root / "link/escaped"),
                                "default": "safe",
                            },
                        ],
                    }
                ]
            ),
            encoding="utf-8",
        )
        self.environment = os.environ.copy()
        self.environment.update(
            {
                "HOME": str(self.root),
                "MYHYPR_SETTINGS_ROOT": str(self.root),
                "MYHYPR_SETTINGS_SCHEMA": str(self.schema),
            }
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_ctl(self, *arguments: str, success: bool = True) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [str(SETTINGSCTL), *arguments],
            check=False,
            capture_output=True,
            text=True,
            env=self.environment,
        )
        if success and result.returncode != 0:
            self.fail(f"settingsctl failed: {result.stderr}")
        if not success and result.returncode == 0:
            self.fail("settingsctl unexpectedly accepted an invalid operation")
        return result

    def test_overwrite_is_atomic_and_preserves_mode(self) -> None:
        self.assertEqual(self.run_ctl("get", "choice").stdout, "one")
        self.run_ctl("set", "choice", "two")
        self.assertEqual(self.choice.read_text(encoding="utf-8"), "two\n")
        self.assertEqual(stat.S_IMODE(self.choice.stat().st_mode), 0o600)

        self.choice.chmod(0o640)
        self.run_ctl("set", "choice", "one")
        self.assertEqual(stat.S_IMODE(self.choice.stat().st_mode), 0o640)
        self.assertFalse(list(self.choice.parent.glob(".choice.*")))

    def test_replace_honors_checkpoint(self) -> None:
        self.assertEqual(self.run_ctl("get", "replace").stdout, "old")
        self.run_ctl("set", "replace", "new value")
        self.assertEqual(
            self.replace.read_text(encoding="utf-8"),
            "# before\n# marker\nvalue = new value\n",
        )

    def test_invalid_choice_and_multiline_values_are_rejected(self) -> None:
        self.run_ctl("set", "choice", "three", success=False)
        self.run_ctl("set", "choice", "one\ntwo", success=False)
        self.assertFalse(self.choice.exists())

    def test_direct_and_symlink_path_escapes_are_rejected(self) -> None:
        self.run_ctl("set", "outside", "unsafe", success=False)
        self.run_ctl("set", "symlink_escape", "unsafe", success=False)
        self.assertFalse((self.outside / "escaped").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
