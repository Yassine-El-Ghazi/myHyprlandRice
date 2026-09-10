#!/usr/bin/env bash
set -uo pipefail

json_status() {
    local count=$1
    local css_class=$2
    local tooltip=$3
    printf '{"text":"%s","alt":"%s","tooltip":"%s","class":"%s"}\n' \
        "$count" "$count" "$tooltip" "$css_class"
}

pacman_db_lock=${MYHYPR_TEST_PACMAN_DB_LOCK:-/var/lib/pacman/db.lck}
if [[ -e $pacman_db_lock || -e ${TMPDIR:-/tmp}/checkup-db-${UID}/db.lck ]]; then
    json_status '…' yellow 'Package database is busy'
    exit 0
fi

count_lines() {
    awk 'NF { count++ } END { print count + 0 }'
}

updates=0
check_failed=0
failure_tooltip='Update check failed; click to run the updater'
check_timeout=${MYHYPR_UPDATE_CHECK_TIMEOUT_SECONDS:-30}
[[ $check_timeout =~ ^[0-9]+([.][0-9]+)?$ ]] || check_timeout=30
if command -v pacman >/dev/null 2>&1; then
    repo_updates=0
    aur_updates=0
    check_output=''
    check_code=0

    if command -v checkupdates >/dev/null 2>&1; then
        check_output=$(timeout "$check_timeout" checkupdates 2>/dev/null)
        check_code=$?
        case $check_code in
            0) repo_updates=$(count_lines <<< "$check_output") ;;
            2) repo_updates=0 ;;
            124)
                check_failed=1
                failure_tooltip='Update check timed out; click to run the updater'
                ;;
            *) check_failed=1 ;;
        esac
    else
        check_output=$(pacman -Qu 2>/dev/null)
        check_code=$?
        if [[ $check_code -eq 0 ]]; then
            repo_updates=$(count_lines <<< "$check_output")
        else
            check_failed=1
        fi
    fi

    if [[ $check_failed -eq 0 ]] && command -v paru >/dev/null 2>&1; then
        check_output=$(timeout 20 paru -Qua 2>/dev/null)
        check_code=$?
        if [[ $check_code -eq 0 ]]; then
            aur_updates=$(count_lines <<< "$check_output")
        else
            check_failed=1
        fi
    elif [[ $check_failed -eq 0 ]] && command -v yay >/dev/null 2>&1; then
        check_output=$(timeout 20 yay -Qua 2>/dev/null)
        check_code=$?
        if [[ $check_code -eq 0 ]]; then
            aur_updates=$(count_lines <<< "$check_output")
        else
            check_failed=1
        fi
    fi
    updates=$((repo_updates + aur_updates))
elif command -v dnf >/dev/null 2>&1; then
    check_output=$(dnf check-update -q 2>/dev/null)
    check_code=$?
    case $check_code in
        0|100)
            updates=$(awk '/^[[:alnum:]]/ { count++ } END { print count + 0 }' \
                <<< "$check_output")
            ;;
        *) check_failed=1 ;;
    esac
fi

if [[ $check_failed -eq 1 ]]; then
    json_status '!' red "$failure_tooltip"
    exit 0
fi

css_class=green
if ((updates > 100)); then
    css_class=red
elif ((updates > 0)); then
    css_class=yellow
fi

if ((updates == 0)); then
    json_status 0 "$css_class" 'System is up to date'
else
    json_status "$updates" "$css_class" 'Click to update the system'
fi
