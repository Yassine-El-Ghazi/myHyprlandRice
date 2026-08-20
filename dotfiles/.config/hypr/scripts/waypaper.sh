#!/usr/bin/env bash
set -Eeuo pipefail

if ! command -v waypaper >/dev/null 2>&1; then
    printf 'waypaper: command not found\n' >&2
    exit 127
fi

wallpaper_dir="$HOME/.config/myhypr/wallpapers"
exec waypaper --backend awww --folder "$wallpaper_dir" "$@"
