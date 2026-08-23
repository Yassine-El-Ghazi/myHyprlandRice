#!/usr/bin/env bash
set -Eeuo pipefail

selector="$HOME/.config/hypr/conf/animation.conf"
cache_root="$HOME/.cache/myhypr"
cache_file="$cache_root/animations-disabled"

if [[ -r $selector && $(<"$selector") == *disabled* ]]; then
    printf '%s\n' ':: Toggle blocked by disabled.conf variation.'
else
    mkdir -p -- "$cache_root"
    if [[ -f $cache_file ]]; then
        hyprctl eval 'hl.config({ animations = { enabled = true } })'
        rm -f -- "$cache_file"
    else
        hyprctl eval 'hl.config({ animations = { enabled = false } })'
        : > "$cache_file"
    fi
fi
