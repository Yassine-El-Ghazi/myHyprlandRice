#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
SIDEPAD_PATH="$CONFIG_ROOT/sidepad/sidepad"
SIDEPAD_DATA="$CONFIG_ROOT/myhypr/settings/sidepad-active"
SIDEPAD_PADS_FOLDER="$CONFIG_ROOT/sidepad/pads"
launcher_file="$CONFIG_ROOT/myhypr/settings/launcher"

declare -a SIDEPAD_APP=()
declare -a SIDEPAD_OPTIONS=()
SIDEPAD_CLASS=''

load_pad() {
    local pad_name=$1
    local pad_file

    [[ $pad_name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
        printf 'Invalid sidepad name: %s\n' "$pad_name" >&2
        return 1
    }
    pad_file="$SIDEPAD_PADS_FOLDER/$pad_name"
    [[ -f $pad_file ]] || {
        printf 'Sidepad configuration not found: %s\n' "$pad_file" >&2
        return 1
    }

    SIDEPAD_APP=()
    SIDEPAD_OPTIONS=()
    SIDEPAD_CLASS=''
    # Pad definitions are tracked configuration files. The runtime selector is
    # validated above, so it cannot traverse outside this directory.
    # shellcheck source=/dev/null
    source "$pad_file"

    ((${#SIDEPAD_APP[@]})) && [[ -n $SIDEPAD_CLASS ]] || {
        printf 'Incomplete sidepad configuration: %s\n' "$pad_file" >&2
        return 1
    }
}

invoke_sidepad() {
    "$SIDEPAD_PATH" --class "$SIDEPAD_CLASS" "${SIDEPAD_OPTIONS[@]}" "$@"
}

select_sidepad() {
    local launcher pad_file selected old_class temporary_setting
    local -a pad_names=()

    for pad_file in "$SIDEPAD_PADS_FOLDER"/*; do
        [[ -f $pad_file ]] || continue
        pad_names+=("${pad_file##*/}")
    done
    ((${#pad_names[@]})) || {
        printf 'No sidepad definitions found in %s\n' "$SIDEPAD_PADS_FOLDER" >&2
        return 1
    }

    launcher=$(<"$launcher_file")
    if [[ $launcher == walker ]] && command -v walker >/dev/null 2>&1; then
        selected=$(printf '%s\n' "${pad_names[@]}" | \
            "$CONFIG_ROOT/walker/launch.sh" -d -n -N -H --maxheight 400 -p Sidepads) || return 0
    else
        selected=$(printf '%s\n' "${pad_names[@]}" | \
            rofi -dmenu -replace -i -config "$CONFIG_ROOT/rofi/config-compact.rasi" \
                -no-show-icons -width 30 -p Sidepads) || return 0
    fi
    [[ -n $selected ]] || return 0

    old_class=$SIDEPAD_CLASS
    "$SIDEPAD_PATH" --class "$old_class" --kill || true
    load_pad "$selected"

    mkdir -p -- "${SIDEPAD_DATA%/*}"
    temporary_setting=$(mktemp "${SIDEPAD_DATA%/*}/.sidepad-active.XXXXXX")
    printf '%s\n' "$selected" > "$temporary_setting"
    mv -- "$temporary_setting" "$SIDEPAD_DATA"

    invoke_sidepad --init -- "${SIDEPAD_APP[@]}"
    printf 'Sidepad switched to %s.\n' "$selected"
}

[[ -x $SIDEPAD_PATH ]] || {
    printf 'Sidepad executable is unavailable: %s\n' "$SIDEPAD_PATH" >&2
    exit 1
}
[[ -r $SIDEPAD_DATA ]] || {
    printf 'Active sidepad setting is unavailable: %s\n' "$SIDEPAD_DATA" >&2
    exit 1
}

SIDEPAD_ACTIVE=$(<"$SIDEPAD_DATA")
load_pad "$SIDEPAD_ACTIVE"

case ${1:-} in
    --init) invoke_sidepad --init -- "${SIDEPAD_APP[@]}" ;;
    --hide) invoke_sidepad --hide ;;
    --test) invoke_sidepad --test ;;
    --kill) invoke_sidepad --kill ;;
    --select) select_sidepad ;;
    '') invoke_sidepad ;;
    *)
        printf 'Usage: %s [--init|--hide|--test|--kill|--select]\n' "${0##*/}" >&2
        exit 2
        ;;
esac
