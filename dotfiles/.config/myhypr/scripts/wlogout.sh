#!/usr/bin/env bash
set -Eeuo pipefail

monitor=$(hyprctl -j monitors | jq -cer '.[] | select(.focused == true)')
res_h=$(jq -r '.height' <<< "$monitor")
h_scale=$(jq -r '.scale' <<< "$monitor" | sed 's/\.//')
[[ $res_h =~ ^[0-9]+$ && $h_scale =~ ^[0-9]+$ && $h_scale -gt 0 ]]
w_margin=$((res_h * 27 / h_scale))
exec wlogout -b 5 -T "$w_margin" -B "$w_margin"
