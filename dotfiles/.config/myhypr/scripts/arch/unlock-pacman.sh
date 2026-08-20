#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=dotfiles/.config/myhypr/scripts/arch/lib.sh
source "$SCRIPT_DIR/lib.sh"

lock_file=/var/lib/pacman/db.lck
[[ -e $lock_file || -L $lock_file ]] || {
    printf 'Pacman database is not locked.\n'
    exit 0
}

myhypr_arch_require_user
myhypr_arch_require pgrep sudo
for process_name in pacman paru yay makepkg pamac; do
    if pgrep -x "$process_name" >/dev/null 2>&1; then
        myhypr_arch_die "Refusing to remove the lock while $process_name is running."
    fi
done
if command -v fuser >/dev/null 2>&1 && fuser "$lock_file" >/dev/null 2>&1; then
    myhypr_arch_die 'Refusing to remove a lock that is held by a running process.'
fi

printf 'Stale lock candidate: %s\n' "$lock_file"
myhypr_arch_confirm 'Remove this lock only if the previous package operation crashed?' || {
    printf 'Lock removal cancelled.\n'
    exit 0
}
sudo rm -- "$lock_file"
printf 'Stale pacman lock removed.\n'
