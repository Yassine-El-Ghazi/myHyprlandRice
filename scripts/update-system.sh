#!/usr/bin/env bash
set -Eeuo pipefail

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
if command -v paru >/dev/null 2>&1; then
    paru --sudo pkexec --sudoflags '' --nosudoloop -Syu
elif command -v yay >/dev/null 2>&1; then
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
