#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

for qml in \
    "$REPO_ROOT/dotfiles/.config/quickshell/SidebarApp/SidebarWindow.qml" \
    "$REPO_ROOT/dotfiles/.config/quickshell/WelcomeApp/WelcomeWindow.qml"; do
    if rg -Uq 'Process[[:space:]]*\{[[:space:]]*id:[[:space:]]*appLauncher' "$qml"; then
        printf 'Interactive applications are still owned by Quickshell: %s\n' "$qml" >&2
        exit 1
    fi
    rg -Uq 'QtObject[[:space:]]*\{[[:space:]]*id:[[:space:]]*appLauncher' "$qml"
    rg -Fq 'Quickshell.execDetached(command)' "$qml"
done

printf 'Quickshell launches independent applications outside its process lifecycle.\n'
