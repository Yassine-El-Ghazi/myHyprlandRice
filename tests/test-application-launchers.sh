#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
launcher="$REPO_ROOT/dotfiles/.local/share/applications/opencode.desktop"

fail() {
    printf 'Application launcher test failed: %s\n' "$*" >&2
    exit 1
}

[[ -f $launcher ]] || fail 'tracked OpenCode launcher is missing'
desktop-file-validate "$launcher" || fail 'OpenCode desktop entry is invalid'
rg -Fqx 'Exec=/opt/OpenCode/OpenCode' "$launcher" || \
    fail 'OpenCode launcher does not start the installed GUI'
rg -Fqx 'TryExec=/opt/OpenCode/OpenCode' "$launcher" || \
    fail 'OpenCode launcher has no safe availability check'
if rg -Fqx 'NoDisplay=true' "$launcher"; then
    fail 'OpenCode launcher is hidden from application menus'
fi

printf 'Visible OpenCode application launcher passed.\n'
