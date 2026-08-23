#!/usr/bin/env bash
set -Eeuo pipefail

case ${1:-} in
    reset)
        next=1
        ;;
    increase|decrease)
        current=$(hyprctl -j getoption cursor:zoom_factor | jq -er '.float // .int')
        [[ $current =~ ^[0-9]+([.][0-9]+)?$ ]] || {
            printf 'Unexpected cursor zoom value: %s\n' "$current" >&2
            exit 1
        }
        direction=1
        [[ $1 == decrease ]] && direction=-1
        next=$(awk -v current="$current" -v direction="$direction" \
            'BEGIN {
                value = current + (direction * 0.5)
                if (value < 1) value = 1
                if (value > 5) value = 5
                printf "%.1f", value
            }')
        ;;
    *)
        printf 'Usage: %s increase|decrease|reset\n' "$0" >&2
        exit 2
        ;;
esac

exec hyprctl eval "hl.config({ cursor = { zoom_factor = $next } })"
