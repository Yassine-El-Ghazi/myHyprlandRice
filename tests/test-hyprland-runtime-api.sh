#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd -- "$REPO_ROOT"
runtime_files=(
    dotfiles/.config/myhypr/scripts/focus.sh
    dotfiles/.config/hypr/scripts/moveTo.sh
    dotfiles/.config/hypr/scripts/cursor-zoom.sh
    dotfiles/.config/hypr/scripts/toggle-animations.sh
    dotfiles/.config/hypr/scripts/gamemode.sh
    dotfiles/.config/hypr/scripts/load-gamemode.sh
    dotfiles/.config/hypr/scripts/toggle-refresh.sh
    dotfiles/.config/hypr/scripts/toggleallfloat.sh
    dotfiles/.config/hypr/scripts/power.sh
    dotfiles/.config/hypr/hypridle.conf
    dotfiles/.config/waybar/modules.json
    dotfiles/.config/sidepad/sidepad
    dotfiles/.config/wlogout/README.txt
)

fail() {
    printf 'Hyprland runtime API guard failed: %s\n' "$*" >&2
    exit 1
}

if rg -n 'hyprctl[[:space:]]+(--batch|keyword)|workspaceopt' "${runtime_files[@]}"; then
    fail 'a deprecated Hyprland runtime action remains'
fi

while IFS= read -r line; do
    [[ $line == *'hl.dsp.'* ]] || fail "token-based dispatcher remains: $line"
done < <(rg 'hyprctl[[:space:]]+dispatch' "${runtime_files[@]}")

while IFS= read -r line; do
    [[ $line == *'hl.config('* || $line == *'hl.monitor('* || $line == *"require('conf.runtime_actions')"* ]] || \
        fail "unapproved hyprctl eval expression: $line"
done < <(rg 'hyprctl[[:space:]]+eval' "${runtime_files[@]}")

hypridle=dotfiles/.config/hypr/hypridle.conf
modules=dotfiles/.config/waybar/modules.json
power=dotfiles/.config/hypr/scripts/power.sh
wlogout=dotfiles/.config/wlogout/README.txt
doctor=scripts/doctor.sh

rg -Fq "after_sleep_cmd = hyprctl dispatch \"hl.dsp.dpms({ action = 'on' })\"" "$hypridle" || \
    fail 'after-sleep DPMS-on action is not exact'
rg -Fq "on-timeout = hyprctl dispatch \"hl.dsp.dpms({ action = 'off' })\"" "$hypridle" || \
    fail 'idle-timeout DPMS-off action is not exact'
rg -Fq "on-resume = hyprctl dispatch \"hl.dsp.dpms({ action = 'on' })\" && brightnessctl -r" "$hypridle" || \
    fail 'brightness restore is not chained after successful DPMS-on'
rg -Fq "\"on-scroll-up\": \"hyprctl dispatch \\\"hl.dsp.focus({ workspace = 'r-1' })\\\"\"" "$modules" || \
    fail 'Waybar scroll-up typed focus is not exact'
rg -Fq "\"on-scroll-down\": \"hyprctl dispatch \\\"hl.dsp.focus({ workspace = 'r+1' })\\\"\"" "$modules" || \
    fail 'Waybar scroll-down typed focus is not exact'
rg -Fq "hyprctl dispatch 'hl.dsp.exit()'" "$power" || fail 'power helper typed exit is missing'
rg -Fq "sleep 1; hyprctl dispatch 'hl.dsp.exit()'" "$wlogout" || fail 'wlogout typed exit example is missing'
rg -Fq "hyprctl dispatch 'hl.dsp.no_op()' >/dev/null 2>&1" "$doctor" || \
    fail 'doctor no-op capability probe is missing'
rg -Fq "hyprctl eval 'assert(type(hl.config) == \"function\" and type(hl.monitor) == \"function\" and type(hl.dsp.window.move) == \"function\")' >/dev/null 2>&1" "$doctor" || \
    fail 'doctor typed API capability assertion is missing'

printf 'All active Hyprland runtime mutations use approved typed Lua APIs.\n'
