#!/usr/bin/env bash
set -Eeuo pipefail

generated_versions="$HOME/.cache/myhypr/wallpaper-generated"
mkdir -p -- "$generated_versions"
shopt -s nullglob
cached_files=("$generated_versions"/*)
((${#cached_files[@]} == 0)) || rm -f -- "${cached_files[@]}"
printf '%s\n' ':: Wallpaper cache cleared'
notify-send 'Wallpaper cache cleared'
