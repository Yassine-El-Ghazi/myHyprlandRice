#!/usr/bin/env bash
set -Eeuo pipefail
#    ___                    
#   / _ \___ _    _____ ____
#  / ___/ _ \ |/|/ / -_) __/
# /_/   \___/__,__/\__/_/   
#                           

finish_session() {
    "$HOME/.config/myhypr/listeners.sh" --stopall || true
    systemctl --user stop myhypr-session.target || true
}

graceful_exit() {
    local requested_action=$1
    local label finish_command
    local -a arguments=()

    command -v hyprshutdown >/dev/null 2>&1 || {
        printf 'hyprshutdown is required for a safe session exit.\n' >&2
        return 1
    }
    case $requested_action in
        exit)
            label='Logging out...'
            ;;
    esac
    printf -v finish_command '%q %q' \
        "$HOME/.config/hypr/scripts/power.sh" finish-exit
    arguments=(
        --top-label "$label"
        --post-cmd "$finish_command"
    )
    hyprshutdown "${arguments[@]}"
}

action=${1:-}
case $action in
    exit|lock|reboot|shutdown|suspend|hibernate|finish-exit) ;;
    *)
        printf 'Usage: %s {exit|lock|reboot|shutdown|suspend|hibernate}\n' "${0##*/}" >&2
        exit 2
        ;;
esac

case $action in
    exit)
        graceful_exit exit
        ;;
    finish-exit)
        finish_session
        ;;
    reboot)
        systemctl reboot
        ;;
    shutdown)
        systemctl poweroff
        ;;
    lock)
        # The compositor arbitrates locks for this Wayland session. A process
        # name (even for this user) is not evidence that this session is locked.
        exec hyprlock
        ;;
    suspend)
        sleep 0.5
        systemctl suspend
        ;;
    hibernate)
        sleep 1
        systemctl hibernate
        ;;
esac
