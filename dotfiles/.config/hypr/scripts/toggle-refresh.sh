#!/usr/bin/env bash

CURRENT="$(hyprctl monitors | grep -A20 '^Monitor eDP-1' | grep -oP '[0-9]+\.[0-9]+(?=Hz)' | head -n1)"

if [[ "$CURRENT" =~ ^144 ]]; then
    hyprctl keyword monitor "eDP-1, 1920x1080@60, 0x0, 1"
    hyprctl notify 5 2500 "rgb(8aadf4)" "Switched to 60Hz"
else
    hyprctl keyword monitor "eDP-1, 1920x1080@144, 0x0, 1"
    hyprctl notify 5 2500 "rgb(a6da95)" "Switched to 144Hz"
fi
