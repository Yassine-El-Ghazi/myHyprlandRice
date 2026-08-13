#!/usr/bin/env python3
"""Validate JSON and JSON-with-comments files using only the standard library."""

from __future__ import annotations

import json
import pathlib
import re
import sys


def strip_comments(source: str) -> str:
    output: list[str] = []
    index = 0
    in_string = False
    escaped = False

    while index < len(source):
        char = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""

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

        if char == "/" and following == "/":
            output.extend("  ")
            index += 2
            while index < len(source) and source[index] not in "\r\n":
                output.append(" ")
                index += 1
            continue

        if char == "/" and following == "*":
            output.extend("  ")
            index += 2
            while index < len(source):
                if source[index] == "*" and index + 1 < len(source) and source[index + 1] == "/":
                    output.extend("  ")
                    index += 2
                    break
                output.append("\n" if source[index] == "\n" else " ")
                index += 1
            else:
                raise ValueError("unterminated block comment")
            continue

        output.append(char)
        index += 1

    return "".join(output)


def strip_trailing_commas(source: str) -> str:
    previous = None
    while previous != source:
        previous = source
        source = re.sub(r",(?=\s*[}\]])", "", source)
    return source


def validate(path: pathlib.Path) -> bool:
    try:
        source = path.read_text(encoding="utf-8")
        json.loads(strip_trailing_commas(strip_comments(source)))
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
        print(f"{path}: {error}", file=sys.stderr)
        return False
    return True


def main() -> int:
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} FILE [...]", file=sys.stderr)
        return 2
    return 0 if all(validate(pathlib.Path(name)) for name in sys.argv[1:]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
