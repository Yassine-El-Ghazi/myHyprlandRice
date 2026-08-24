#!/usr/bin/env bash
set -Eeuo pipefail

setting_file="${XDG_CONFIG_HOME:-$HOME/.config}/myhypr/settings/welcome-on-startup"
show_welcome=False
if [[ -r $setting_file ]]; then
    IFS= read -r show_welcome < "$setting_file" || true
fi
[[ $show_welcome == True ]] || exit 0
sleep 2
"${XDG_CONFIG_HOME:-$HOME/.config}/myhypr/bin/myhyprctl" welcome
