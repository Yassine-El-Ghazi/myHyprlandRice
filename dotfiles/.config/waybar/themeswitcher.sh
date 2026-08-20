#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
THEME_ROOT="$CONFIG_ROOT/waybar/themes"
THEME_SETTING="$CONFIG_ROOT/myhypr/settings/waybar-theme.sh"
launcher=$(<"$CONFIG_ROOT/myhypr/settings/launcher")

declare -a labels=()
declare -a specifications=()

display_name() {
    local relative=$1
    local metadata=$2
    local name

    if [[ -r $metadata ]]; then
        IFS= read -r name < "$metadata" || true
        if [[ -n $name && $name != *$'\n'* && $name != *$'\r'* ]]; then
            printf '%s' "$name"
            return
        fi
    fi
    name=${relative//-/ }
    name=${name//\// — }
    printf '%s' "${name^}"
}

while IFS= read -r -d '' style_file; do
    style_directory=${style_file%/style.css}
    relative=${style_directory#"$THEME_ROOT/"}
    theme_name=${relative%%/*}
    [[ $theme_name != assets && -f $THEME_ROOT/$theme_name/config ]] || continue

    labels+=("$(display_name "$relative" "$style_directory/name")")
    specifications+=("/$theme_name;/$relative")
done < <(find -L "$THEME_ROOT" -mindepth 2 -maxdepth 3 -type f -name style.css -print0 | sort -z)

((${#labels[@]})) || {
    printf 'No complete Waybar themes found under %s.\n' "$THEME_ROOT" >&2
    exit 1
}

choice=-1
if [[ $launcher == walker ]] && command -v walker >/dev/null 2>&1; then
    selected=$(printf '%s\n' "${labels[@]}" | \
        "$CONFIG_ROOT/walker/launch.sh" -d -i -N -H --height 400 -p 'Waybar theme') || exit 0
    for index in "${!labels[@]}"; do
        if [[ ${labels[$index]} == "$selected" ]]; then
            choice=$index
            break
        fi
    done
else
    selected=$(printf '%s\n' "${labels[@]}" | \
        rofi -dmenu -replace -i -config "$CONFIG_ROOT/rofi/config-themes.rasi" \
            -no-show-icons -width 30 -p 'Waybar theme' -format i) || exit 0
    [[ $selected =~ ^[0-9]+$ ]] && choice=$selected
fi

((choice >= 0 && choice < ${#specifications[@]})) || exit 0
mkdir -p -- "${THEME_SETTING%/*}"
temporary=$(mktemp "${THEME_SETTING%/*}/.waybar-theme.XXXXXX")
printf '%s\n' "${specifications[$choice]}" > "$temporary"
mv -- "$temporary" "$THEME_SETTING"
exec "$CONFIG_ROOT/waybar/launch.sh"
