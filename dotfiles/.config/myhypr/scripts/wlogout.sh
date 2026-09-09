#!/usr/bin/env bash
set -Eeuo pipefail

# Wayland margins use logical pixels. Keep scale numeric: deleting its decimal
# point makes 1, 1.5 and 1.25 produce wildly different, often off-screen margins.
w_margin=$(hyprctl -j monitors | jq -er '
    first(.[] | select(.focused == true)) |
    select((.height | type) == "number" and (.scale | type) == "number") |
    select(.height > 0 and .scale > 0) |
    (.height / .scale * 0.27 | floor)
')
exec wlogout -b 5 -T "$w_margin" -B "$w_margin"
