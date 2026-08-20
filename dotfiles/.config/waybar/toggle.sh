#!/usr/bin/env bash
set -Eeuo pipefail
#  _____                 _       __        __          _
# |_   _|__   __ _  __ _| | ___  \ \      / /_ _ _   _| |__   __ _ _ __
#   | |/ _ \ / _` |/ _` | |/ _ \  \ \ /\ / / _` | | | | '_ \ / _` | '__|
#   | | (_) | (_| | (_| | |  __/   \ V  V / (_| | |_| | |_) | (_| | |
#   |_|\___/ \__, |\__, |_|\___|    \_/\_/ \__,_|\__, |_.__/ \__,_|_|
#            |___/ |___/                         |___/
#

marker="$HOME/.config/myhypr/settings/waybar-disabled"
mkdir -p -- "$(dirname -- "$marker")"
if [[ -f $marker ]]; then
    rm -f -- "$marker"
else
    : > "$marker"
fi
"$HOME/.config/waybar/launch.sh" &
