#!/usr/bin/env bash
set -Eeuo pipefail

mapfile -d '' paths < <(
    find -L . -maxdepth 4 \( -type d -o -type f -o -type l \) -print0 \
        2>/dev/null
)
((${#paths[@]} > 1)) || exit 0

labels=()
for index in "${!paths[@]}"; do
    path=${paths[index]}
    [[ $path == . ]] && continue
    [[ $path != *$'\n'* && $path != *$'\t'* ]] || continue
    if [[ -d $path ]]; then
        icon=''
    elif [[ -L $path ]]; then
        icon=''
    else
        icon='󰈚'
    fi
    labels+=("$index"$'\t'"$icon $path")
done
((${#labels[@]})) || exit 0

selected=$(printf '%s\n' "${labels[@]}" | fzf \
    --style full --height 50% --layout reverse --border \
    --prompt '🔍 Finder: ' --delimiter $'\t' --with-nth 2..) || exit 0
selected_index=${selected%%$'\t'*}
[[ $selected_index =~ ^[0-9]+$ && -n ${paths[selected_index]+x} ]] || {
    printf 'Invalid finder selection.\n' >&2
    exit 1
}
selected_path=${paths[selected_index]}

if [[ -d $selected_path ]]; then
    printf 'TYPE_DIR:%s\n' "$selected_path"
    exit 0
fi

read -r -a editor_command <<< "${EDITOR:-nvim}"
((${#editor_command[@]})) || editor_command=(nvim)
command -v "${editor_command[0]}" >/dev/null 2>&1 || {
    printf 'Editor is unavailable: %s\n' "${editor_command[0]}" >&2
    exit 127
}
exec "${editor_command[@]}" "$selected_path"
