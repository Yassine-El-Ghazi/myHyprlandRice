#!/usr/bin/python3
"""Present Elephant clipboard history in the configured Rofi popup."""

import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    if sys.argv[1:] not in (["copy"], ["delete"]):
        raise ValueError("expected copy or delete")
    action = "remove" if sys.argv[1] == "delete" else "copy"
    config = Path(os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config"))
    response = subprocess.run(
        ["elephant", "query", "--json", "clipboard;;500"],
        capture_output=True, text=True, check=True, timeout=5,
    )
    items = []
    for line in response.stdout.splitlines():
        item = json.loads(line).get("item")
        if item and item.get("provider") == "clipboard":
            identifier = item.get("identifier", "")
            if identifier and not any(char in identifier for char in ";\n\r\0"):
                items.append(item)
    # Pass previews only to Rofi; selection uses an index into the original
    # response. Clipboard text is never parsed as an identifier or command.
    rows = []
    for item in items:
        preview = " ".join(item.get("text", "").split())
        preview = "".join(char for char in preview if char.isprintable())
        rows.append(preview[:500] or "[Image or empty clipboard entry]")
    selection = subprocess.run(
        ["rofi", "-dmenu", "-replace", "-no-custom", "-no-markup-rows",
         "-format", "i", "-p", "Delete" if action == "remove" else "Search",
         "-config", str(config / "rofi/config-cliphist.rasi")],
        input="\n".join(rows) + ("\n" if rows else ""), capture_output=True, text=True,
    )
    if selection.returncode == 1:  # Escape or clicking outside the popup.
        return 0
    selection.check_returncode()
    value = selection.stdout.strip()
    if not value:
        return 0
    if not value.isdecimal() or int(value) >= len(items):
        raise ValueError("invalid clipboard selection")
    identifier = items[int(value)]["identifier"]
    subprocess.run(
        ["elephant", "activate", f"clipboard;{identifier};{action};;"],
        capture_output=True, check=True, timeout=5,
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError):
        # Do not echo clipboard contents or subprocess output in diagnostics.
        print("Could not open Elephant clipboard history in Rofi.", file=sys.stderr)
        sys.exit(1)
