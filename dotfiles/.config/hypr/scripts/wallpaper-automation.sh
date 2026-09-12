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
    local child_pid=''

    cleanup_worker() {
        local recorded_pid=''
        if [[ -r $pid_file ]]; then
            IFS= read -r recorded_pid < "$pid_file" || true
        fi
        [[ $recorded_pid != "$$" ]] || rm -f -- "$pid_file"
    }
    stop_worker() {
        trap - INT TERM
        if [[ -n $child_pid ]] && kill -0 "$child_pid" 2>/dev/null; then
            kill "$child_pid" 2>/dev/null || true
            wait "$child_pid" 2>/dev/null || true
        fi
        exit 0
    }
    run_child() {
        local child_status
        "$@" &
        child_pid=$!
        set +e
        wait "$child_pid"
        child_status=$?
        set -e
        child_pid=''
        return "$child_status"
    }

    trap cleanup_worker EXIT
    trap stop_worker INT TERM
    printf '%s\n' "$$" > "$pid_file"
    while :; do
        run_child waypaper --backend awww --random
        run_child sleep "$interval"
    done
}

stop_automation() {
    local running_pid=$1
    local confirmed_pid=''
    local attempt

    kill "$running_pid"
    for ((attempt = 0; attempt < 40; attempt++)); do
        kill -0 "$running_pid" 2>/dev/null || break
        sleep 0.05
    done
    if kill -0 "$running_pid" 2>/dev/null; then
        confirmed_pid=$(read_running_pid || true)
        if [[ $confirmed_pid == "$running_pid" ]]; then
            kill -KILL "$running_pid"
        else
            printf 'Refusing to terminate a process no longer owned by wallpaper automation.\n' >&2
            return 1
        fi
    fi
    rm -f -- "$pid_file"
}

start_automation() {
    local attempt

    if running_pid=$(read_running_pid); then
        printf ':: Wallpaper automation is already running as process %s\n' \
            "$running_pid"
        return 0
    fi
    rm -f -- "$pid_file"
    nohup "$script_path" --run >/dev/null 2>&1 &
    for ((attempt = 0; attempt < 20; attempt++)); do
        read_running_pid >/dev/null && break
        sleep 0.05
    done
    read_running_pid >/dev/null || {
        printf 'Wallpaper automation failed to start.\n' >&2
        return 1
    }
    notify-send 'Wallpaper automation started' \
        "Wallpaper will change every $interval seconds."
    printf ':: Wallpaper automation started with a %s second interval\n' "$interval"
}

action=${1:-toggle}
case $action in
    --run)
        run_automation
        ;;
    --status)
        if running_pid=$(read_running_pid); then
            printf 'running %s\n' "$running_pid"
            exit 0
        fi
        printf 'stopped\n'
        exit 1
        ;;
    --start)
        start_automation
        ;;
    --stop)
        if running_pid=$(read_running_pid); then
            stop_automation "$running_pid"
            notify-send 'Wallpaper automation stopped.'
            printf ':: Wallpaper automation process %s stopped\n' "$running_pid"
        else
            rm -f -- "$pid_file"
            printf ':: Wallpaper automation is already stopped\n'
        fi
        ;;
    toggle)
        if running_pid=$(read_running_pid); then
            stop_automation "$running_pid"
            notify-send 'Wallpaper automation stopped.'
            printf ':: Wallpaper automation process %s stopped\n' "$running_pid"
        else
            start_automation
        fi
        ;;
    *)
        printf 'Usage: %s [--start|--stop|--status]\n' "${0##*/}" >&2
        exit 2
        ;;
esac
