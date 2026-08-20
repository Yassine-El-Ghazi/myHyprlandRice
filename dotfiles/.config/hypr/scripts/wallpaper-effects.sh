#!/usr/bin/env bash
set -Eeuo pipefail
# __        ______    _____  __  __           _
# \ \      / /  _ \  | ____|/ _|/ _| ___  ___| |_ ___
#  \ \ /\ / /| |_) | |  _| | |_| |_ / _ \/ __| __/ __|
#   \ V  V / |  __/  | |___|  _|  _|  __/ (__| |_\__ \
#    \_/\_/  |_|     |_____|_| |_|  \___|\___|\__|___/
#

myhypr_cache_root="$HOME/.cache/myhypr"

# Get current wallpaper
cache_file="$myhypr_cache_root/current_wallpaper"
effect_helper="$HOME/.config/hypr/scripts/wallpaper-effect.sh"
setting_file="$HOME/.config/myhypr/settings/wallpaper-effect.sh"

if [[ ${1:-} == reload ]]; then
    [[ -r $cache_file ]] || {
        printf 'No current wallpaper is cached.\n' >&2
        exit 1
    }
    waypaper --backend awww --wallpaper "$(<"$cache_file")"
else
    mapfile -t effects < <("$effect_helper" --list)
    effects+=(off)
    choice=$(printf '%s\n' "${effects[@]}" | rofi -dmenu -replace \
        -config "$HOME/.config/rofi/config-themes.rasi" -i -no-show-icons \
        -l 5 -width 30 -p 'Wallpaper effect') || exit 0
    [[ -n $choice ]] || exit 0
    [[ $choice == off || " ${effects[*]} " == *" $choice "* ]] || {
        printf 'Invalid wallpaper effect: %s\n' "$choice" >&2
        exit 1
    }
    printf '%s\n' "$choice" > "$setting_file"
    notify-send 'Changing wallpaper effect' "$choice"
    [[ -r $cache_file ]] && \
        waypaper --backend awww --wallpaper "$(<"$cache_file")"
fi
