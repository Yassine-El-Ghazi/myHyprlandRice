#!/usr/bin/env bash
set -Eeuo pipefail

target_workspace=${1:-}
[[ $target_workspace =~ ^([1-9]|10)$ ]] || {
    printf 'Usage: %s {1..10}\n' "${0##*/}" >&2
    exit 2
}
for command_name in hyprctl jq; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf '%s: command not found\n' "$command_name" >&2
        exit 127
    }
done

active_workspace_json=$(hyprctl -j activeworkspace) || {
    printf 'Unable to query the active workspace.\n' >&2
    exit 1
}
current_workspace=$(jq -er '.id | numbers' <<< "$active_workspace_json") || {
    printf 'Hyprland returned an invalid active workspace.\n' >&2
    exit 1
}
[[ $current_workspace =~ ^-?[0-9]+$ ]] || {
    printf 'Hyprland returned an invalid active workspace.\n' >&2
    exit 1
}

clients_json=$(hyprctl -j clients) || {
    printf 'Unable to query Hyprland clients.\n' >&2
    exit 1
}
window_addresses_json=$(jq -ce --argjson workspace "$current_workspace" \
    '[.[] | select(.workspace.id == $workspace) | .address]' <<< "$clients_json") || {
    printf 'Hyprland returned invalid client data.\n' >&2
    exit 1
}
address_count=$(jq -er 'length' <<< "$window_addresses_json") || {
    printf 'Hyprland returned invalid client data.\n' >&2
    exit 1
}

window_addresses=()
for ((address_index = 0; address_index < address_count; address_index++)); do
    address=$(jq -er --argjson index "$address_index" '.[$index]' <<< "$window_addresses_json") || {
        printf 'Hyprland returned an invalid window address.\n' >&2
        exit 1
    }
    [[ $address =~ ^0x[0-9A-Fa-f]+$ ]] || {
        printf 'Hyprland returned an invalid window address.\n' >&2
        exit 1
    }
    window_addresses+=("$address")
done

for address in "${window_addresses[@]}"; do
    hyprctl dispatch "hl.dsp.window.move({ workspace = $target_workspace, follow = false, window = 'address:$address' })"
done
hyprctl dispatch "hl.dsp.focus({ workspace = $target_workspace })"
