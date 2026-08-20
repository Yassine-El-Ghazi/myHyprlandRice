#!/usr/bin/env bash
set -Eeuo pipefail

VISIBLE_MIN=10
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/myhypr/now-playing"
SCROLL_FILE="$CACHE_ROOT/scroll-position"
MEDIA_FILE="$CACHE_ROOT/last-track"
mkdir -p -- "$CACHE_ROOT"

if ! player_status=$(playerctl status 2>/dev/null) || [[ -z $player_status ]]; then
    rm -f -- "$SCROLL_FILE" "$MEDIA_FILE"
    exit 0
fi

artist=$(playerctl metadata xesam:artist 2>/dev/null || true)
title=$(playerctl metadata xesam:title 2>/dev/null || true)
[[ -n $artist || -n $title ]] || exit 0
track="$title • $artist • "

last_track=''
[[ -r $MEDIA_FILE ]] && last_track=$(<"$MEDIA_FILE")
if [[ $track != "$last_track" ]]; then
    printf '%s\n' "$track" > "$MEDIA_FILE"
    scroll_position=0
else
    scroll_position=0
    [[ -r $SCROLL_FILE ]] && scroll_position=$(<"$SCROLL_FILE")
    [[ $scroll_position =~ ^[0-9]+$ ]] || scroll_position=0
fi

visible_characters=$((${#track} / 2))
((visible_characters >= VISIBLE_MIN)) || visible_characters=$VISIBLE_MIN

if [[ $player_status != Paused ]]; then
    scroll_position=$((scroll_position + 1))
    if ((scroll_position > ${#track})); then
        sleep 2
        scroll_position=0
    fi
fi
printf '%s\n' "$scroll_position" > "$SCROLL_FILE"

if ((scroll_position + visible_characters <= ${#track})); then
    display_text=${track:scroll_position:visible_characters}
else
    wrap_length=$((scroll_position + visible_characters - ${#track}))
    display_text="${track:scroll_position}${track:0:wrap_length}"
fi

jq -cn --arg text "$display_text" --arg class "${player_status,,}" \
    '{text: $text, class: $class}'
