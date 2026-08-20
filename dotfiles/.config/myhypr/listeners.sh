#!/usr/bin/env bash
set -Eeuo pipefail

declare -Ar LISTENERS=(
    [gtk-theme-switcher]="$HOME/.config/myhypr/listeners/gtk-theme-switcher.sh"
    [low-bat-notification]="$HOME/.config/myhypr/listeners/low-bat-notification.sh"
)

# Function to start a specific listener script
start_listener() {
    local script_name=$1
    local script_path="${LISTENERS[$script_name]:-}"
    local -a arguments=()
    local -a pids=()

    [[ -n ${2:-} ]] && arguments+=("$2")

    if [[ -z $script_path ]]; then
        printf "Error: Listener '%s' is not registered.\n" "$script_name" >&2
        return 1
    fi

    printf "Attempting to start '%s'...\n" "$script_name"

    if [[ ! -f $script_path ]]; then
        printf "Error: Script '%s' was not found for '%s'.\n" \
            "$script_path" "$script_name" >&2
        return 1
    fi
    if [[ ! -x $script_path ]]; then
        printf "Error: Script '%s' is not executable.\n" "$script_path" >&2
        return 1
    fi

    mapfile -t pids < <(pgrep -f -- "$script_path" || true)
    if ((${#pids[@]})); then
        printf "Listener '%s' is already running (PID: %s).\n" \
            "$script_name" "${pids[*]}"
        return 0
    fi

    nohup "$script_path" "${arguments[@]}" >/dev/null 2>&1 &
    printf "Listener '%s' started successfully.\n" "$script_name"
}

# Function to stop a specific listener script
stop_listener() {
    local script_name=$1
    local script_path="${LISTENERS[$script_name]:-}"
    local -a pids remaining

    if [[ -z $script_path ]]; then
        printf "Error: Listener '%s' is not registered.\n" "$script_name" >&2
        return 1
    fi

    printf "Attempting to stop '%s'...\n" "$script_name"
    mapfile -t pids < <(pgrep -f -- "$script_path" || true)

    if ((${#pids[@]} == 0)); then
        printf "Listener '%s' is not running.\n" "$script_name"
        return 0
    fi

    printf "Found PID(s) for '%s': %s. Sending SIGTERM...\n" \
        "$script_name" "${pids[*]}"
    kill -- "${pids[@]}"
    sleep 1
    mapfile -t remaining < <(pgrep -f -- "$script_path" || true)
    if ((${#remaining[@]})); then
        printf "Listener '%s' did not stop; sending SIGKILL.\n" "$script_name"
        kill -KILL -- "${remaining[@]}"
    fi
    printf "Listener '%s' stopped.\n" "$script_name"
}

# Function to restart a specific listener script
restart_listener() {
    local script_name=$1
    printf "Attempting to restart '%s'...\n" "$script_name"
    stop_listener "$script_name"
    start_listener "$script_name"
}

# Main script logic based on command-line arguments
case "${1:-}" in
--startall)
    printf '%s\n' 'Starting all registered listeners...'
    for key in "${!LISTENERS[@]}"; do
        start_listener "$key"
    done
    printf '%s\n' 'All registered listeners processed.'
    ;;
--stopall)
    printf '%s\n' 'Stopping all registered listeners...'
    for key in "${!LISTENERS[@]}"; do
        stop_listener "$key"
    done
    printf '%s\n' 'All registered listeners processed.'
    ;;
--restartall)
    printf '%s\n' 'Restarting all registered listeners...'
    for key in "${!LISTENERS[@]}"; do
        restart_listener "$key"
    done
    printf '%s\n' 'All registered listeners processed.'
    ;;
--start)
    if [[ -z ${2:-} ]]; then
        printf 'Error: Missing listener name for --start.\n' >&2
        printf 'Usage: %s --start <listener_name>\n' "$0" >&2
        exit 1
    fi
    start_listener "$2"
    ;;
--stop)
    if [[ -z ${2:-} ]]; then
        printf 'Error: Missing listener name for --stop.\n' >&2
        printf 'Usage: %s --stop <listener_name>\n' "$0" >&2
        exit 1
    fi
    stop_listener "$2"
    ;;
--restart)
    if [[ -z ${2:-} ]]; then
        printf 'Error: Missing listener name for --restart.\n' >&2
        printf 'Usage: %s --restart <listener_name>\n' "$0" >&2
        exit 1
    fi
    restart_listener "$2"
    ;;
*)
    printf 'Usage: %s [--startall | --stopall | --restartall | --start NAME | --stop NAME | --restart NAME]\n' "$0" >&2
    printf '\nRegistered listeners:\n' >&2
    for key in "${!LISTENERS[@]}"; do
        printf '  - %s\n' "$key" >&2
    done
    exit 1
    ;;
esac
