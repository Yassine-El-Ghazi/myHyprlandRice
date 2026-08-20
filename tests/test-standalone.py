#!/usr/bin/env python3
"""Validate standalone schema targets and runtime defaults."""

from __future__ import annotations

import json
import re
import shlex
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "dotfiles/.config/myhypr/settings-schema.json"


def repository_path(home_path: str) -> Path:
    if not home_path.startswith("~/.config/"):
        raise AssertionError(f"non-portable settings path: {home_path}")
    relative = Path(home_path.removeprefix("~/"))
    default_path = ROOT / "defaults" / relative
    if default_path.exists():
        return default_path
    return ROOT / "dotfiles" / relative


def main() -> None:
    for default_path in (ROOT / "defaults").rglob("*"):
        if not default_path.is_file():
            continue
        assert default_path.stat().st_mode & 0o111 == 0, (
            f"mutable runtime default is executable: {default_path}"
        )
        relative = default_path.relative_to(ROOT / "defaults")
        tracked_runtime_twin = ROOT / "dotfiles" / relative
        assert not tracked_runtime_twin.exists(), (
            f"mutable runtime file is also linked by Stow: {relative}"
        )

    groups = json.loads(SCHEMA.read_text(encoding="utf-8"))
    identifiers: set[str] = set()

    for group in groups:
        assert group.get("group"), "schema group is unnamed"
        for setting in group.get("settings", []):
            identifier = setting["id"]
            assert identifier not in identifiers, f"duplicate setting id: {identifier}"
            identifiers.add(identifier)

            target = repository_path(setting["file"])
            assert target.is_file(), f"missing target/default for {identifier}: {target}"
            content = target.read_text(encoding="utf-8")
            mode = setting.get("mode", "overwrite")

            if mode == "overwrite":
                assert content.strip() == str(setting.get("default", "")), (
                    f"schema default differs from runtime default for {identifier}"
                )
            elif mode == "replace":
                checkpoint = setting.get("checkpoint")
                candidate = content
                if checkpoint:
                    match = re.search(checkpoint, candidate, re.MULTILINE)
                    assert match, f"checkpoint does not match for {identifier}"
                    candidate = candidate[match.end() :]
                assert re.search(setting["match"], candidate, re.MULTILINE), (
                    f"replacement pattern does not match for {identifier}"
                )
            else:
                raise AssertionError(f"unsupported mode for {identifier}: {mode}")

            if setting.get("type") == "choose":
                assert setting["default"] in setting.get("options", []), (
                    f"default is not selectable for {identifier}"
                )
            if setting.get("type") == "files":
                folder = repository_path(setting["folder"])
                assert (folder / setting["default"]).is_file(), (
                    f"default variant is missing for {identifier}"
                )

            post_command = setting.get("post_command", "")
            if post_command:
                arguments = shlex.split(post_command)
                assert arguments and "com.ml4w" not in post_command
                assert not (arguments[0] in {"bash", "sh"} and "-c" in arguments)

    assert identifiers, "settings schema is empty"
    print(f"Standalone settings schema validated ({len(identifiers)} settings).")


if __name__ == "__main__":
    main()
