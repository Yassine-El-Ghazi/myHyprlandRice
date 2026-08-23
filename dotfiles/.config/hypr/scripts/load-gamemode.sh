#!/usr/bin/env bash
set -Eeuo pipefail
#                                      __   
#   ___ ____ ___ _  ___ __ _  ___  ___/ /__ 
#  / _ `/ _ `/  ' \/ -_)  ' \/ _ \/ _  / -_)
#  \_, /\_,_/_/_/_/\__/_/_/_/\___/\_,_/\__/ 
# /___/                                     
# 

_loadGameMode() {
    hyprctl eval 'hl.config({ animations = { enabled = false }, decoration = { shadow = { enabled = false }, blur = { enabled = false }, rounding = 0 }, general = { gaps_in = 0, gaps_out = 0, border_size = 1 } })'
}

if [[ -f $HOME/.config/myhypr/settings/gamemode-enabled ]]; then
    _loadGameMode
    notify-send "Gamemode activated" "Animations and blur disabled"
fi
