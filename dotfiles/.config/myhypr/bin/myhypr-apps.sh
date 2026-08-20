#!/usr/bin/env bash
set -Eeuo pipefail

include_terminal_apps=true
declare -a application_directories=(
    "$HOME/.local/share/applications"
    "$HOME/.local/share/flatpak/exports/share/applications"
    /var/lib/flatpak/exports/share/applications
    /usr/share/applications
)
declare -a entries=()
declare -A seen_ids=()

desktop_value() {
    local key=$1
    local file=$2
    sed -n "s/^${key}=//p" "$file" | head -n 1
}

for directory in "${application_directories[@]}"; do
    [[ -d $directory ]] || continue
    while IFS= read -r -d '' desktop_file; do
        desktop_id=${desktop_file##*/}
        [[ -z ${seen_ids[$desktop_id]+x} ]] || continue
        seen_ids[$desktop_id]=1

        name=$(desktop_value Name "$desktop_file")
        hidden=$(desktop_value Hidden "$desktop_file")
        no_display=$(desktop_value NoDisplay "$desktop_file")
        terminal=$(desktop_value Terminal "$desktop_file")
        terminal=${terminal,,}
        [[ -n $name && ${hidden,,} != true && ${no_display,,} != true ]] || continue
        [[ $include_terminal_apps == true || ${terminal,,} != true ]] || continue

        icon='󰀻'
        [[ $terminal == true ]] && icon=''
        [[ $desktop_file == *flatpak* ]] && icon='󰏖'
        entries+=("$icon $name | $desktop_id")
    done < <(find -L "$directory" -maxdepth 1 -type f -name '*.desktop' -print0)
done

((${#entries[@]})) || {
    printf 'No launchable desktop applications were found.\n' >&2
    exit 1
}

selected=$(printf '%s\n' "${entries[@]}" | sort -f | fzf \
    --style full --delimiter '|' --with-nth 1 \
    --height 40% --layout reverse --border \
    --prompt '🚀 Run: ' \
    --header '󰀻 System | 󰏖 Flatpak |  Terminal') || exit 0
[[ -n $selected ]] || exit 0

desktop_id=${selected##*| }
[[ $desktop_id =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*\.desktop$ ]] || {
    printf 'Invalid desktop application identifier: %s\n' "$desktop_id" >&2
    exit 1
}

setsid gtk-launch "${desktop_id%.desktop}" >/dev/null 2>&1 &
disown
