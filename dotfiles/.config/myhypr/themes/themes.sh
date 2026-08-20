#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
launcher=$(<"$CONFIG_ROOT/myhypr/settings/launcher")
declare -a themes=()

for theme_directory in "$SCRIPT_DIR"/*; do
    [[ -x $theme_directory/theme.sh ]] || continue
    theme_name=${theme_directory##*/}
    if [[ $theme_name == *-walker ]] && ! command -v walker >/dev/null 2>&1; then
        continue
    fi
    themes+=("$theme_name")
done
((${#themes[@]})) || {
    printf 'No complete desktop themes found under %s.\n' "$SCRIPT_DIR" >&2
    exit 1
}

if [[ $launcher == walker ]] && command -v walker >/dev/null 2>&1; then
    selected_theme=$(printf '%s\n' "${themes[@]}" | \
        "$CONFIG_ROOT/walker/launch.sh" -d -N -H -p 'Desktop theme') || exit 0
else
    selected_theme=$(printf '%s\n' "${themes[@]}" | \
        rofi -dmenu -i -markup -eh 2 -replace -p 'Desktop theme' \
            -config "$CONFIG_ROOT/rofi/config-compact.rasi") || exit 0
fi
[[ -n $selected_theme ]] || exit 0
[[ $selected_theme =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    printf 'Invalid desktop theme selection: %s\n' "$selected_theme" >&2
    exit 1
}
theme_script="$SCRIPT_DIR/$selected_theme/theme.sh"
[[ -x $theme_script ]] || {
    printf 'Desktop theme does not exist: %s\n' "$selected_theme" >&2
    exit 1
}

exec "$theme_script"
