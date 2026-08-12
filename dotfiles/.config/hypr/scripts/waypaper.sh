#!/usr/bin/env bash
if [ -f /usr/bin/waypaper ]; then
    echo ":: Launching waypaper in /usr/bin"
    waypaper --backend awww "$@" &
elif [ -f "$HOME/.local/bin/waypaper" ]; then
    echo ":: Launching waypaper in $HOME/.local/bin"
    "$HOME/.local/bin/waypaper" --backend awww "$@" &
else
    echo ":: waypaper not found"
fi
