#!/usr/bin/env bash
set -Eeuo pipefail

# Keep the historical entry-point name for existing bindings. Elephant is the
# only collector; each launcher presents the same Elephant history.
if (($# > 1)); then
    printf 'Usage: %s [d|w]\n' "$0" >&2
    exit 2
fi

show_clipboard() {
    local mode=$1 launcher=rofi
    local config_root="${XDG_CONFIG_HOME:-$HOME/.config}"
    local launcher_file="$config_root/myhypr/settings/launcher"
    if [[ -r $launcher_file ]]; then
        IFS= read -r launcher < "$launcher_file" || true
    fi
    case $launcher in
        walker)
            if [[ $mode == delete ]]; then
                exec "$config_root/walker/launch.sh" -m clipboard -H -p 'Delete entry: Ctrl+D'
            fi
            exec "$config_root/walker/launch.sh" -m clipboard -N -H
            ;;
        rofi)
            "$config_root/walker/launch.sh" --ensure-elephant
            exec /usr/bin/python3 "$config_root/myhypr/bin/clipboard-rofi.py" "$mode"
            ;;
        *) printf 'Unsupported launcher setting: %s\n' "$launcher" >&2; exit 1 ;;
    esac
}

case ${1:-} in
    '') show_clipboard copy ;;
    d) show_clipboard delete ;;
    w)
        status=0
        if ! elephant activate 'clipboard;;remove_all;;' >/dev/null 2>&1; then
            printf 'Could not clear Elephant clipboard history. Check the session service.\n' >&2
            status=1
        fi
        # Existing installations may still have the retired Cliphist store.
        # Attempt both clears even if one fails; never report partial success.
        if command -v cliphist >/dev/null 2>&1; then
            if ! cliphist wipe >/dev/null 2>&1; then
                printf 'Could not clear legacy Cliphist history.\n' >&2
                status=1
            fi
        else
            legacy_db="${XDG_CACHE_HOME:-$HOME/.cache}/cliphist/db"
            legacy_config="${XDG_CONFIG_HOME:-$HOME/.config}/cliphist/config"
            if [[ -e $legacy_db || -L $legacy_db || -e $legacy_config || -L $legacy_config ]]; then
                printf 'Legacy Cliphist data/config remains; install Cliphist temporarily and repeat this clear.\n' >&2
                status=1
            fi
        fi
        if ((status != 0)) && command -v notify-send >/dev/null 2>&1; then
            notify-send -a MyHypr -u critical 'Clipboard history clear failed' \
                'History could not be fully cleared. Check the session service and any legacy Cliphist installation.' \
                >/dev/null 2>&1 || true
        fi
        exit "$status"
        ;;
    *) printf 'Usage: %s [d|w]\n' "$0" >&2; exit 2 ;;
esac
