#!/usr/bin/env bash
set -Eeuo pipefail
#    ___                    
#   / _ \___ _    _____ ____
#  / ___/ _ \ |/|/ / -_) __/
# /_/   \___/__,__/\__/_/   
#                           

finish_session() {
    local system_action=${1:-}

    "$HOME/.config/myhypr/listeners.sh" --stopall || true
    systemctl --user stop myhypr-session.target || true
    case $system_action in
        '') ;;
        reboot) systemctl reboot ;;
        poweroff) systemctl poweroff ;;
        *) return 2 ;;
    esac
}

graceful_exit() {
    local requested_action=$1
    local label finish_action finish_command
    local -a arguments=()

    command -v hyprshutdown >/dev/null 2>&1 || {
        printf 'hyprshutdown is required for a safe session exit.\n' >&2
        return 1
    }
    case $requested_action in
        exit)
            label='Logging out...'
            finish_action=finish-exit
            ;;
        reboot)
            label='Restarting...'
            finish_action=finish-reboot
            ;;
        shutdown)
            label='Shutting down...'
            finish_action=finish-poweroff
            ;;
    esac
    printf -v finish_command '%q %q' \
        "$HOME/.config/hypr/scripts/power.sh" "$finish_action"
    arguments=(
        --top-label "$label"
        --post-cmd "$finish_command"
    )
    hyprshutdown "${arguments[@]}"
}

action=${1:-}
case $action in
    exit|lock|reboot|shutdown|suspend|hibernate|finish-exit|finish-reboot|finish-poweroff) ;;
    *)
        printf 'Usage: %s {exit|lock|reboot|shutdown|suspend|hibernate}\n' "${0##*/}" >&2
        exit 2
        ;;
esac

case $action in
    exit|reboot|shutdown)
        graceful_exit "$action"
        ;;
    finish-exit)
        finish_session
        ;;
    finish-reboot)
        finish_session reboot
        ;;
    finish-poweroff)
        finish_session poweroff
        ;;
    lock)
        sleep 0.5
        pgrep -x hyprlock >/dev/null 2>&1 || hyprlock
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
