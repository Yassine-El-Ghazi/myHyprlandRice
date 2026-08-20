#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd -- "$REPO_ROOT"

if rg -n -i 'ml4w|mylinuxforwork' dotfiles defaults; then
    printf 'Legacy branding or an external ML4W runtime dependency remains.\n' >&2
    exit 1
fi

if rg -n '(^|[^[:alnum:]_])eval[[:space:]]' \
    dotfiles/.config/myhypr dotfiles/.config/sidepad dotfiles/.config/hypr/scripts; then
    printf 'Tracked desktop helpers still evaluate runtime text as shell code.\n' >&2
    exit 1
fi

if rg -n 'source[[:space:]]+.*effects/wallpaper' dotfiles/.config/hypr; then
    printf 'Wallpaper effects are still sourced as executable shell text.\n' >&2
    exit 1
fi

obsolete_local_refs='\.config/myhypr/waybar|settings/aur\.sh|cat .*settings/terminal\.sh|hypr/scripts/diagnosis\.sh|myhypr-quickshell'
if rg -n --hidden "$obsolete_local_refs" dotfiles defaults; then
    printf 'An obsolete local path remains in active configuration.\n' >&2
    exit 1
fi

if rg -n --hidden '"(bash|sh)",[[:space:]]*"-c"' dotfiles/.config/quickshell; then
    printf 'Quickshell still routes desktop actions through a shell string.\n' >&2
    exit 1
fi

if rg -n --hidden '(bash|sh)[[:space:]]+-c' \
    dotfiles/.config/swaync dotfiles/.config/myhypr dotfiles/.config/hypr; then
    printf 'An active desktop action still uses an unchecked shell command string.\n' >&2
    exit 1
fi

rg -q 'require\("conf\.myhypr"\)' dotfiles/.config/hypr/hyprland.lua
rg -q 'SettingsWindow[[:space:]]*\{' dotfiles/.config/quickshell/shell.qml
rg -q 'settingsctl' dotfiles/.config/quickshell/SettingsApp/SettingsWindow.qml

python "$REPO_ROOT/tests/test-standalone.py"
printf 'Standalone runtime dependency guards passed.\n'
