#!/usr/bin/env bash
set -Eeuo pipefail

launch_mode=managed
case ${1:-} in
    '') ;;
    --direct) launch_mode=direct ;;
    --service) launch_mode=service ;;
    *) printf 'Usage: %s [--direct|--service]\n' "$0" >&2; exit 2 ;;
esac

if [[ $launch_mode == managed ]] && command -v systemctl >/dev/null 2>&1 && \
    systemctl --user cat myhypr-waybar.service >/dev/null 2>&1; then
    systemctl --user restart myhypr-waybar.service
    exit 0
fi

CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
THEME_ROOT="$CONFIG_ROOT/waybar/themes"
THEME_SETTING="$CONFIG_ROOT/myhypr/settings/waybar-theme.sh"
SETTINGS_ROOT="$CONFIG_ROOT/myhypr/settings"
CONFIG_GENERATOR="$CONFIG_ROOT/waybar/generate-config.py"
DEFAULT_THEME='/myhypr-modern;/myhypr-modern/default'
LOCK_ROOT="${XDG_RUNTIME_DIR:-$HOME/.cache/myhypr}"

mkdir -p -- "$LOCK_ROOT" "${THEME_SETTING%/*}"
exec {LOCK_FD}>"$LOCK_ROOT/waybar-launch.lock"
flock -n "$LOCK_FD" || exit 0

write_theme_setting() {
    local value=$1
    local temporary

    temporary=$(mktemp "${THEME_SETTING%/*}/.waybar-theme.XXXXXX")
    printf '%s\n' "$value" > "$temporary"
    mv -- "$temporary" "$THEME_SETTING"
}

resolve_theme() {
    local raw=$1
    local extra=''

    IFS=';' read -r theme_path style_path extra <<< "$raw"
    [[ -z $extra ]] || return 1
    [[ $theme_path =~ ^/[A-Za-z0-9._-]+$ ]] || return 1
    [[ $style_path =~ ^/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?$ ]] || return 1
    [[ -f $THEME_ROOT$theme_path/config && -f $THEME_ROOT$style_path/style.css ]]
}

theme_spec=$DEFAULT_THEME
[[ -r $THEME_SETTING ]] && theme_spec=$(<"$THEME_SETTING")
if ! resolve_theme "$theme_spec"; then
    printf 'Invalid or unavailable Waybar theme %q; using %s.\n' \
        "$theme_spec" "$DEFAULT_THEME" >&2
    theme_spec=$DEFAULT_THEME
    resolve_theme "$theme_spec" || {
        printf 'Default Waybar theme is incomplete.\n' >&2
        exit 1
    }
    write_theme_setting "$theme_spec"
fi

IFS=';' read -r theme_path style_path <<< "$theme_spec"
config_file="$THEME_ROOT$theme_path/config"
style_file="$THEME_ROOT$style_path/style.css"
[[ -f $THEME_ROOT$theme_path/config-custom ]] && \
    config_file="$THEME_ROOT$theme_path/config-custom"
[[ -f $THEME_ROOT$style_path/style-custom.css ]] && \
    style_file="$THEME_ROOT$style_path/style-custom.css"

generated_config="$LOCK_ROOT/waybar-config.json"
if [[ ! -r $CONFIG_GENERATOR ]]; then
    printf 'Waybar configuration generator is missing: %s\n' "$CONFIG_GENERATOR" >&2
    exit 1
fi
python3 "$CONFIG_GENERATOR" "$config_file" "$SETTINGS_ROOT" "$generated_config"
config_file=$generated_config

pkill -x waybar >/dev/null 2>&1 || true
sleep 0.3

if [[ -f $CONFIG_ROOT/myhypr/settings/waybar-disabled ]]; then
    printf 'Waybar is disabled by the runtime setting.\n'
    exit 0
fi

instance_signature=${HYPRLAND_INSTANCE_SIGNATURE:-}
if [[ -z $instance_signature ]]; then
    instance_signature=$(hyprctl -j instances | jq -er '.[0].instance')
fi

printf 'Launching Waybar theme %s.\n' "$theme_spec"
if [[ $launch_mode == service ]]; then
    exec {LOCK_FD}>&-
    export HYPRLAND_INSTANCE_SIGNATURE="$instance_signature"
    exec waybar --config "$config_file" --style "$style_file"
fi
(
    # Keep the launcher serialized, but do not let long-running Waybar inherit
    # the lock and block every later reload.
    exec {LOCK_FD}>&-
    export HYPRLAND_INSTANCE_SIGNATURE="$instance_signature"
    exec waybar --config "$config_file" --style "$style_file"
) &
disown
