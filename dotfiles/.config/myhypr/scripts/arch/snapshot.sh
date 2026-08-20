#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=dotfiles/.config/myhypr/scripts/arch/lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
    printf 'Usage: %s [--comment TEXT]\n' "${0##*/}"
}

comment=''
while (($#)); do
    case $1 in
        --comment)
            (($# >= 2)) || myhypr_arch_die '--comment requires text'
            comment=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) myhypr_arch_die "Unknown option: $1" ;;
    esac
done

myhypr_arch_require_user
myhypr_arch_require pacman sudo timeshift
myhypr_arch_banner 'Snapshot'

if [[ -z $comment ]]; then
    if command -v gum >/dev/null 2>&1; then
        comment=$(gum input --placeholder 'Snapshot description')
    elif [[ -t 0 ]]; then
        read -r -p 'Snapshot description: ' comment
    fi
fi
[[ -n $comment ]] || myhypr_arch_die 'A non-empty snapshot description is required.'

sudo timeshift --create --comments "$comment"
sudo timeshift --list
if [[ -d /boot/grub ]] && pacman -T grub-btrfs >/dev/null 2>&1 && \
    command -v grub-mkconfig >/dev/null 2>&1; then
    sudo grub-mkconfig -o /boot/grub/grub.cfg
fi
printf 'Snapshot created: %s\n' "$comment"
