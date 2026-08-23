#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd -- "$REPO_ROOT"

if rg -n -i 'ml4w|mylinuxforwork' dotfiles defaults; then
    printf 'Legacy branding or an external ML4W runtime dependency remains.\n' >&2
    exit 1
fi

shell_eval_pattern='(^|[;&|(){}[:space:]])[[:space:]]*(builtin[[:space:]]+|command[[:space:]]+)?eval[[:space:]]'

shell_eval_matches() {
    local matches match remainder line_number line found=1
    matches=$(rg -n "$shell_eval_pattern" "$@" || true)
    [[ -n $matches ]] || return 1
    while IFS= read -r match; do
        remainder=${match#*:}
        line_number=${remainder%%:*}
        line=${remainder#*:}
        line=$(printf '%s\n' "$line" | sed -e "s/[\"']//g" | sed -E \
            -e 's#(^|[;&|(){}[:space:]])hyprctl[[:space:]]+eval([[:space:]])#\1\2#g')
        if printf '%s\n' "$line" | rg -q "$shell_eval_pattern"; then
            printf '%s:%s:%s\n' "${match%%:*}" "$line_number" "$line"
            found=0
        fi
    done <<< "$matches"
    return "$found"
}

shell_eval_test_root=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-shell-eval-test.XXXXXXXX")
trap 'rm -rf -- "$shell_eval_test_root"' EXIT
printf '%s\n' 'eval "$value"' > "$shell_eval_test_root/plain.sh"
printf '%s\n' 'if eval "$value"; then' > "$shell_eval_test_root/control-flow.sh"
printf '%s\n' 'hyprctl eval hl.config({ cursor = { zoom_factor = 2.5 } })' > "$shell_eval_test_root/fixed.sh"
printf '%s\n' 'hyprctl eval hl.monitor({ refresh_rate = 60 })' > "$shell_eval_test_root/monitor.sh"
printf '%s\n' 'hyprctl eval "require('\''conf.runtime_actions'\'').toggle_all_float()"' > "$shell_eval_test_root/runtime-actions.sh"
printf '%s\n' 'hyprctl eval hl.config({ cursor = { zoom_factor = 2.5 } }); eval "$value"' > "$shell_eval_test_root/mixed.sh"
if shell_eval_matches "$shell_eval_test_root/plain.sh"; then :; else
    printf 'Shell-eval guard missed plain eval.\n' >&2
    exit 1
fi
if shell_eval_matches "$shell_eval_test_root/control-flow.sh"; then :; else
    printf 'Shell-eval guard missed control-flow eval.\n' >&2
    exit 1
fi
if shell_eval_matches "$shell_eval_test_root/fixed.sh"; then
    printf 'Shell-eval guard rejected a fixed hyprctl eval subcommand.\n' >&2
    exit 1
fi
if shell_eval_matches "$shell_eval_test_root/monitor.sh"; then
    printf 'Shell-eval guard rejected a fixed hyprctl monitor subcommand.\n' >&2
    exit 1
fi
if shell_eval_matches "$shell_eval_test_root/runtime-actions.sh"; then
    printf 'Shell-eval guard rejected a fixed runtime-actions subcommand.\n' >&2
    exit 1
fi
if shell_eval_matches "$shell_eval_test_root/mixed.sh"; then :; else
    printf 'Shell-eval guard missed a second shell eval.\n' >&2
    exit 1
fi

if shell_eval_matches \
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

if rg -n --hidden \
    'hyprctl[[:space:]]+(clients|monitors|activewindow|activeworkspace|instances|layers)[[:space:]]+-j' \
    dotfiles; then
    printf 'A Hyprland helper still uses the obsolete JSON-flag ordering.\n' >&2
    exit 1
fi

rg -q 'require\("conf\.myhypr"\)' dotfiles/.config/hypr/hyprland.lua
rg -q 'SettingsWindow[[:space:]]*\{' dotfiles/.config/quickshell/shell.qml
rg -q 'settingsctl' dotfiles/.config/quickshell/SettingsApp/SettingsWindow.qml

python "$REPO_ROOT/tests/test-standalone.py"
printf 'Standalone runtime dependency guards passed.\n'
