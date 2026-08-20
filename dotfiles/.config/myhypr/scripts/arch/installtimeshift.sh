#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=dotfiles/.config/myhypr/scripts/arch/lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
    printf 'Usage: %s [--yes] [--with-grub-btrfs|--without-grub-btrfs]\n' "${0##*/}"
}

grub_mode=auto
while (($#)); do
    case $1 in
        --yes)
            MYHYPR_ASSUME_YES=1
            shift
            ;;
        --with-grub-btrfs)
            grub_mode=yes
            shift
            ;;
        --without-grub-btrfs)
            grub_mode=no
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) myhypr_arch_die "Unknown option: $1" ;;
    esac
done

myhypr_arch_require_user
myhypr_arch_require findmnt pacman sudo
myhypr_arch_banner 'Timeshift'
myhypr_arch_confirm 'Install Timeshift?' || {
    printf 'Timeshift installation cancelled.\n'
    exit 0
}

packages=(timeshift)
root_filesystem=$(findmnt --noheadings --output FSTYPE / | head -n 1)
if [[ $grub_mode == yes ]] || {
    [[ $grub_mode == auto && $root_filesystem == btrfs && -d /boot/grub ]] && \
        myhypr_arch_confirm 'Install GRUB snapshot integration?'
}; then
    packages+=(grub-btrfs)
fi

pacman_args=(sudo pacman -S --needed)
[[ ${MYHYPR_ASSUME_YES:-0} == 1 ]] && pacman_args+=(--noconfirm)
"${pacman_args[@]}" "${packages[@]}"
printf 'Timeshift is installed. Review its snapshot destination before creating the first snapshot.\n'
