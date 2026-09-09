#!/usr/bin/env python3
"""Apply MyHypr's Waybar visibility settings to a theme configuration."""

from __future__ import annotations

import argparse
import json
import os
import tempfile
from pathlib import Path


MODULES = {
    "custom/appmenu": ("waybar_appmenu.sh", True, "modules-left", "first"),
    "wlr/taskbar": ("waybar_taskbar.sh", False, "modules-left", "last"),
    "group/quicklinks": ("waybar_quicklinks.sh", False, "modules-left", "last"),
    "hyprland/window": ("waybar_window.sh", True, "modules-center", "last"),
    "network": ("waybar_network.sh", True, "modules-right", "last"),
    "tray": ("waybar_systray.sh", True, "modules-right", "last"),
}

REQUIRED_INCLUDES = (
    "~/.config/myhypr/settings/waybar-quicklinks.json",
    "~/.config/waybar/modules.json",
)


def strip_trailing_commas(source: str) -> str:
    """Remove JSONC trailing commas while preserving quoted text."""
    output: list[str] = []
    index = 0
    in_string = False
    escaped = False
    while index < len(source):
        char = source[index]
        if in_string:
            output.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            index += 1
            continue
        if char == '"':
            in_string = True
            output.append(char)
            index += 1
            continue
        if char == ",":
            lookahead = index + 1
            while lookahead < len(source) and source[lookahead].isspace():
                lookahead += 1
            if lookahead < len(source) and source[lookahead] in "}]":
                index += 1
                continue
        output.append(char)
        index += 1
    return "".join(output)


def strip_jsonc(source: str) -> str:
    """Remove JSONC comments and trailing commas without touching strings."""
    output: list[str] = []
    index = 0
    in_string = False
    escaped = False
    while index < len(source):
        char = source[index]
        next_char = source[index + 1] if index + 1 < len(source) else ""
        if in_string:
            output.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            index += 1
            continue
        if char == '"':
            in_string = True
            output.append(char)
            index += 1
        elif char == "/" and next_char == "/":
            index += 2
            while index < len(source) and source[index] not in "\r\n":
                index += 1
        elif char == "/" and next_char == "*":
            end = source.find("*/", index + 2)
            if end == -1:
                raise ValueError("unterminated block comment")
            index = end + 2
        else:
            output.append(char)
            index += 1
    return strip_trailing_commas("".join(output))


def setting_enabled(settings_root: Path, filename: str, default: bool) -> bool:
    path = settings_root / filename
    if not path.is_file():
        return default
    value = path.read_text(encoding="utf-8").strip().casefold()
    if value in {"true", "1", "yes", "on"}:
        return True
    if value in {"false", "0", "no", "off"}:
        return False
    print(f"Ignoring invalid Waybar setting in {path}: {value!r}", file=os.sys.stderr)
    return default


def apply_visibility(config: dict[str, object], settings_root: Path) -> None:
    for module, (filename, default, destination, placement) in MODULES.items():
        enabled = setting_enabled(settings_root, filename, default)
        found = False
        for key in ("modules-left", "modules-center", "modules-right"):
            modules = config.get(key)
            if isinstance(modules, list):
                filtered = []
                for item in modules:
                    if item != module:
                        filtered.append(item)
                    elif enabled and not found:
                        filtered.append(item)
                        found = True
                config[key] = filtered
        if enabled and not found:
            modules = config.setdefault(destination, [])
            if not isinstance(modules, list):
                raise ValueError(f"{destination} must be an array")
            if placement == "first":
                modules.insert(0, module)
            else:
                modules.append(module)


def ensure_module_includes(config: dict[str, object]) -> None:
    """Ensure every switchable module has a definition in every theme."""
    includes = config.setdefault("include", [])
    if not isinstance(includes, list) or not all(
        isinstance(item, str) for item in includes
    ):
        raise ValueError("include must be an array of strings")

    # Match the established include order while retaining theme-specific files.
    for required in reversed(REQUIRED_INCLUDES):
        if required not in includes:
            includes.insert(0, required)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("settings_root", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    config = json.loads(strip_jsonc(args.source.read_text(encoding="utf-8")))
    if not isinstance(config, dict):
        raise ValueError("Waybar configuration root must be an object")
    ensure_module_includes(config)
    apply_visibility(config, args.settings_root)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{args.output.name}.", dir=args.output.parent, text=True
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as temporary:
            json.dump(config, temporary, indent=2)
            temporary.write("\n")
        os.chmod(temporary_name, 0o600)
        os.replace(temporary_name, args.output)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
