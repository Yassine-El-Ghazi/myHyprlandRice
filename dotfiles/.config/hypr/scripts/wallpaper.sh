#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=/dev/null
source "$HOME/.config/myhypr/library.sh"

cache_root="$HOME/.cache/myhypr"
generated_root="$cache_root/wallpaper-generated"
cache_file="$cache_root/current_wallpaper"
recursion_marker="$cache_root/waypaper-running"
blurred_wallpaper="$cache_root/blurred_wallpaper.png"
square_wallpaper="$cache_root/square_wallpaper.png"
rofi_file="$cache_root/current_wallpaper.rasi"
default_wallpaper="$HOME/.config/myhypr/wallpapers/default.jpg"
effect_setting="$HOME/.config/myhypr/settings/wallpaper-effect.sh"
effect_helper="$HOME/.config/hypr/scripts/wallpaper-effect.sh"
blur_setting="$HOME/.config/myhypr/settings/blur.sh"
gtk_settings="$HOME/.config/gtk-3.0/settings.ini"

mkdir -p -- "$cache_root" "$generated_root"

# Waypaper invokes this script after applying an image. Applying a generated
# effect calls Waypaper once more; this marker makes that callback a no-op.
if [[ -f $recursion_marker ]]; then
    rm -f -- "$recursion_marker"
    exit 0
fi

use_cache=0
[[ -f $HOME/.config/myhypr/settings/wallpaper_cache ]] && use_cache=1
force_generate=0

wallpaper=${1:-}
if [[ -z $wallpaper && -r $cache_file ]]; then
    wallpaper=$(<"$cache_file")
fi
[[ -n $wallpaper ]] || wallpaper=$default_wallpaper
wallpaper=${wallpaper//\\ / }
tilde='~'
[[ $wallpaper == "$tilde/"* ]] && wallpaper="$HOME/${wallpaper#"$tilde/"}"
[[ -f $wallpaper ]] || {
    _writeLog "Wallpaper does not exist: $wallpaper; using the default"
    wallpaper=$default_wallpaper
}
[[ -f $wallpaper ]] || {
    printf 'Default wallpaper does not exist: %s\n' "$default_wallpaper" >&2
    exit 1
}

printf '%s\n' "$wallpaper" > "$cache_file"
wallpaper_filename=$(basename -- "$wallpaper")
used_wallpaper=$wallpaper
effect=off

if [[ -r $effect_setting ]]; then
    configured_effect=
    IFS= read -r configured_effect < "$effect_setting" || true
    [[ -z $configured_effect ]] || effect=$configured_effect
fi

if [[ $effect != off ]]; then
    mapfile -t supported_effects < <("$effect_helper" --list)
    effect_supported=0
    for supported_effect in "${supported_effects[@]}"; do
        [[ $effect == "$supported_effect" ]] && effect_supported=1
    done
    [[ $effect_supported -eq 1 ]] || {
        printf 'Unsupported wallpaper effect setting: %s\n' "$effect" >&2
        exit 1
    }

    used_wallpaper="$generated_root/$effect-$wallpaper_filename"
    if [[ ! -f $used_wallpaper || $force_generate -eq 1 || $use_cache -eq 0 ]]; then
        notify-send --replace-id=1 "Using wallpaper effect $effect" \
            "$wallpaper_filename" -h int:value:33
        "$effect_helper" "$effect" "$wallpaper" "$used_wallpaper"
    fi

    : > "$recursion_marker"
    if ! waypaper --backend awww --wallpaper "$used_wallpaper"; then
        rm -f -- "$recursion_marker"
        exit 1
    fi
fi

theme_mode=light
if [[ -r $gtk_settings ]]; then
    theme_preference=$(awk -F= \
        '$1 == "gtk-application-prefer-dark-theme" {print $2; exit}' \
        "$gtk_settings")
    [[ $theme_preference == 1 || $theme_preference == true ]] && theme_mode=dark
fi

if command -v matugen >/dev/null 2>&1; then
    matugen image "$used_wallpaper" -m "$theme_mode"
else
    _writeLog 'matugen is not installed; color generation was skipped'
fi

"$HOME/.config/waybar/launch.sh"
"$HOME/.config/nwg-dock-hyprland/launch.sh" &
command -v pywalfox >/dev/null 2>&1 && pywalfox update
swaync-client -rs

blur=50x30
if [[ -r $blur_setting ]]; then
    IFS= read -r blur < "$blur_setting" || true
fi
[[ $blur =~ ^[0-9]+x[0-9]+$ ]] || {
    printf 'Invalid blur setting: %s\n' "$blur" >&2
    exit 1
}

blur_cache="$generated_root/blur-$blur-$effect-$wallpaper_filename.png"
if [[ ! -f $blur_cache || $force_generate -eq 1 || $use_cache -eq 0 ]]; then
    magick "$used_wallpaper" -resize 75% "$blurred_wallpaper"
    if [[ $blur != 0x0 ]]; then
        magick "$blurred_wallpaper" -blur "$blur" "$blurred_wallpaper"
    fi
    cp -- "$blurred_wallpaper" "$blur_cache"
fi
cp -- "$blur_cache" "$blurred_wallpaper"
printf '* { current-image: url("%s", height); }\n' "$blurred_wallpaper" \
    > "$rofi_file"

magick "$wallpaper" -gravity Center -extent 1:1 "$square_wallpaper"
cp -- "$square_wallpaper" "$generated_root/square-$wallpaper_filename.png"

rm -f -- "$recursion_marker"
_writeLog "Wallpaper and adaptive colors applied from $wallpaper"
