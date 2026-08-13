#!/usr/bin/env bash
set -Euo pipefail

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
[[ -r $HOME/.config/ml4w/colors/primary ]] && primary=$(<"$HOME/.config/ml4w/colors/primary")
[[ -r $HOME/.config/ml4w/colors/onsurface ]] && on_surface=$(<"$HOME/.config/ml4w/colors/onsurface")

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
failures=0

run_update() {
    printf ':: Running:'
    printf ' %q' "$@"
    printf '\n'
    if ! "$@"; then
        printf ':: ERROR: command failed:' >&2
        printf ' %q' "$@" >&2
        printf '\n' >&2
        failures=$((failures + 1))
    fi
}

if command -v pacman >/dev/null 2>&1; then
    if command -v paru >/dev/null 2>&1; then
        run_update paru -Syu
    elif command -v yay >/dev/null 2>&1; then
        run_update yay -Syu
    else
        run_update sudo pacman -Syu
    fi
elif command -v dnf >/dev/null 2>&1; then
    run_update sudo dnf upgrade
else
    printf ':: ERROR: unsupported package manager.\n' >&2
    failures=$((failures + 1))
fi

if command -v flatpak >/dev/null 2>&1 && \
    [[ -n $(flatpak remotes --columns=name 2>/dev/null) ]]; then
    printf '\n:: Searching for Flatpak updates...\n'
    run_update flatpak update -y
fi

pkill -RTMIN+1 waybar >/dev/null 2>&1 || true

if [[ $failures -gt 0 ]]; then
    printf '\n:: Update finished with %d error(s). Review the output above.\n' "$failures" >&2
    pause_before_exit
    exit 1
fi

printf '\n:: All updates completed successfully.\n'
pause_before_exit
