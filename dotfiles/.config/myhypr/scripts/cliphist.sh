#!/usr/bin/env bash
set -Eeuo pipefail
#   ____ _ _       _     _     _
#  / ___| (_)_ __ | |__ (_)___| |_
# | |   | | | '_ \| '_ \| / __| __|
# | |___| | | |_) | | | | \__ \ |_
#  \____|_|_| .__/|_| |_|_|___/\__|
#           |_|
#

# -----------------------------------------------------
# Load Launcher
# -----------------------------------------------------
launcher=rofi
launcher_file="$HOME/.config/myhypr/settings/launcher"
if [[ -r $launcher_file ]]; then
    IFS= read -r launcher < "$launcher_file" || true
fi
if [[ $launcher == walker ]]; then
    exec "$HOME/.config/walker/launch.sh" -m clipboard -N -H
else
    [[ $launcher == rofi ]] || {
        printf 'Unsupported launcher setting: %s\n' "$launcher" >&2
        exit 1
    }
    case ${1:-} in
        d)
            cliphist list | rofi -dmenu -replace \
                -config "$HOME/.config/rofi/config-cliphist.rasi" | cliphist delete
            ;;
        w)
            cliphist wipe
            ;;
        *)
            cliphist list | rofi -dmenu -replace \
                -config "$HOME/.config/rofi/config-cliphist.rasi" | \
                cliphist decode | wl-copy
            ;;
    esac
fi
