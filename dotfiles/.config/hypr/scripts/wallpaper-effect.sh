#!/usr/bin/env bash
set -Eeuo pipefail

effects=(
    blackwhite
    blackwhite-blur
    blackwhite-brightness40
    blackwhite-brightness60
    blackwhite-brightness80
    blur1
    blur1-brightness40
    blur1-brightness60
    blur1-brightness80
    blur2
    negate
    negate-brightness40
    negate-brightness60
    negate-brightness80
)

if [[ ${1:-} == --list ]]; then
    printf '%s\n' "${effects[@]}"
    exit 0
fi

if [[ $# -ne 3 ]]; then
    printf 'Usage: %s EFFECT INPUT OUTPUT\n' "$0" >&2
    exit 2
fi

effect=$1
input=$2
output=$3
[[ -f $input ]] || {
    printf 'Wallpaper effect input does not exist: %s\n' "$input" >&2
    exit 1
}
mkdir -p -- "$(dirname -- "$output")"

grayscale() {
    magick "$input" -set colorspace Gray -separate -average "$output"
}

brightness() {
    magick "$output" -brightness-contrast "$1" "$output"
}

case $effect in
    blackwhite)
        grayscale
        ;;
    blackwhite-blur)
        grayscale
        magick "$output" -blur 50x30 "$output"
        ;;
    blackwhite-brightness40)
        grayscale
        brightness -60%
        ;;
    blackwhite-brightness60)
        grayscale
        brightness -40%
        ;;
    blackwhite-brightness80)
        grayscale
        brightness -20%
        ;;
    blur1)
        magick "$input" -blur 50x30 "$output"
        ;;
    blur1-brightness40)
        magick "$input" -blur 50x30 "$output"
        brightness -60%
        ;;
    blur1-brightness60)
        magick "$input" -blur 50x30 "$output"
        brightness -40%
        ;;
    blur1-brightness80)
        magick "$input" -blur 50x30 "$output"
        brightness -20%
        ;;
    blur2)
        magick "$input" -blur 10x30 "$output"
        ;;
    negate)
        magick "$input" -negate "$output"
        ;;
    negate-brightness40)
        magick "$input" -negate "$output"
        brightness -60%
        ;;
    negate-brightness60)
        magick "$input" -negate "$output"
        brightness -40%
        ;;
    negate-brightness80)
        magick "$input" -negate "$output"
        brightness -20%
        ;;
    *)
        printf 'Unsupported wallpaper effect: %s\n' "$effect" >&2
        exit 1
        ;;
esac
