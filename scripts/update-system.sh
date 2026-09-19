#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$SCRIPT_DIR/.."
STATUS_SCRIPT="$REPO_ROOT/dotfiles/.config/myhypr/scripts/updates.sh"
update_aur_helper=none
ALLOW_AUR=0
PACMAN_BIN=/usr/bin/pacman
PKEXEC_BIN=/usr/bin/pkexec
PARU_BIN=/usr/bin/paru
YAY_BIN=/usr/bin/yay

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
while (($#)); do
    case $1 in
        --allow-aur)
            ALLOW_AUR=1
            shift
            ;;
        -h|--help)
            printf 'Usage: %s [--allow-aur]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Usage: %s [--allow-aur]\n' "$0" >&2
            exit 2
            ;;
    esac
done
[[ -x $PACMAN_BIN ]] || {
    printf 'This updater requires an Arch-based system.\n' >&2
    exit 1
}
[[ -x $PKEXEC_BIN ]] || {
    printf 'pkexec is required for graphical administrator authentication.\n' >&2
    exit 1
}

# Official repository packages are signed and are the safe routine default.
"$PKEXEC_BIN" "$PACMAN_BIN" -Syu

# AUR recipes execute maintainer-controlled build code as the user. Keep this
# a separate, explicit, interactive action rather than silently folding it
# into every routine update.
if [[ $ALLOW_AUR -eq 1 && -x $PARU_BIN ]]; then
    update_aur_helper=paru
    "$PARU_BIN" --sudo "$PKEXEC_BIN" --sudoflags '' --nosudoloop -Sua
elif [[ $ALLOW_AUR -eq 1 && -x $YAY_BIN ]]; then
    update_aur_helper=yay
    "$YAY_BIN" --sudo "$PKEXEC_BIN" --sudoflags '' --nosudoloop -Sua
elif [[ $ALLOW_AUR -eq 1 ]]; then
    printf 'No trusted AUR helper exists at /usr/bin/paru or /usr/bin/yay.\n' >&2
    exit 1
fi

if command -v flatpak >/dev/null 2>&1; then
    for scope in user system; do
        remotes=$(flatpak "--$scope" remotes --columns=name)
        [[ -n $remotes ]] || continue
        printf '\n:: Updating %s Flatpak applications...\n' "$scope"
        flatpak "--$scope" update
    done
fi
