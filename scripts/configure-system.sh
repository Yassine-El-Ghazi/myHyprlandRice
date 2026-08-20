#!/usr/bin/env bash
# shellcheck disable=SC2034  # Flags are consumed by run()/confirm() from lib.sh.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

DRY_RUN=0
ASSUME_YES=0

while (($#)); do
    case $1 in
        --dry-run) DRY_RUN=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        -h|--help)
            printf 'Usage: scripts/configure-system.sh [--dry-run] [--yes]\n'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

require_command systemctl
services=(NetworkManager.service bluetooth.service)
missing_state=()
for service in "${services[@]}"; do
    if ! systemctl is-enabled "$service" >/dev/null 2>&1 || \
        ! systemctl is-active "$service" >/dev/null 2>&1; then
        missing_state+=("$service")
    fi
done

if ((${#missing_state[@]})); then
    warn "Required desktop services need activation: ${missing_state[*]}"
    confirm 'Enable and start the required desktop services?'
    privilege_command=(sudo)
    if [[ ! -t 0 && -n ${WAYLAND_DISPLAY:-${DISPLAY:-}} ]] && \
        command -v pkexec >/dev/null 2>&1; then
        privilege_command=(pkexec)
    fi
    run "${privilege_command[@]}" systemctl enable --now "${missing_state[@]}"
else
    success 'Required NetworkManager and Bluetooth services are active.'
fi

if command -v xdg-user-dirs-update >/dev/null 2>&1; then
    run xdg-user-dirs-update
fi

success 'System integration is configured.'
