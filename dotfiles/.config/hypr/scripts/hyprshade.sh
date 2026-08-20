#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
SETTING_FILE="$CONFIG_ROOT/myhypr/settings/hyprshade.sh"
default_filter='blue-light-filter-50'

mapfile -t filters < <(hyprshade ls | sed 's/^[ *]*//' | sed '/^$/d')
is_known_filter() {
    local candidate=$1
    local filter
    [[ $candidate == off ]] && return 0
    for filter in "${filters[@]}"; do
        [[ $candidate == "$filter" ]] && return 0
    done
    return 1
}

write_filter() {
    local filter=$1
    local temporary

    mkdir -p -- "${SETTING_FILE%/*}"
    temporary=$(mktemp "${SETTING_FILE%/*}/.hyprshade.XXXXXX")
    printf '%s\n' "$filter" > "$temporary"
    mv -- "$temporary" "$SETTING_FILE"
}

if [[ ${1:-} == rofi ]]; then
    choice=$(printf '%s\n' "${filters[@]}" off | \
        rofi -dmenu -replace -config "$CONFIG_ROOT/rofi/config-hyprshade.rasi" \
            -i -no-show-icons -l 4 -width 30 -p Hyprshade) || exit 0
    [[ -n $choice ]] || exit 0
    is_known_filter "$choice" || {
        printf 'Unknown Hyprshade filter: %s\n' "$choice" >&2
        exit 1
    }
    write_filter "$choice"
    if [[ $choice == off ]]; then
        hyprshade off
        notify-send 'Hyprshade deactivated'
    else
        notify-send "Hyprshade set to $choice" 'Toggle with SUPER+SHIFT+H'
    fi
    exit 0
fi

selected_filter=$default_filter
[[ -r $SETTING_FILE ]] && selected_filter=$(<"$SETTING_FILE")
if ! is_known_filter "$selected_filter"; then
    printf 'Configured Hyprshade filter is unavailable: %s\n' "$selected_filter" >&2
    exit 1
fi

if [[ $selected_filter == off ]]; then
    hyprshade off
    exit 0
fi

current_filter=$(hyprshade current 2>/dev/null || true)
if [[ -z $current_filter ]]; then
    hyprshade on "$selected_filter"
    notify-send 'Hyprshade activated' "with $selected_filter"
else
    hyprshade off
    notify-send 'Hyprshade deactivated'
fi
