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
WALLPAPER_AUTOMATION="$CONFIG_ROOT/hypr/scripts/wallpaper-automation.sh"
mkdir -p -- "$CACHE_ROOT" "$SETTINGS_ROOT"

if [[ -f $ENABLED_MARKER ]]; then
    restart_wallpaper=0
    if [[ -f $LAST_MONITOR ]]; then
        cp -- "$LAST_MONITOR" "$MONITOR_SELECTOR"
        rm -f -- "$LAST_MONITOR"
    fi
    if [[ -f $RESTART_WALLPAPER ]]; then
        rm -f -- "$RESTART_WALLPAPER"
        restart_wallpaper=1
    fi
    rm -f -- "$ENABLED_MARKER"
    reload_status=0
    hyprctl reload || reload_status=$?
    if [[ $restart_wallpaper -eq 1 ]]; then
        "$WALLPAPER_AUTOMATION" --start || true
    fi
    [[ $reload_status -eq 0 ]] || exit "$reload_status"
    notify-send 'Gamemode deactivated' 'Animations and blur enabled'
    exit 0
fi

if "$WALLPAPER_AUTOMATION" --status >/dev/null 2>&1; then
    "$WALLPAPER_AUTOMATION" --stop
    : > "$RESTART_WALLPAPER"
fi
if [[ -f $GAMEMODE_MONITOR ]]; then
    [[ -f $MONITOR_SELECTOR ]] && cp -- "$MONITOR_SELECTOR" "$LAST_MONITOR"
    printf 'source = %s\n' "$GAMEMODE_MONITOR" > "$MONITOR_SELECTOR"
fi

if ! hyprctl eval 'require("conf.gamemode_state").apply()'; then
    if [[ -f $RESTART_WALLPAPER ]]; then
        rm -f -- "$RESTART_WALLPAPER"
        "$WALLPAPER_AUTOMATION" --start || true
    fi
    if [[ -f $LAST_MONITOR ]]; then
        cp -- "$LAST_MONITOR" "$MONITOR_SELECTOR"
        rm -f -- "$LAST_MONITOR"
    fi
    exit 1
fi
: > "$ENABLED_MARKER"
notify-send 'Gamemode activated' 'Animations and blur disabled'
