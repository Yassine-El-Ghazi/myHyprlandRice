#!/usr/bin/env bash
set -uo pipefail
umask 077
export LC_ALL=C

mode=${1:-online}
[[ $mode == online || $mode == --local ]] || {
    printf 'Usage: %s [--local]\n' "${0##*/}" >&2
    exit 2
}

json_status() {
    local count=$1
    local css_class=$2
    local tooltip=$3
    jq -cn --arg text "$count" --arg tooltip "$tooltip" --arg class "$css_class" \
        '{text:$text, alt:$text, tooltip:$tooltip, class:$class}'
}

# Never consume old post-update markers: they can omit sources or be stale.

pacman_db_lock=${MYHYPR_TEST_PACMAN_DB_LOCK:-/var/lib/pacman/db.lck}
if [[ -e $pacman_db_lock ]]; then
    json_status '…' yellow 'Package database is busy'
    exit 0
fi

count_lines() {
    awk 'NF { count++ } END { print count + 0 }'
}

updates=0
repo_known=0
aur_known=1
repo_fresh=0
repo_updates=0
aur_updates=0
status_note=''
check_timeout=${MYHYPR_UPDATE_CHECK_TIMEOUT_SECONDS:-30}
[[ $check_timeout =~ ^[0-9]+([.][0-9]+)?$ && $check_timeout =~ [1-9] ]] || check_timeout=30
work=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-update-check.XXXXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT

# Start independent Flatpak queries while the repository/AUR checks run.
flatpak_status() {
    local scope=$1 code args=()
    if ! command -v flatpak >/dev/null 2>&1; then
        printf '0\n' > "$work/flatpak-$scope.count"
        return
    fi
    [[ $mode == --local ]] && args=(--cached)
    timeout --kill-after=2 "$check_timeout" flatpak "--$scope" remote-ls \
        --updates --columns=ref "${args[@]}" > "$work/flatpak-$scope.out" \
        2> "$work/flatpak-$scope.err"
    code=$?
    # A warning with exit 0 can mean an unreachable remote and partial data.
    if [[ $code == 0 && ! -s $work/flatpak-$scope.err ]]; then
        sort -u "$work/flatpak-$scope.out" | count_lines > "$work/flatpak-$scope.count"
    else
        printf '?\n' > "$work/flatpak-$scope.count"
    fi
}
flatpak_status user & flatpak_user_pid=$!
flatpak_status system & flatpak_system_pid=$!
if command -v pacman >/dev/null 2>&1; then
    repo_updates=0
    aur_updates=0
    check_output=''
    check_error=''
    check_code=0
    aur_helper=${MYHYPR_UPDATE_AUR_HELPER:-auto}
    [[ $aur_helper == auto || $aur_helper == paru || $aur_helper == yay || \
        $aur_helper == none ]] || aur_helper=auto
    error_file="$work/package.err"

    if [[ $mode == online ]] && command -v checkupdates >/dev/null 2>&1; then
        # Private disposable sync DB: no live pacman refresh and no shared lock.
        check_output=$(CHECKUPDATES_DB="$work/db" timeout --kill-after=2 "$check_timeout" checkupdates 2>"$error_file")
        check_code=$?
        case $check_code in
            0) repo_updates=$(count_lines <<< "$check_output"); repo_known=1; repo_fresh=1 ;;
            2) repo_updates=0; repo_known=1; repo_fresh=1 ;;
            124|137)
                status_note='Repository refresh timed out; showing local package data'
                ;;
            *) status_note='Repository refresh failed; showing local package data' ;;
        esac
    fi

    if [[ $repo_known -eq 0 ]]; then
        [[ -n $status_note ]] || status_note='Showing local package data (not refreshed)'
        : > "$error_file"
        check_output=$(timeout --kill-after=2 "$check_timeout" pacman -Qu 2>"$error_file")
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
        check_output=$(timeout --kill-after=2 "$check_timeout" paru -Qua 2>"$error_file")
        check_code=$?
        check_error=$(<"$error_file")
        if [[ $check_code -eq 0 || \
            ( $check_code -eq 1 && -z $check_output && -z $check_error ) ]]; then
            aur_updates=$(count_lines <<< "$check_output")
        else
            aur_known=0
        fi
    elif [[ $aur_helper == yay ]] && command -v yay >/dev/null 2>&1; then
        check_output=$(timeout --kill-after=2 "$check_timeout" yay -Qua 2>"$error_file")
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
    else
        check_output=$(timeout --kill-after=2 "$check_timeout" pacman -Qmq 2>"$error_file")
        check_code=$?
        if [[ ( $check_code != 0 && $check_code != 1 ) || -n $check_output || -s $error_file ]]; then
            aur_known=0
            status_note="${status_note:+$status_note; }Foreign packages not checked (AUR helper disabled or missing)"
        fi
    fi
    updates=$((repo_updates + aur_updates))
elif command -v dnf >/dev/null 2>&1; then
    dnf_args=(--refresh)
    [[ $mode == --local ]] && dnf_args=(--cacheonly)
    check_output=$(timeout --kill-after=2 "$check_timeout" dnf "${dnf_args[@]}" check-update -q 2>/dev/null)
    check_code=$?
    case $check_code in
        0|100)
            updates=$(awk '/^[[:alnum:]]/ { count++ } END { print count + 0 }' \
                <<< "$check_output")
            repo_known=1
            repo_updates=$updates
            [[ $mode == online ]] && repo_fresh=1
            ;;
        *) repo_known=0 ;;
    esac
fi

wait "$flatpak_user_pid" || true
wait "$flatpak_system_pid" || true
flatpak_known=1
flatpak_user='?'
flatpak_system='?'
[[ -f $work/flatpak-user.count ]] && flatpak_user=$(<"$work/flatpak-user.count")
[[ -f $work/flatpak-system.count ]] && flatpak_system=$(<"$work/flatpak-system.count")
for flatpak_count in "$flatpak_user" "$flatpak_system"; do
    if [[ $flatpak_count =~ ^[0-9]+$ ]]; then
        updates=$((updates + flatpak_count))
    else
        flatpak_known=0
    fi
done

if [[ $aur_known -eq 0 ]]; then
    status_note="${status_note:+$status_note; }AUR status unavailable"
fi

css_class=green
if ((updates > 100)); then
    css_class=red
elif ((updates > 0)); then
    css_class=yellow
fi

display=$updates
if (( ! repo_fresh || ! repo_known || ! aur_known || ! flatpak_known )); then
    css_class=yellow
    if ((updates > 0)); then display="${updates}+"; else display='?'; fi
    status_note="Incomplete/cached check — count is not a current total${status_note:+; $status_note}"
fi
[[ -n $status_note ]] || status_note='Available updates at last check'
((repo_known)) || repo_updates='?'
((aur_known)) || aur_updates='?'
tooltip="$status_note"$'\n'"Repository: $repo_updates"$'\n'"AUR: $aur_updates (installation is opt-in)"$'\n'"Flatpak user: $flatpak_user"$'\n'"Flatpak system: $flatpak_system"$'\n'"Checked: $(date '+%Y-%m-%d %H:%M:%S %Z')"$'\n''Left: repository + Flatpak updates; AUR requires --allow-aur'$'\n''Right: refresh now (automatic check every 5 minutes)'
json_status "$display" "$css_class" "$tooltip"
