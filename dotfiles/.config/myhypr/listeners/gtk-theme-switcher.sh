#!/usr/bin/env bash
set -Eeuo pipefail

# This script monitors changes to the GTK settings.ini file
# and automatically switches the 'matugen' theme between light and dark
# based on the 'gtk-application-prefer-dark-theme' setting.

# Path to the GTK settings file
SETTINGS_FILE="$HOME/.config/gtk-3.0/settings.ini"
SETTINGS_DIR="$HOME/.config/gtk-3.0"
SETTINGS_BASENAME=$(basename "$SETTINGS_FILE")

# Ensure inotify-tools is installed
if ! command -v inotifywait >/dev/null 2>&1; then
    printf '%s\n' 'Error: inotifywait is not installed. Run the desktop bootstrap.' >&2
    exit 1
fi

printf 'Monitoring %s for changes...\n' "$SETTINGS_FILE"

# Function to apply the theme based on the current settings
apply_theme() {
    # Check if the settings file exists
    if [[ ! -f $SETTINGS_FILE ]]; then
        printf 'Error: GTK settings file not found: %s\n' "$SETTINGS_FILE" >&2
        return 1
    fi

    # Extract the value of gtk-application-prefer-dark-theme
    # We use grep to find the line and awk to get the value after the '='
    local theme_pref wallpaper
    local -a mode_args=(-m light)
    theme_pref=$(awk -F= '$1 == "gtk-application-prefer-dark-theme" {print $2; exit}' "$SETTINGS_FILE")

    if [[ -z $theme_pref ]]; then
        printf 'GTK color preference is not set in %s; skipping.\n' \
            "$SETTINGS_FILE" >&2
        return 0
    fi

    case $theme_pref in
        1|true) mode_args=(-m dark) ;;
        0|false) ;;
        *)
            printf 'Unexpected GTK color preference: %s\n' "$theme_pref" >&2
            return 1
            ;;
    esac
    [[ -r $HOME/.cache/myhypr/current_wallpaper ]] || return 0
    wallpaper=$(<"$HOME/.cache/myhypr/current_wallpaper")
    [[ -f $wallpaper ]] || return 0

    matugen image "$wallpaper" "${mode_args[@]}"
    "$HOME/.config/nwg-dock-hyprland/launch.sh" &
    "$HOME/.config/waybar/launch.sh" &
    "$HOME/.config/hypr/scripts/gtk.sh" &
    swaync-client -rs
}

# Loop indefinitely, reading output from inotifywait
inotifywait -m -q -e close_write,moved_to "$SETTINGS_DIR" | while read -r _directory _events filename; do
    if [[ "$filename" == "$SETTINGS_BASENAME" ]]; then
        printf 'Change detected in %s; reapplying theme.\n' "$SETTINGS_FILE"
        apply_theme
    fi
done
