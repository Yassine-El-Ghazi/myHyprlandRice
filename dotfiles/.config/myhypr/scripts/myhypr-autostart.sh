#!/usr/bin/env bash
set -Eeuo pipefail

setting_file="${XDG_CONFIG_HOME:-$HOME/.config}/myhypr/settings/welcome-on-startup"
IFS= read -r show_welcome < "$setting_file" || show_welcome=False
[[ $show_welcome == True ]] || exit 0
sleep 2
"${XDG_CONFIG_HOME:-$HOME/.config}/myhypr/bin/myhyprctl" welcome
