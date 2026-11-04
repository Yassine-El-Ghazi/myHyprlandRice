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

printf 'Monitoring GTK settings for changes.\n'

# Function to apply the theme based on the current settings
apply_theme() {
    # Check if the settings file exists
    if [[ ! -f $SETTINGS_FILE ]]; then
        printf 'Error: GTK settings file not found.\n' >&2
        return 1
    fi

    # Extract the value of gtk-application-prefer-dark-theme
    # We use grep to find the line and awk to get the value after the '='
    local theme_pref
    local result=0
    theme_pref=$(awk -F= '$1 == "gtk-application-prefer-dark-theme" {print $2; exit}' "$SETTINGS_FILE" 2>/dev/null) || {
        printf 'Unable to read GTK color preference.\n' >&2
        return 1
    }

    if [[ -z $theme_pref ]]; then
        printf 'GTK color preference is not set; skipping.\n' >&2
        return 0
    fi

    case $theme_pref in
        1|true) ;;
        0|false) ;;
        *)
            printf 'Unexpected GTK color preference; expected true/false or 1/0.\n' >&2
            return 1
            ;;
    esac
    # Keep the desktop toolkit preference synchronized even when adaptive
    # wallpaper color generation is temporarily unavailable.
    if ! "$HOME/.config/hypr/scripts/gtk.sh" >/dev/null 2>&1; then
        printf 'GTK toolkit update failed.\n' >&2
        result=1
    fi
    [[ -r $HOME/.cache/myhypr/current_wallpaper ]] || return "$result"
    "$HOME/.config/hypr/scripts/wallpaper.sh" --refresh || result=1
    return "$result"
}

# Loop indefinitely, reading output from inotifywait
if ! inotifywait -m -q -e close_write,moved_to "$SETTINGS_DIR" 2>/dev/null | while read -r _directory _events filename; do
    if [[ "$filename" == "$SETTINGS_BASENAME" ]]; then
        printf 'GTK settings changed; reapplying theme.\n'
        if ! apply_theme; then
            printf 'Theme update failed; continuing to monitor GTK settings.\n' >&2
        fi
    fi
done
then
    printf 'GTK settings monitoring failed.\n' >&2
    exit 1
fi
