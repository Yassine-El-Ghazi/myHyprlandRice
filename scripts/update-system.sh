#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$SCRIPT_DIR/.."
STATUS_SCRIPT="$REPO_ROOT/dotfiles/.config/myhypr/scripts/updates.sh"
update_aur_helper=none

refresh_waybar_status() {
    local update_status=$?
    local runtime_root=${XDG_RUNTIME_DIR:-}
    local marker temporary payload

    trap - EXIT
    if [[ -n $runtime_root && -d $runtime_root && -O $runtime_root && \
        ! -L $runtime_root ]]; then
        marker="$runtime_root/myhypr-update-status.json"
        rm -f -- "$marker" || true
        if [[ $update_status -eq 0 && -x $STATUS_SCRIPT ]]; then
            payload=$(MYHYPR_UPDATE_AUR_HELPER="$update_aur_helper" \
                "$STATUS_SCRIPT" --local) || payload=''
            if [[ -n $payload ]] && \
                temporary=$(mktemp "$runtime_root/.myhypr-update-status.XXXXXX"); then
                if ! chmod 600 "$temporary" || \
                    ! printf '%s\n' "$payload" > "$temporary" || \
                    ! mv -- "$temporary" "$marker"; then
                    rm -f -- "$temporary" || true
                fi
            fi
        fi
    fi
    pkill -RTMIN+1 waybar >/dev/null 2>&1 || true
    exit "$update_status"
}
trap refresh_waybar_status EXIT

# The everyday updater uses package managers directly. Snapshot policy and
# dotfiles transactions are separate, optional maintenance operations.
(($# == 0)) || { printf 'Usage: %s\n' "$0" >&2; exit 2; }
command -v pacman >/dev/null 2>&1 || {
    printf 'This updater requires an Arch-based system.\n' >&2
    exit 1
}
command -v pkexec >/dev/null 2>&1 || {
    printf 'pkexec is required for graphical administrator authentication.\n' >&2
    exit 1
}

# AUR helpers run as the regular user; only their pacman calls use pkexec.
# Disable sudo-specific flags and credential-refresh loops for this backend.
preferred_aur_helper=${MYHYPR_TEST_AUR_HELPER:-auto}
[[ $preferred_aur_helper == auto || $preferred_aur_helper == paru || \
    $preferred_aur_helper == yay || $preferred_aur_helper == none ]] || \
    preferred_aur_helper=auto
if [[ $preferred_aur_helper == auto || $preferred_aur_helper == paru ]] && \
    command -v paru >/dev/null 2>&1; then
    update_aur_helper=paru
    paru --sudo pkexec --sudoflags '' --nosudoloop -Syu
elif [[ $preferred_aur_helper == auto || $preferred_aur_helper == yay ]] && \
    command -v yay >/dev/null 2>&1; then
    update_aur_helper=yay
    yay --sudo pkexec --sudoflags '' --nosudoloop -Syu
else
    pkexec pacman -Syu
fi

if command -v flatpak >/dev/null 2>&1; then
    for scope in user system; do
        remotes=$(flatpak "--$scope" remotes --columns=name)
        [[ -n $remotes ]] || continue
        printf '\n:: Updating %s Flatpak applications...\n' "$scope"
        flatpak "--$scope" update
    done
fi
