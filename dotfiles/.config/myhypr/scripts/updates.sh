#!/usr/bin/env bash
set -uo pipefail

mode=${1:-online}
[[ $mode == online || $mode == --local ]] || {
    printf 'Usage: %s [--local]\n' "${0##*/}" >&2
    exit 2
}

json_status() {
    local count=$1
    local css_class=$2
    local tooltip=$3
    printf '{"text":"%s","alt":"%s","tooltip":"%s","class":"%s"}\n' \
        "$count" "$count" "$tooltip" "$css_class"
}

runtime_root=${XDG_RUNTIME_DIR:-}
if [[ $mode == online && -n $runtime_root && -d $runtime_root && \
    -O $runtime_root && ! -L $runtime_root ]]; then
    update_status_marker="$runtime_root/myhypr-update-status.json"
    if [[ -f $update_status_marker && ! -L $update_status_marker ]]; then
        marker_payload=$(<"$update_status_marker")
        rm -f -- "$update_status_marker"
        if jq -e '
            type == "object" and
            (.text | type == "string") and
            (.alt | type == "string") and
            (.tooltip | type == "string") and
            (.class | type == "string")
        ' <<< "$marker_payload" >/dev/null 2>&1; then
            printf '%s\n' "$marker_payload"
            exit 0
        fi
    fi
fi

pacman_db_lock=${MYHYPR_TEST_PACMAN_DB_LOCK:-/var/lib/pacman/db.lck}
checkupdates_db_lock=${MYHYPR_TEST_CHECKUPDATES_DB_LOCK:-${TMPDIR:-/tmp}/checkup-db-${UID}/db.lck}
if [[ -e $pacman_db_lock || \
    ( $mode == online && -e $checkupdates_db_lock ) ]]; then
    json_status '…' yellow 'Package database is busy'
    exit 0
fi

count_lines() {
    awk 'NF { count++ } END { print count + 0 }'
}

updates=0
repo_known=0
aur_known=1
status_note=''
check_timeout=${MYHYPR_UPDATE_CHECK_TIMEOUT_SECONDS:-30}
[[ $check_timeout =~ ^[0-9]+([.][0-9]+)?$ ]] || check_timeout=30
if command -v pacman >/dev/null 2>&1; then
    repo_updates=0
    aur_updates=0
    check_output=''
    check_error=''
    check_code=0
    aur_helper=${MYHYPR_UPDATE_AUR_HELPER:-auto}
    [[ $aur_helper == auto || $aur_helper == paru || $aur_helper == yay || \
        $aur_helper == none ]] || aur_helper=auto
    error_file=$(mktemp "${TMPDIR:-/tmp}/myhypr-update-error.XXXXXXXX") || exit 1
    trap 'rm -f -- "$error_file"' EXIT

    if [[ $mode == online ]] && command -v checkupdates >/dev/null 2>&1; then
        check_output=$(timeout "$check_timeout" checkupdates 2>"$error_file")
        check_code=$?
        case $check_code in
            0) repo_updates=$(count_lines <<< "$check_output"); repo_known=1 ;;
            2) repo_updates=0; repo_known=1 ;;
            124)
                status_note='Repository refresh timed out; showing local package data'
                ;;
            *) status_note='Repository refresh failed; showing local package data' ;;
        esac
    fi

    if [[ $repo_known -eq 0 ]]; then
        : > "$error_file"
        check_output=$(pacman -Qu 2>"$error_file")
        check_code=$?
        check_error=$(<"$error_file")
        if [[ $check_code -eq 0 || \
            ( $check_code -eq 1 && -z $check_output && -z $check_error ) ]]; then
            repo_updates=$(count_lines <<< "$check_output")
            repo_known=1
        elif [[ $mode == --local ]]; then
            status_note='Repository update status unavailable; showing AUR result'
        else
            status_note='Repository refresh and local query failed; showing AUR result'
        fi
    fi

    : > "$error_file"
    if [[ $aur_helper == auto ]] && command -v paru >/dev/null 2>&1; then
        aur_helper=paru
    elif [[ $aur_helper == auto ]] && command -v yay >/dev/null 2>&1; then
        aur_helper=yay
    elif [[ $aur_helper == auto ]]; then
        aur_helper=none
    fi
    if [[ $aur_helper == paru ]] && command -v paru >/dev/null 2>&1; then
        check_output=$(timeout 20 paru -Qua 2>"$error_file")
        check_code=$?
        check_error=$(<"$error_file")
        if [[ $check_code -eq 0 || \
            ( $check_code -eq 1 && -z $check_output && -z $check_error ) ]]; then
            aur_updates=$(count_lines <<< "$check_output")
        else
            aur_known=0
        fi
    elif [[ $aur_helper == yay ]] && command -v yay >/dev/null 2>&1; then
        check_output=$(timeout 20 yay -Qua 2>"$error_file")
        check_code=$?
        check_error=$(<"$error_file")
        if [[ $check_code -eq 0 || \
            ( $check_code -eq 1 && -z $check_output && -z $check_error ) ]]; then
            aur_updates=$(count_lines <<< "$check_output")
        else
            aur_known=0
        fi
    elif [[ $aur_helper != none ]]; then
        aur_known=0
    fi
    updates=$((repo_updates + aur_updates))
elif command -v dnf >/dev/null 2>&1; then
    check_output=$(dnf check-update -q 2>/dev/null)
    check_code=$?
    case $check_code in
        0|100)
            updates=$(awk '/^[[:alnum:]]/ { count++ } END { print count + 0 }' \
                <<< "$check_output")
            repo_known=1
            ;;
        *) repo_known=0 ;;
    esac
fi

if [[ $repo_known -eq 0 && $aur_known -eq 0 ]]; then
    json_status '!' red 'Update checks failed; click to run the updater'
    exit 0
fi

if [[ $aur_known -eq 0 ]]; then
    status_note="${status_note:+$status_note; }AUR check failed"
fi

css_class=green
if ((updates > 100)); then
    css_class=red
elif ((updates > 0)); then
    css_class=yellow
fi

if [[ -n $status_note ]]; then
    json_status "$updates" "$css_class" "$status_note"
elif ((updates == 0)); then
    json_status 0 "$css_class" 'System is up to date'
else
    json_status "$updates" "$css_class" 'Click to update the system'
fi
