#!/usr/bin/env bash
set -Eeuo pipefail
#                _ _
# __      ____ _| | |_ __   __ _ _ __   ___ _ __
# \ \ /\ / / _` | | | '_ \ / _` | '_ \ / _ \ '__|
#  \ V  V / (_| | | | |_) | (_| | |_) |  __/ |
#   \_/\_/ \__,_|_|_| .__/ \__,_| .__/ \___|_|
#                   |_|         |_|
#
# -----------------------------------------------------
# Restore last wallpaper
# -----------------------------------------------------

# -----------------------------------------------------
# Set defaults
# -----------------------------------------------------

myhypr_cache_root="$HOME/.cache/myhypr"

defaultwallpaper="$HOME/.config/myhypr/wallpapers/default.jpg"

cachefile="$myhypr_cache_root/current_wallpaper"
mkdir -p -- "$myhypr_cache_root"

# -----------------------------------------------------
# Get current wallpaper
# -----------------------------------------------------

if [[ -r $cachefile ]]; then
    wallpaper=$(<"$cachefile")
    tilde='~'
    [[ $wallpaper == "$tilde/"* ]] && \
        wallpaper="$HOME/${wallpaper#"$tilde/"}"
    if [[ -f $wallpaper ]]; then
        printf ':: Wallpaper %s exists\n' "$wallpaper"
    else
        printf ':: Wallpaper %s does not exist; using the default.\n' "$wallpaper"
        wallpaper=$defaultwallpaper
    fi
else
    printf ':: %s does not exist; using the default wallpaper.\n' "$cachefile"
    wallpaper=$defaultwallpaper
fi
[[ -f $wallpaper ]] || {
    printf 'Wallpaper restore failed; image does not exist: %s\n' "$wallpaper" >&2
    exit 1
}

# -----------------------------------------------------
# Set wallpaper
# -----------------------------------------------------

printf ':: Restoring wallpaper from %s\n' "$wallpaper"
# Waypaper's awww backend starts the daemon asynchronously. Ensure its socket
# is ready first so wallpaper restore is reliable during Hyprland startup.
if ! awww query >/dev/null 2>&1; then
    awww-daemon >/dev/null 2>&1 &
fi
awww_ready=0
for _ in {1..30}; do
    if awww query >/dev/null 2>&1; then
        awww_ready=1
        break
    fi
    sleep 0.1
done
[[ $awww_ready -eq 1 ]] || {
    printf 'Awww daemon did not become ready.\n' >&2
    exit 1
}

exec waypaper --backend awww --wallpaper "$wallpaper"
