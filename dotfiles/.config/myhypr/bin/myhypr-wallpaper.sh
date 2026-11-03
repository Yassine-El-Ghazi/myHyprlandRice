#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
pipeline="$CONFIG_ROOT/hypr/scripts/wallpaper.sh"
mapfile -d '' -t images < <("$pipeline" --list)
(("${#images[@]}")) || {
    printf 'No supported wallpaper images found.\n' >&2
    exit 1
}

selected=
IFS= read -r -d '' selected < <(printf '%s\0' "${images[@]}" | fzf --read0 --print0 \
    --style full --height 70% --layout reverse --border \
    --prompt '🖼️ Wallpaper: ' --header 'ENTER to apply wallpaper' \
    --preview-window right:50%:wrap) || exit 0
[[ -n $selected ]] || exit 0

exec "$pipeline" "$selected"
