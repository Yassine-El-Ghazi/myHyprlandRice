#!/usr/bin/env bash
set -Eeuo pipefail

for command_name in hyprctl jq rofi; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'Window focus requires %s. Run the desktop bootstrap.\n' \
            "$command_name" >&2
        exit 1
    }
done

clients=$(hyprctl -j clients | jq -cer \
    '[.[] | select(.mapped == true and .hidden == false)]')
client_count=$(jq 'length' <<< "$clients")
((client_count > 0)) || {
    printf 'No active windows found.\n'
    exit 0
}

mapfile -t labels < <(
    jq -r '.[] |
        ((.title // .class // "Untitled") | gsub("[\\r\\n\\t]"; " ")) as $title |
        "[workspace \(.workspace.id)] \($title)"' <<< "$clients"
)

selected_index=$(printf '%s\n' "${labels[@]}" | rofi -dmenu \
    -config "$HOME/.config/rofi/config-compact.rasi" -no-show-icons \
    -no-custom -i -format i -p 'Active Window') || exit 0
[[ $selected_index =~ ^[0-9]+$ && $selected_index -lt $client_count ]] || {
    printf 'Invalid window selection index: %s\n' "$selected_index" >&2
    exit 1
}

selected_address=$(jq -er ".[$selected_index].address" <<< "$clients")
[[ $selected_address =~ ^0x[0-9A-Fa-f]+$ ]] || {
    printf 'Invalid Hyprland window address: %s\n' "$selected_address" >&2
    exit 1
}

exec hyprctl dispatch "hl.dsp.focus({ window = 'address:$selected_address' })"
