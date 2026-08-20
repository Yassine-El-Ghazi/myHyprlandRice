#!/usr/bin/env bash
set -Eeuo pipefail

# -----------------------------------------------------
# Load Launcher
# -----------------------------------------------------
launcher_file="$HOME/.config/myhypr/settings/launcher"
launcher=rofi
[[ -r $launcher_file ]] && IFS= read -r launcher < "$launcher_file"

# Use Walker
_launch_walker() {
    exec "$HOME/.config/walker/launch.sh" --height 500
}

# Use Rofi
_launch_rofi() {
    if pgrep -x rofi >/dev/null 2>&1; then
        pkill -x rofi
    else
        exec rofi -show drun -replace -i
    fi
}

case $launcher in
    walker) _launch_walker ;;
    rofi) _launch_rofi ;;
    *)
        printf 'Unsupported launcher setting: %s\n' "$launcher" >&2
        exit 1
        ;;
esac
