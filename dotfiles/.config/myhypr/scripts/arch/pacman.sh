#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=dotfiles/.config/myhypr/scripts/arch/lib.sh
source "$SCRIPT_DIR/lib.sh"

config=/etc/pacman.conf
backup=/etc/pacman.conf.myhypr.bak
myhypr_arch_require_user
myhypr_arch_require grep pacman-conf sed sudo
[[ -f $config ]] || myhypr_arch_die "Missing pacman configuration: $config"
myhypr_arch_banner 'Pacman preferences'

if [[ ! -e $backup ]]; then
    sudo cp --preserve=mode,ownership,timestamps -- "$config" "$backup"
fi

enable_option() {
    local option=$1

    if grep -Eq "^[[:space:]]*$option([[:space:]]|$)" "$config"; then
        printf '%s is already enabled.\n' "$option"
        return
    fi
    if ! grep -Eq "^[[:space:]]*#[[:space:]]*$option([[:space:]]|$)" "$config"; then
        printf '%s is not declared in %s; skipping.\n' "$option" "$config"
        return
    fi
    if myhypr_arch_confirm "Enable $option?"; then
        sudo sed -i -E \
            "s|^([[:space:]]*)#[[:space:]]*($option)([[:space:]]|$)|\\1\\2\\3|" \
            "$config"
    fi
}

enable_option ParallelDownloads
enable_option Color
enable_option VerbosePkgLists

if ! grep -Fxq ILoveCandy "$config" && myhypr_arch_confirm 'Enable ILoveCandy?'; then
    sudo sed -i -E '/^[[:space:]]*ParallelDownloads([[:space:]]|=)/a ILoveCandy' "$config"
fi

if ! pacman-conf --repo-list >/dev/null; then
    printf 'Pacman rejected the updated configuration; restoring %s.\n' "$backup" >&2
    sudo cp --preserve=mode,ownership,timestamps -- "$backup" "$config"
    exit 1
fi
printf 'Pacman preferences updated. Original file: %s\n' "$backup"
