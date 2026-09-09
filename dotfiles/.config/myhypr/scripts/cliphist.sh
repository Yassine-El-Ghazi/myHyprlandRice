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
    case ${1:-} in
        w) exec elephant activate 'clipboard;;remove_all;;' ;;
        d)
            # Keep Walker's native clipboard store and expose its existing
            # Ctrl+D delete action instead of silently opening copy mode.
            exec "$HOME/.config/walker/launch.sh" -m clipboard -H \
                -p 'Delete entry: Ctrl+D'
            ;;
        '') exec "$HOME/.config/walker/launch.sh" -m clipboard -N -H ;;
        *) printf 'Usage: %s [d|w]\n' "$0" >&2; exit 2 ;;
    esac
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
        '')
            cliphist list | rofi -dmenu -replace \
                -config "$HOME/.config/rofi/config-cliphist.rasi" | \
                cliphist decode | wl-copy
            ;;
        *) printf 'Usage: %s [d|w]\n' "$0" >&2; exit 2 ;;
    esac
fi
