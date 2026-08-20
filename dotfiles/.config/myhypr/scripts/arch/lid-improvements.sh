#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=dotfiles/.config/myhypr/scripts/arch/lib.sh
source "$SCRIPT_DIR/lib.sh"

drop_in_directory=/etc/systemd/logind.conf.d
drop_in=$drop_in_directory/90-myhypr.conf
action=${1:-apply}

myhypr_arch_require_user
myhypr_arch_require sudo systemd-analyze
case $action in
    apply)
        sudo install -d -m 0755 -- "$drop_in_directory"
        printf '%s\n' \
            '# Managed by MyHypr. Remove this file to restore system defaults.' \
            '[Login]' \
            'HandleLidSwitchDocked=ignore' \
            'HoldoffTimeoutSec=5s' | sudo tee "$drop_in" >/dev/null
        sudo chmod 0644 "$drop_in"
        systemd-analyze cat-config systemd/logind.conf >/dev/null
        printf 'Lid settings installed in %s. Reboot to apply them safely.\n' "$drop_in"
        ;;
    remove)
        if [[ -e $drop_in || -L $drop_in ]]; then
            sudo rm -- "$drop_in"
            printf 'Removed %s. Reboot to restore system defaults.\n' "$drop_in"
        else
            printf 'No MyHypr lid-settings drop-in is installed.\n'
        fi
        ;;
    *) myhypr_arch_die "Usage: ${0##*/} [apply|remove]" ;;
esac
