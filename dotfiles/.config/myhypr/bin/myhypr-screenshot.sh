#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
# shellcheck source=/dev/null
source "$CONFIG_ROOT/myhypr/library.sh"

save_directory="$HOME/Pictures"
filename_template='screenshot_%Y%m%d_%H%M%S.jpg'
[[ -r $CONFIG_ROOT/myhypr/settings/screenshot-folder ]] && \
    save_directory=$(<"$CONFIG_ROOT/myhypr/settings/screenshot-folder")
[[ -r $CONFIG_ROOT/myhypr/settings/screenshot-filename ]] && \
    filename_template=$(<"$CONFIG_ROOT/myhypr/settings/screenshot-filename")

save_directory=$(myhypr_expand_path "$save_directory")
filename=$(myhypr_render_filename "$filename_template")
output_path="$save_directory/$filename"
mkdir -p -- "$save_directory"

take_screenshot() {
    local mode=$1
    local delay=$2
    local geometry

    [[ $delay =~ ^[0-9]+$ ]] || {
        printf 'Screenshot delay must be a non-negative integer.\n' >&2
        return 2
    }
    if ((delay > 0)); then
        printf 'Waiting %s seconds...\n' "$delay"
        sleep "$delay"
    fi

    case $mode in
        fullscreen)
            grim "$output_path"
            ;;
        area)
            geometry=$(slurp) || return 0
            [[ -n $geometry ]] || return 0
            grim -g "$geometry" "$output_path"
            ;;
        window)
            geometry=$(hyprctl -j activewindow | \
                jq -r '"\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"')
            grim -g "$geometry" "$output_path"
            ;;
        *)
            printf 'Usage: %s [fullscreen|area|window] [DELAY_SECONDS]\n' "${0##*/}" >&2
            return 2
            ;;
    esac

    [[ -f $output_path ]] || {
        printf 'Screenshot capture failed.\n' >&2
        return 1
    }
    wl-copy < "$output_path"
    printf 'Saved %s and copied it to the clipboard.\n' "$output_path"
}

if (($#)); then
    take_screenshot "$1" "${2:-0}"
    exit
fi

mode=$(printf '%s\n' area window fullscreen | fzf \
    --style full --height 15% --layout reverse --border \
    --prompt '🎯 Screenshot mode: ' --header 'ESC to cancel') || exit 0
delay_label=$(printf '%s\n' 0s 2s 5s 10s | fzf \
    --style full --height 15% --layout reverse --border \
    --prompt '⏳ Delay: ' --header 'ESC to cancel') || exit 0

take_screenshot "$mode" "${delay_label%s}"
