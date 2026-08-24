#!/usr/bin/env bash
set -Eeuo pipefail
#                                 __        __ 
#   ___ ___________ ___ ___  ___ / /  ___  / /_
#  (_-</ __/ __/ -_) -_) _ \(_-</ _ \/ _ \/ __/
# /___/\__/_/  \__/\__/_//_/___/_//_/\___/\__/ 
#                                              
# Based on https://github.com/hyprwm/contrib/blob/main/grimblast/screenshot.sh

# -----------------------------------------------------

# Screenshots will be stored in $HOME by default.
# The screenshot will be moved into the screenshot directory

# Add this to ~/.config/user-dirs.dirs to save screenshots in a custom folder:
# XDG_SCREENSHOTS_DIR="$HOME/Screenshots"

CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
# shellcheck source=/dev/null
source "$CONFIG_ROOT/myhypr/library.sh"

SAVE_DIR=$(<"$CONFIG_ROOT/myhypr/settings/screenshot-folder")
SAVE_FILENAME=$(<"$CONFIG_ROOT/myhypr/settings/screenshot-filename")
screenshot_folder=$(myhypr_expand_path "$SAVE_DIR")
NAME=$(myhypr_render_filename "$SAVE_FILENAME")
output_path="$screenshot_folder/$NAME"
mkdir -p -- "$screenshot_folder"

# Screenshot Editor
GRIMBLAST_EDITOR=$(<"$CONFIG_ROOT/myhypr/settings/screenshot-editor")
export GRIMBLAST_EDITOR

# Example for keybindings
# bind = SUPER, p, exec, grimblast save active
# bind = SUPER SHIFT, p, exec, grimblast save area
# bind = SUPER ALT, p, exec, grimblast save output
# bind = SUPER CTRL, p, exec, grimblast save screen

# Quick instant mode: full screen
take_instant_full() {
    grim "$output_path" && notify-send -t 1000 "Screenshot saved to $output_path"
}

# Quick instant mode: area selection
take_instant_area() {
    local pid_picker region

    # freeze screen for region selection
    hyprpicker -r -z &
    pid_picker=$!
    trap 'kill "$pid_picker" 2>/dev/null' EXIT
    sleep 0.1

    # user selects region; kill picker on cancel
    region=$(slurp -b "#00000080" -c "#888888ff" -w 1) || exit 0
    [[ -z "$region" ]] && exit 0

    # unfreeze screen
    kill "$pid_picker" 2>/dev/null
    trap - EXIT

    # capture and notify
    grim -g "$region" "$output_path" && notify-send -t 1000 "Screenshot saved to $output_path"
}

# Handle instant flags
mode=${1:-}
case $mode in
    --instant)
        take_instant_full
        exit 0
        ;;
    --instant-area)
        take_instant_area
        exit 0
        ;;
esac

# Options
option_1="Immediate"
option_2="Delayed"

option_capture_1="Capture Everything"
option_capture_2="Capture Active Display"
option_capture_3="Capture Selection"

option_time_1="5s"
option_time_2="10s"
option_time_3="20s"
option_time_4="30s"
option_time_5="60s"
#option_time_4="Custom (in seconds)" # Roadmap or someone contribute :)

copy='Copy'
save='Save'
copy_save='Copy & Save'
edit='Edit'

# Rofi CMD
rofi_cmd() {
    rofi -dmenu -replace -config ~/.config/rofi/config-screenshot.rasi -i -no-show-icons -l 2 -width 30 -p "Take screenshot"
}

# Pass variables to rofi dmenu
run_rofi() {
    echo -e "$option_1\n$option_2" | rofi_cmd
}

####
# Choose Timer
# CMD
timer_cmd() {
    rofi -dmenu -replace -config ~/.config/rofi/config-screenshot.rasi -i -no-show-icons -l 5 -width 30 -p "Choose timer"
}

