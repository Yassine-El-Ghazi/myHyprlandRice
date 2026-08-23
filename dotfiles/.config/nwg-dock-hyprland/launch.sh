#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
SETTINGS_ROOT="$CONFIG_ROOT/myhypr/settings"
theme=modern
[[ -r $SETTINGS_ROOT/dock-theme ]] && theme=$(<"$SETTINGS_ROOT/dock-theme")
[[ $theme =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    printf 'Invalid dock theme: %s\n' "$theme" >&2
    exit 1
}
style_relative="themes/$theme/style.css"
style="$CONFIG_ROOT/nwg-dock-hyprland/$style_relative"
[[ -f $style ]] || {
    printf 'Dock theme is unavailable: %s\n' "$style" >&2
    exit 1
}

pkill -f -- '(^|/)nwg-dock-hyprland([[:space:]]|$)' >/dev/null 2>&1 || true
[[ ! -f $SETTINGS_ROOT/dock-disabled ]] || {
    printf 'Dock is disabled by the runtime setting.\n'
    exit 0
}
sleep 0.3

arguments=(
    -i 32 -w 5 -mb 10 -x
    -s "$style_relative"
    -c "$CONFIG_ROOT/hypr/scripts/launcher.sh"
)
[[ ! -f $SETTINGS_ROOT/dock-autohide ]] || arguments=(-d "${arguments[@]}")
exec nwg-dock-hyprland "${arguments[@]}"
