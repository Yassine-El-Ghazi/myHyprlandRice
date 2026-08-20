#!/usr/bin/env bash
set -Eeuo pipefail
#     _         _         __        ______
#    / \  _   _| |_ ___   \ \      / /  _ \
#   / _ \| | | | __/ _ \   \ \ /\ / /| |_) |
#  / ___ \ |_| | || (_) |   \ V  V / |  __/
# /_/   \_\__,_|\__\___/     \_/\_/  |_|
#

cache_root="$HOME/.cache/myhypr"
pid_file="$cache_root/wallpaper-automation.pid"
setting_file="$HOME/.config/myhypr/settings/wallpaper-automation.sh"
script_path=$(readlink -f -- "${BASH_SOURCE[0]}")

mkdir -p -- "$cache_root"
interval=60
if [[ -r $setting_file ]]; then
    IFS= read -r configured_interval < "$setting_file" || true
    if [[ $configured_interval =~ ^[0-9]+$ && \
        $configured_interval -ge 10 && $configured_interval -le 86400 ]]; then
        interval=$configured_interval
    fi
fi

read_running_pid() {
    local pid command_line
    [[ -r $pid_file ]] || return 1
    IFS= read -r pid < "$pid_file" || return 1
    [[ $pid =~ ^[0-9]+$ && -r /proc/$pid/cmdline ]] || return 1
    command_line=$(tr '\0' ' ' < "/proc/$pid/cmdline")
    [[ $command_line == *"$script_path --run"* ]] || return 1
    printf '%s' "$pid"
}

run_automation() {
    trap 'rm -f -- "$pid_file"' EXIT INT TERM
    printf '%s\n' "$$" > "$pid_file"
    while :; do
        waypaper --backend awww --random
        sleep "$interval"
    done
}

if [[ ${1:-} == --run ]]; then
    run_automation
    exit 0
fi

if running_pid=$(read_running_pid); then
    kill "$running_pid"
    rm -f -- "$pid_file"
    notify-send 'Wallpaper automation stopped.'
    printf ':: Wallpaper automation process %s stopped\n' "$running_pid"
    exit 0
fi

rm -f -- "$pid_file"
nohup "$script_path" --run >/dev/null 2>&1 &
notify-send 'Wallpaper automation started' \
    "Wallpaper will change every $interval seconds."
printf ':: Wallpaper automation started with a %s second interval\n' "$interval"
