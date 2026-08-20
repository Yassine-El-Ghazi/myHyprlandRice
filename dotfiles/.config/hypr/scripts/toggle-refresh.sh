#!/usr/bin/env bash
set -Eeuo pipefail

action=${1:-toggle}
case $action in
    low|high|toggle) ;;
    *)
        printf 'Usage: %s [low|high|toggle]\n' "${0##*/}" >&2
        exit 2
        ;;
esac

for command_name in hyprctl jq; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf '%s: command not found\n' "$command_name" >&2
        exit 127
    fi
done

query_file=$(mktemp "${TMPDIR:-/tmp}/myhypr-monitor.XXXXXXXX")
cleanup() {
    case $query_file in
        "${TMPDIR:-/tmp}"/myhypr-monitor.*) rm -f -- "$query_file" ;;
    esac
}
trap cleanup EXIT

monitor_json=''
for _attempt in 1 2 3 4 5; do
    if hyprctl monitors -j 2>/dev/null | \
        jq -ce 'map(select(.focused))[0] // .[0]' > "$query_file" 2>/dev/null; then
        monitor_json=$(<"$query_file")
        break
    fi
    sleep 1
done
if [[ -z $monitor_json ]]; then
    printf 'Unable to query a focused Hyprland monitor.\n' >&2
    exit 1
fi
name=$(jq -r '.name' <<< "$monitor_json")
width=$(jq -r '.width' <<< "$monitor_json")
height=$(jq -r '.height' <<< "$monitor_json")
current_rate=$(jq -r '.refreshRate' <<< "$monitor_json")
position=$(jq -r '(.x | tostring) + "x" + (.y | tostring)' <<< "$monitor_json")
scale=$(jq -r '.scale' <<< "$monitor_json")
transform=$(jq -r '.transform // 0' <<< "$monitor_json")

mapfile -t rates < <(
    jq -r --arg resolution "${width}x${height}" '
        .availableModes[]
        | capture("^" + $resolution + "@(?<rate>[0-9.]+)Hz?$")
        | .rate
    ' <<< "$monitor_json" | sort -n -u
)

if ((${#rates[@]} == 0)); then
    printf 'No refresh-rate modes found for %s at %sx%s.\n' "$name" "$width" "$height" >&2
    exit 1
fi

low_rate=${rates[0]}
high_rate=${rates[${#rates[@]} - 1]}
case $action in
    low) target_rate=$low_rate ;;
    high) target_rate=$high_rate ;;
    toggle)
        target_rate=$(awk -v current="$current_rate" -v low="$low_rate" -v high="$high_rate" \
            'BEGIN { midpoint = (low + high) / 2; print current >= midpoint ? low : high }')
        ;;
esac

if awk -v current="$current_rate" -v target="$target_rate" \
    'BEGIN { difference = current - target; if (difference < 0) difference = -difference; exit difference < 0.01 ? 0 : 1 }'; then
    hyprctl notify 5 1800 'rgb(89b4fa)' "$name is already at ${target_rate}Hz"
    exit 0
fi

monitor_rule="$name,${width}x${height}@${target_rate},$position,$scale,transform,$transform"
hyprctl keyword monitor "$monitor_rule"
hyprctl notify 5 2500 'rgb(a6e3a1)' "$name switched to ${target_rate}Hz"
