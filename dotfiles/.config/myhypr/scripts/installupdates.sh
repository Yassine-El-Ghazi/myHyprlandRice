#!/usr/bin/env bash
set -Euo pipefail

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
REPO_ROOT=$(cd -- "$(dirname -- "$SCRIPT_PATH")/../../../.." && pwd -P)

pause_before_exit() {
    [[ -t 0 ]] || return 0
    printf '\nPress [ENTER] to close.'
    read -r _
}

if [[ -t 1 && -n ${TERM:-} ]]; then
    clear
fi
if command -v figlet >/dev/null 2>&1; then
    figlet -f smslant Updates
else
    printf 'System updates\n'
fi
printf '\n'

primary='#89b4fa'
on_surface='#cdd6f4'
[[ -r $HOME/.config/myhypr/colors/primary ]] && primary=$(<"$HOME/.config/myhypr/colors/primary")
[[ -r $HOME/.config/myhypr/colors/onsurface ]] && on_surface=$(<"$HOME/.config/myhypr/colors/onsurface")

if command -v gum >/dev/null 2>&1; then
    gum confirm \
        --selected.background="$primary" \
        --prompt.foreground="$on_surface" \
        'Start the system update?'
    confirmation=$?
    [[ $confirmation -eq 130 ]] && exit 130
    if [[ $confirmation -ne 0 ]]; then
        printf 'Update canceled.\n'
        exit 0
    fi
else
    read -r -p 'Start the system update? [y/N] ' confirmation
    if [[ $confirmation != [yY] && $confirmation != [yY][eE][sS] ]]; then
        printf 'Update canceled.\n'
        exit 0
    fi
fi

printf '\n:: Update started...\n'
"$REPO_ROOT/scripts/update-system.sh"
update_status=$?

pkill -RTMIN+1 waybar >/dev/null 2>&1 || true

if [[ $update_status -ne 0 ]]; then
    printf '\n:: Update failed with status %d. Review the package-manager output above.\n' \
        "$update_status" >&2
    pause_before_exit
    exit "$update_status"
fi

printf '\n:: All updates completed successfully.\n'
pause_before_exit
