#!/usr/bin/env bash
set -uo pipefail

json_status() {
    local count=$1
    local css_class=$2
    local tooltip=$3
    printf '{"text":"%s","alt":"%s","tooltip":"%s","class":"%s"}\n' \
        "$count" "$count" "$tooltip" "$css_class"
}

if [[ -e /var/lib/pacman/db.lck || -e ${TMPDIR:-/tmp}/checkup-db-${UID}/db.lck ]]; then
    json_status '…' yellow 'Package database is busy'
    exit 0
fi

count_lines() {
    awk 'NF { count++ } END { print count + 0 }'
}

updates=0
if command -v pacman >/dev/null 2>&1; then
    repo_updates=0
    aur_updates=0

    if command -v checkupdates >/dev/null 2>&1; then
        repo_updates=$(checkupdates 2>/dev/null | count_lines)
    else
        repo_updates=$(pacman -Qu 2>/dev/null | count_lines)
    fi

    if command -v paru >/dev/null 2>&1; then
        aur_updates=$(timeout 20 paru -Qua 2>/dev/null | count_lines)
    elif command -v yay >/dev/null 2>&1; then
        aur_updates=$(timeout 20 yay -Qua 2>/dev/null | count_lines)
    fi
    updates=$((repo_updates + aur_updates))
elif command -v dnf >/dev/null 2>&1; then
    updates=$(dnf check-update -q 2>/dev/null | awk '/^[[:alnum:]]/ { count++ } END { print count + 0 }')
fi

css_class=green
if ((updates > 100)); then
    css_class=red
elif ((updates > 25)); then
    css_class=yellow
fi

if ((updates == 0)); then
    json_status 0 "$css_class" 'System is up to date'
else
    json_status "$updates" "$css_class" 'Click to update the system'
fi
