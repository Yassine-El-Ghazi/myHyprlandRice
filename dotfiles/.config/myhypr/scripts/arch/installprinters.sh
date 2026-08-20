#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=dotfiles/.config/myhypr/scripts/arch/lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
    printf 'Usage: %s [--yes]\n' "${0##*/}"
}

while (($#)); do
    case $1 in
        --yes)
            MYHYPR_ASSUME_YES=1
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
myhypr_arch_require pacman sudo systemctl
myhypr_arch_banner 'Printer support'

packages=(
    cups
    cups-browsed
    cups-filters
    cups-pdf
    foomatic-db
    foomatic-db-engine
    foomatic-db-nonfree
    foomatic-db-nonfree-ppds
    foomatic-db-ppds
    ipp-usb
    nss-mdns
    system-config-printer
)

myhypr_arch_confirm 'Install the driverless CUPS printing stack?' || {
    printf 'Printer installation cancelled.\n'
    exit 0
}

pacman_args=(sudo pacman -S --needed)
[[ ${MYHYPR_ASSUME_YES:-0} == 1 ]] && pacman_args+=(--noconfirm)
"${pacman_args[@]}" "${packages[@]}"
sudo systemctl enable --now cups.service
if systemctl list-unit-files avahi-daemon.service --no-legend 2>/dev/null | \
    grep -q '^avahi-daemon\.service'; then
    sudo systemctl enable --now avahi-daemon.service
fi

if command -v notify-send >/dev/null 2>&1; then
    notify-send 'MyHypr' 'Printer support is ready.' || true
fi
printf 'Printer support installed. Add model-specific drivers through the package manifest if needed.\n'
