#!/usr/bin/env bash
exec "${XDG_CONFIG_HOME:-$HOME/.config}/myhypr/bin/run-setting" terminal \
    --class dotfiles-floating -e \
    "${XDG_CONFIG_HOME:-$HOME/.config}/myhypr/scripts/installupdates.sh"
