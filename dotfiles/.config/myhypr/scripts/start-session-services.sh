#!/usr/bin/env bash
set -Eeuo pipefail

# Import only display/session identifiers needed by graphical user services.
# Never copy the complete shell environment into the long-lived user manager.
allowed_environment=(
    DISPLAY
    WAYLAND_DISPLAY
    HYPRLAND_INSTANCE_SIGNATURE
    XDG_CURRENT_DESKTOP
    XDG_SESSION_TYPE
)
available_environment=()

for name in "${allowed_environment[@]}"; do
    value=${!name-}
    [[ -n $value ]] && available_environment+=("$name")
done

if ((${#available_environment[@]})); then
    systemctl --user import-environment "${available_environment[@]}"
    if command -v dbus-update-activation-environment >/dev/null 2>&1; then
        dbus-update-activation-environment --systemd \
            "${available_environment[@]}"
    fi
fi

systemctl --user start myhypr-session.target
