#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/myhypr"
SETTINGS_ROOT="$CONFIG_ROOT/myhypr/settings"
MONITOR_SELECTOR="$CONFIG_ROOT/hypr/conf/monitor.conf"
GAMEMODE_MONITOR="$CONFIG_ROOT/hypr/conf/monitors/gamemode.conf"
ENABLED_MARKER="$SETTINGS_ROOT/gamemode-enabled"
LAST_MONITOR="$CACHE_ROOT/last_monitor.conf"
RESTART_WALLPAPER="$CACHE_ROOT/restart-wpauto"
WALLPAPER_AUTOMATION="$CACHE_ROOT/wallpaper-automation"
mkdir -p -- "$CACHE_ROOT" "$SETTINGS_ROOT"

if [[ -f $ENABLED_MARKER ]]; then
    if [[ -f $LAST_MONITOR ]]; then
        cp -- "$LAST_MONITOR" "$MONITOR_SELECTOR"
        rm -f -- "$LAST_MONITOR"
    fi
    if [[ -f $RESTART_WALLPAPER ]]; then
        rm -f -- "$RESTART_WALLPAPER"
        "$CONFIG_ROOT/hypr/scripts/wallpaper-automation.sh" &
        disown
    fi
    hyprctl reload
    rm -f -- "$ENABLED_MARKER"
    notify-send 'Gamemode deactivated' 'Animations and blur enabled'
    exit 0
fi

if [[ -f $GAMEMODE_MONITOR ]]; then
    [[ -f $MONITOR_SELECTOR ]] && cp -- "$MONITOR_SELECTOR" "$LAST_MONITOR"
    printf 'source = %s\n' "$GAMEMODE_MONITOR" > "$MONITOR_SELECTOR"
fi
if [[ -f $WALLPAPER_AUTOMATION ]]; then
    : > "$RESTART_WALLPAPER"
    "$CONFIG_ROOT/hypr/scripts/wallpaper-automation.sh"
fi

hyprctl eval 'hl.config({ animations = { enabled = false }, decoration = { shadow = { enabled = false }, blur = { enabled = false }, active_opacity = 1, inactive_opacity = 1, fullscreen_opacity = 1, rounding = 0 }, general = { gaps_in = 0, gaps_out = 0, border_size = 1 } })'
: > "$ENABLED_MARKER"
notify-send 'Gamemode activated' 'Animations and blur disabled'
