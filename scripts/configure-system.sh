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
    ensure_sudo_session
    run sudo systemctl enable --now "${missing_state[@]}"
else
    success 'Required NetworkManager and Bluetooth services are active.'
fi

require_command elephant
require_command walker

user_unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
tracked_user_unit_dir="$REPO_ROOT/dotfiles/.config/systemd/user"
user_units=(elephant.service walker.service)
managed_user_units=(myhypr-session.target "${user_units[@]}")

for unit in "${managed_user_units[@]}"; do
    if [[ $DRY_RUN -eq 1 ]]; then
        [[ -f $tracked_user_unit_dir/$unit ]] || \
            die "Tracked user unit is missing: $tracked_user_unit_dir/$unit"
    else
        [[ -f $user_unit_dir/$unit ]] || \
            die "User unit is not linked: $user_unit_dir/$unit (run scripts/link-dotfiles.sh first)"
    fi
done

run systemctl --user daemon-reload

retired_wants_dirs=(
    "$user_unit_dir/graphical-session.target.wants"
    "$user_unit_dir/myhypr-session.target.wants"
)
for wants_dir in "${retired_wants_dirs[@]}"; do
    for unit in "${user_units[@]}"; do
        retired_link="$wants_dir/$unit"
        [[ -L $retired_link ]] || continue
        if [[ -e $retired_link && $retired_link -ef $user_unit_dir/$unit ]]; then
            info "Removing redundant user-service link: ${wants_dir##*/}/$unit"
            run unlink "$retired_link"
        else
            warn "Preserving unexpected user-service link: $retired_link"
        fi
    done
done

if [[ -n ${WAYLAND_DISPLAY:-}${DISPLAY:-} ]]; then
    info 'Starting the graphical-session user services'
    run "$REPO_ROOT/dotfiles/.config/myhypr/scripts/start-session-services.sh"
    if [[ $DRY_RUN -eq 0 ]]; then
        for unit in "${user_units[@]}"; do
            systemctl --user is-active "$unit" >/dev/null 2>&1 || \
                die "User service failed to start: $unit"
        done
    fi
    if [[ $DRY_RUN -eq 0 ]]; then
        systemctl --user is-active myhypr-session.target >/dev/null 2>&1 || \
            die 'MyHypr graphical-session target failed to start'
    fi
    success 'Elephant and Walker user services are managed and running.'
else
    success 'Elephant and Walker user services are installed for the next graphical session.'
fi

if command -v xdg-user-dirs-update >/dev/null 2>&1; then
    run xdg-user-dirs-update
fi

success 'System integration is configured.'