# Ask for confirmation
timer_exit() {
    echo -e "$option_time_1\n$option_time_2\n$option_time_3\n$option_time_4\n$option_time_5" | timer_cmd
}

# Confirm and execute
timer_run() {
    selected_timer="$(timer_exit)"
    if [[ "$selected_timer" == "$option_time_1" ]]; then
        countdown=5
    elif [[ "$selected_timer" == "$option_time_2" ]]; then
        countdown=10
    elif [[ "$selected_timer" == "$option_time_3" ]]; then
        countdown=20
    elif [[ "$selected_timer" == "$option_time_4" ]]; then
        countdown=30
    elif [[ "$selected_timer" == "$option_time_5" ]]; then
        countdown=60
    else
        exit
    fi
}
###

####
# Chose Screenshot Type
# CMD
type_screenshot_cmd() {
    rofi -dmenu -replace -config ~/.config/rofi/config-screenshot.rasi -i -no-show-icons -l 3 -width 30 -p "Type of screenshot"
}

# Ask for confirmation
type_screenshot_exit() {
    echo -e "$option_capture_1\n$option_capture_2\n$option_capture_3" | type_screenshot_cmd
}

# Confirm and execute
type_screenshot_run() {
    selected_type_screenshot="$(type_screenshot_exit)"
    if [[ "$selected_type_screenshot" == "$option_capture_1" ]]; then
        option_type_screenshot=screen
    elif [[ "$selected_type_screenshot" == "$option_capture_2" ]]; then
        option_type_screenshot=output
    elif [[ "$selected_type_screenshot" == "$option_capture_3" ]]; then
        option_type_screenshot=area
    else
        exit
    fi
}
###

####
# Choose to save or copy photo
# CMD
copy_save_editor_cmd() {
    rofi -dmenu -replace -config ~/.config/rofi/config-screenshot.rasi -i -no-show-icons -l 4 -width 30 -p "How to save"
}

# Ask for confirmation
copy_save_editor_exit() {
    echo -e "$copy\n$save\n$copy_save\n$edit" | copy_save_editor_cmd
}

# Confirm and execute
copy_save_editor_run() {
    selected_chosen="$(copy_save_editor_exit)"
    if [[ "$selected_chosen" == "$copy" ]]; then
        option_chosen=copy
        "$1"
    elif [[ "$selected_chosen" == "$save" ]]; then
        option_chosen=save
        "$1"
    elif [[ "$selected_chosen" == "$copy_save" ]]; then
        option_chosen=copysave
        "$1"
    elif [[ "$selected_chosen" == "$edit" ]]; then
        option_chosen=edit
        "$1"
    else
        exit
    fi
}
###

timer() {
    if [[ $countdown -gt 10 ]]; then
        notify-send -t 1000 "Taking screenshot in ${countdown} seconds"
        countdown_less_10=$((countdown - 10))
        sleep "$countdown_less_10"
        countdown=10
    fi
    while [[ $countdown -ne 0 ]]; do
        notify-send -t 1000 "Taking screenshot in ${countdown} seconds"
        countdown=$((countdown - 1))
        sleep 1
    done
}

# take shots
takescreenshot() {
    sleep 1
    grimblast --notify "$option_chosen" "$option_type_screenshot" "$output_path"
}

takescreenshot_timer() {
    sleep 1
    timer
    sleep 1
    grimblast --notify "$option_chosen" "$option_type_screenshot" "$output_path"
}

# Execute Command
run_cmd() {
    if [[ "$1" == '--opt1' ]]; then
        type_screenshot_run
        copy_save_editor_run "takescreenshot"
    elif [[ "$1" == '--opt2' ]]; then
        timer_run
        type_screenshot_run
        copy_save_editor_run "takescreenshot_timer"
    fi
}

# Actions
chosen="$(run_rofi)"
case ${chosen} in
    "$option_1")
        run_cmd --opt1
        ;;
    "$option_2")
        run_cmd --opt2
        ;;
esac
