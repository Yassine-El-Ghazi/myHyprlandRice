#!/usr/bin/env bash
set -Eeuo pipefail
#    __            __   _         ___             
#   / /_____ __ __/ /  (_)__  ___/ (_)__  ___ ____
#  /  '_/ -_) // / _ \/ / _ \/ _  / / _ \/ _ `(_-<
# /_/\_\\__/\_, /_.__/_/_//_/\_,_/_/_//_/\_, /___/
#          /___/                        /___/     
# 

# -----------------------------------------------------
# Load Launcher
# -----------------------------------------------------
launcher=rofi
launcher_file="$HOME/.config/myhypr/settings/launcher"
if [[ -r $launcher_file ]]; then
    IFS= read -r launcher < "$launcher_file" || true
fi

# Hyprland is the source of truth. Descriptions are inert strings attached to
# Lua bindings, including bindings loaded from custom.lua and local.lua.
if ! bindings_json=$(hyprctl -j binds); then
    printf 'Unable to query active Hyprland keybindings.\n' >&2
    exit 1
fi

if ! keybinds=$(jq -er '
    def modifiers($mask):
        [
            if ((($mask / 64) | floor) % 2) >= 1 then "SUPER" else empty end,
            if ((($mask / 4) | floor) % 2) >= 1 then "CTRL" else empty end,
            if ((($mask / 8) | floor) % 2) >= 1 then "ALT" else empty end,
            if ($mask % 2) >= 1 then "SHIFT" else empty end
        ];
    def binding_key:
        if (.key | type) == "string" and (.key | length) > 0 then .key
        elif (.keycode | type) == "number" and .keycode > 0 then "code:\(.keycode)"
        else "unknown"
        end;
    if type != "array" then error("binding result is not an array") else . end
    | [
        .[]
        | select(type == "object")
        | select((.modmask | type) == "number" and .modmask >= 0 and .modmask <= 255)
        | select((.description | type) == "string")
        | select(.description | test("\\S") and (test("[[:cntrl:]]") | not))
        | select((.description | length) <= 256)
        | ((modifiers(.modmask) + [binding_key]) | join(" + "))
            + "\r" + .description
    ]
    | if length == 0 then error("no described bindings") else .[] end
' <<< "$bindings_json"); then
    printf 'Hyprland returned no valid described keybindings.\n' >&2
    exit 1
fi

sleep 0.2

case $launcher in
    walker)
        keybinds=$(printf '%s' "$keybinds" | tr '\r' ':')
        "$HOME/.config/walker/launch.sh" -d -N -H \
            -p 'Search Keybinds' <<< "$keybinds"
        ;;
    rofi)
        rofi -dmenu -i -markup -eh 2 -replace -p 'Keybinds' \
            -config "$HOME/.config/rofi/config-compact.rasi" <<< "$keybinds"
        ;;
    *)
        printf 'Unsupported launcher setting: %s\n' "$launcher" >&2
        exit 1
        ;;
esac
