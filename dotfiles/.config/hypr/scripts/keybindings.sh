#!/usr/bin/env bash
set -Eeuo pipefail
#    __            __   _         ___             
#   / /_____ __ __/ /  (_)__  ___/ (_)__  ___ ____
#  /  '_/ -_) // / _ \/ / _ \/ _  / / _ \/ _ `(_-<
# /_/\_\\__/\_, /_.__/_/_//_/\_,_/_/_//_/\_, /___/
#          /___/                        /___/     
# 

# -----------------------------------------------------
# Get keybindings location based on variation
# -----------------------------------------------------
selector="$HOME/.config/hypr/conf/keybinding.conf"
[[ -r $selector ]] || {
    printf 'Keybinding selector is missing: %s\n' "$selector" >&2
    exit 1
}
selector_value=$(<"$selector")
variant=${selector_value##*/}
[[ $variant =~ ^[A-Za-z0-9._-]+\.conf$ ]] || {
    printf 'Invalid keybinding variant: %s\n' "$variant" >&2
    exit 1
}
config_file="$HOME/.config/hypr/conf/keybindings/$variant"
[[ -f $config_file ]] || {
    printf 'Keybinding variant does not exist: %s\n' "$config_file" >&2
    exit 1
}

# -----------------------------------------------------
# Load Launcher
# -----------------------------------------------------
launcher=rofi
launcher_file="$HOME/.config/myhypr/settings/launcher"
if [[ -r $launcher_file ]]; then
    IFS= read -r launcher < "$launcher_file" || true
fi

# -----------------------------------------------------
# Path to keybindings config file
# -----------------------------------------------------
printf 'Reading from: %s\n' "$config_file"

keybinds=$(awk -F'[=#]' '
    $1 ~ /^bind/ {
        # Replace the string "$mainMod" with "SUPER" (for the super key)
        gsub(/\$mainMod/, "SUPER", $0)

        # Remove "bind" and extra spaces, if any, at the beginning of the line
        gsub(/^bind[[:space:]]*=+[[:space:]]*/, "", $0)

        # Split the keybinding part (e.g., "Mod1,Return") using a comma
        split($1, kbarr, ",")

        # Format the keybinding and associated command and prepare for output:
        # Concatenate the two keybinding keys (e.g., "Mod1" + "Return") and append the command
        print kbarr[1] "  + " kbarr[2] "\r" $2
    }
' "$config_file")

sleep 0.2

case $launcher in
    walker)
        keybinds=$(printf '%s' "$keybinds" | tr '\r' ':')
        "$HOME/.config/walker/launch.sh" -d -N -H \
            -p 'Search Keybinds' <<< "$keybinds"
        ;;
    rofi)
        rofi -dmenu -i -markup -eh 2 -replace -p 'Keybinds' \
            -config "$HOME/.config/rofi/config-compact.rasi" <<< "$keybinds"
        ;;
    *)
        printf 'Unsupported launcher setting: %s\n' "$launcher" >&2
        exit 1
        ;;
esac
