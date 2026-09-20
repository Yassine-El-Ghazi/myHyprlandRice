#!/bin/bash
set -Eeuo pipefail
#    __ __              _    ____   
#   / // /_ _____  ____(_)__/ / /__ 
#  / _  / // / _ \/ __/ / _  / / -_)
# /_//_/\_, / .__/_/ /_/\_,_/_/\__/ 
#      /___/_/                      
# 

SERVICE="hypridle"

start_idle() {
    # A Waybar restart must not terminate the daemon started by this button.
    "${XDG_CONFIG_HOME:-$HOME/.config}/myhypr/bin/launch-app" "$SERVICE" >/dev/null &
}

print_status() {
    if pgrep -u "$UID" -x "$SERVICE" >/dev/null ; then
        printf '%s\n' '{"text": "RUNNING", "class": "active", "tooltip": "Screen locking active\nLeft: Deactivate\nRight: Lock Screen"}'
    else
        printf '%s\n' '{"text": "NOT RUNNING", "class": "notactive", "tooltip": "Screen locking deactivated\nLeft: Activate\nRight: Lock Screen"}'
    fi
}

case "${1:-}" in
    status)
        # Add a tiny delay to avoid race condition on startup
        sleep 0.2
        print_status
        ;;
    toggle)
        if pgrep -u "$UID" -x "$SERVICE" >/dev/null ; then
            pkill -u "$UID" -x "$SERVICE"
        else
            start_idle
        fi
        # Give it a moment to start/stop before checking again
        sleep 0.2
        print_status
        ;;
    restart)
        pkill -u "$UID" -x "$SERVICE" || true
        sleep 1
        start_idle
        ;;
    *)
        echo "Usage: $0 {status|toggle|restart}"
        exit 1
        ;;
esac
