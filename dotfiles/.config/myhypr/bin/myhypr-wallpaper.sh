#!/usr/bin/env bash
# shellcheck disable=SC2016  # Keep the default path portable until expansion.
set -Eeuo pipefail

CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
# shellcheck source=/dev/null
source "$CONFIG_ROOT/myhypr/library.sh"

search_path='$HOME/.config/myhypr/wallpapers'
[[ -r $CONFIG_ROOT/myhypr/settings/wallpaper-folder ]] && \
    search_path=$(<"$CONFIG_ROOT/myhypr/settings/wallpaper-folder")
search_path=$(myhypr_expand_path "$search_path")

[[ -d $search_path ]] || {
    printf 'Wallpaper directory not found: %s\n' "$search_path" >&2
    printf 'Update ~/.config/myhypr/settings/wallpaper-folder to choose another directory.\n' >&2
    exit 1
}

mapfile -t images < <(
    find "$search_path" -maxdepth 5 -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
           -o -iname '*.webp' -o -iname '*.gif' \) -print | sort
)
((${#images[@]})) || {
    printf 'No supported images found under %s.\n' "$search_path" >&2
    exit 1
}

selected=$(printf '%s\n' "${images[@]}" | fzf \
    --style full --height 70% --layout reverse --border \
    --prompt '🖼️ Wallpaper: ' --header 'ENTER to apply with Waypaper' \
    --preview-window right:50%:wrap) || exit 0
[[ -n $selected ]] || exit 0

waypaper --backend awww --wallpaper "$selected" >/dev/null 2>&1 &
disown
