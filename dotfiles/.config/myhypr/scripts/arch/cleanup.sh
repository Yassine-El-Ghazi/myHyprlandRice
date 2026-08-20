#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=dotfiles/.config/myhypr/scripts/arch/lib.sh
source "$SCRIPT_DIR/lib.sh"

myhypr_arch_require_user
myhypr_arch_require pacman paccache sudo
myhypr_arch_banner 'Arch cleanup'

printf 'Keeping the two newest cached versions of installed packages.\n'
sudo paccache --remove --keep 2
printf 'Removing cached versions of packages that are no longer installed.\n'
sudo paccache --remove --uninstalled --keep 0

mapfile -t orphaned_packages < <(pacman -Qtdq 2>/dev/null || true)
if ((${#orphaned_packages[@]} == 0)); then
    printf 'No orphaned packages found.\n'
    exit 0
fi

printf 'Orphaned packages:\n'
printf '  %s\n' "${orphaned_packages[@]}"
if myhypr_arch_confirm 'Remove these orphaned packages?'; then
    sudo pacman -Rns -- "${orphaned_packages[@]}"
else
    printf 'Orphan removal skipped.\n'
fi
