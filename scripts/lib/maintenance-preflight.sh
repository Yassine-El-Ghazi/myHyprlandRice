#!/usr/bin/env bash

# Read-only maintenance readiness checks. This library is sourced after lib.sh
# and maintenance-transaction.sh. It stores only bounded classes and statuses,
# never probe output, paths, host details, network names, or package inventories.
# shellcheck disable=SC2016  # Single-quoted jq programs must not expand in Bash.

_preflight_safe_name() {
    [[ ${1:-} =~ ^[a-z0-9-]{1,64}$ ]]
}

_preflight_safe_class() {
    case ${1:-} in
        required-command-missing|low-space|package-manager-active|worktree-dirty|\
            upstream-unavailable|candidate-untrusted|unsupported-operating-system|\
            snapshot-coverage-unaccepted) return 0 ;;
        *) return 1 ;;
    esac
}

_preflight_context() {
    local operation=$1 profile=$2 requested=$3 requested_repo=$4
    local journal recorded_operation recorded_profile state canonical_repo top

    case $operation in dotfiles|system) ;; *) return 64 ;; esac
    case $profile in core|desktop|full) ;; *) return 64 ;; esac
    _maintenance_tx_require_active "$requested" || {
        warn 'Preflight requires the active locked transaction.'
        return 1
    }
    _PREFLIGHT_TX_DIR=$_MAINTENANCE_VALIDATED_TX_DIR
    journal="$_PREFLIGHT_TX_DIR/journal.json"
    recorded_operation=$(jq -er '.operation | select(type == "string")' \
        "$journal" 2>/dev/null) || return 1
    recorded_profile=$(jq -er '.profile | select(type == "string")' \
        "$journal" 2>/dev/null) || return 1
    state=$(jq -er '.state | select(type == "string")' "$journal" \
        2>/dev/null) || return 1
    [[ $recorded_operation == "$operation" && $recorded_profile == "$profile" && \
        $state == planned ]] || {
        warn 'Preflight arguments or state differ from the active transaction.'
        return 1
    }

    [[ $requested_repo == /* && -d $requested_repo && ! -L $requested_repo ]] || \
        return 1
    _maintenance_validate_owned_directory "$requested_repo" || return 1
    canonical_repo=$(realpath -e -- "$requested_repo" 2>/dev/null) || return 1
    [[ $canonical_repo == "$requested_repo" ]] || return 1
    top=$(git -C "$canonical_repo" rev-parse --show-toplevel 2>/dev/null) || return 1
    top=$(realpath -e -- "$top" 2>/dev/null) || return 1
    [[ $top == "$canonical_repo" ]] || return 1
    _PREFLIGHT_REPO=$canonical_repo
}

_preflight_command_available() {
    command -v -- "$1"
}

_preflight_space_available() {
    local class=$1 path=$2 minimum_kib=$3 available

    case $class in repository|home|packages) ;; *) return 1 ;; esac
    [[ $path == /* && -e $path && $minimum_kib =~ ^[0-9]+$ ]] || return 1
    available=$(df -Pk -- "$path" 2>/dev/null | awk '
        NR == 2 && $4 ~ /^[0-9]+$/ { print $4 }
    ') || return 1
    [[ $available =~ ^[0-9]+$ ]] || return 1
    ((available >= minimum_kib))
}

_preflight_pacman_unlocked() {
    [[ ! -e /var/lib/pacman/db.lck && ! -L /var/lib/pacman/db.lck ]]
}

_preflight_repo_clean() {
    local repo=$1 untracked

    git -C "$repo" diff --quiet || return 1
    git -C "$repo" diff --cached --quiet || return 1
    untracked=$(git -C "$repo" ls-files --others --exclude-standard) || return 1
    [[ -z $untracked ]]
}

_preflight_remote_ready() {
    local repo=$1 candidate upstream

    candidate=$(jq -er '.candidate_commit | select(type == "string")' \
        "$_PREFLIGHT_TX_DIR/journal.json" 2>/dev/null) || return 1
    upstream=$(git -C "$repo" rev-parse '@{upstream}' 2>/dev/null) || return 1
    [[ $candidate =~ ^[0-9a-f]{40}$ && $upstream == "$candidate" ]] || return 1
    [[ $(git -C "$repo" cat-file -t "$candidate" 2>/dev/null) == commit ]] || return 1
    git -C "$repo" merge-base --is-ancestor HEAD "$candidate"
}

_preflight_candidate_evidence() {
    local tx_dir=$1 journal candidate evidence

    journal="$tx_dir/journal.json"
    evidence="$tx_dir/git.json"
    _maintenance_validate_owned_file "$evidence" || return 1
    candidate=$(jq -er '.candidate_commit | select(type == "string")' \
        "$journal" 2>/dev/null) || return 1
    [[ $candidate =~ ^[0-9a-f]{40}$ ]] || return 1
    jq -e --arg id "${tx_dir##*/}" --arg candidate "$candidate" '
        .version == 1 and .transaction_id == $id and
        .candidate_commit == $candidate and
        .checks == {trusted_scan: 0, audit: 0, quick: 0} and
        (keys | sort) ==
            (["candidate_commit","checks","transaction_id","version"] | sort)
    ' "$evidence" >/dev/null 2>&1
}

_preflight_os_supported() {
    local id='' id_like=''

    [[ -r /etc/os-release ]] || return 1
    while IFS='=' read -r key value; do
        value=${value#\"}
        value=${value%\"}
        case $key in
            ID) id=$value ;;
            ID_LIKE) id_like=$value ;;
        esac
    done < /etc/os-release
    case " $id $id_like " in
        *' arch '*|*' cachyos '*) return 0 ;;
        *) return 1 ;;
    esac
}

_preflight_snapshot_validate() {
    local probe=$1

    _maintenance_validate_owned_file "$probe" || return 1
    jq -e '
        .version == 1 and
        (.provider == "none" or .provider == "snapper" or
            .provider == "timeshift") and
        (.reason | type == "string" and test("^[a-z0-9-]{1,64}$")) and
        (.coverage | type == "object") and
        (.coverage | keys | sort) ==
            (["boot","home","package_db","root"] | sort) and
        all(.coverage[]; type == "boolean") and
        (.system_restorable | type == "boolean") and
        .system_restorable ==
            (.coverage.root and .coverage.package_db and .coverage.boot) and
        (keys | sort) == ([
            "coverage","provider","reason","system_restorable","version"
        ] | sort)
    ' "$probe" >/dev/null 2>&1
}

_preflight_snapshot_accepted() {
    local probe=$1 answer layer joined IFS=,
    local -a missing=()

    jq -e '.provider == "none" and .reason == "explicitly-disabled"' \
        "$probe" >/dev/null 2>&1 && return 0
    for layer in root package_db home boot; do
        jq -e --arg layer "$layer" '.coverage[$layer] == true' \
            "$probe" >/dev/null 2>&1 || missing+=("${layer//_/-}")
    done
    ((${#missing[@]} == 0)) && return 0
    joined=${missing[*]}
    warn "System snapshot coverage is incomplete; uncovered layers: $joined"
    warn 'Universal configuration recovery remains available; package rollback stays manual.'
    [[ ${ASSUME_YES:-0} == 1 ]] && return 0
    if [[ -t 0 ]]; then
        read -r -p 'Proceed with this recovery limitation? [y/N] ' answer
        [[ $answer == [yY] || $answer == [yY][eE][sS] ]] && return 0
    fi
    return 2
}

_preflight_add_manual() {
    local class=$1

    _preflight_safe_class "$class" || return 1
    if ! grep -Fxq -- "$class" "$_PREFLIGHT_MANUAL_FILE"; then
        printf '%s\n' "$class" >> "$_PREFLIGHT_MANUAL_FILE" || return 1
    fi
}

_preflight_record() {
    local name=$1 exit_status=$2 failure_class=${3:-} status=passed numeric

    _preflight_safe_name "$name" || return 1
    [[ $exit_status =~ ^[0-9]{1,3}$ ]] || return 1
    numeric=$((10#$exit_status))
    ((numeric >= 0 && numeric <= 255)) || return 1
    if ((numeric != 0)); then
        status=failed
        _PREFLIGHT_REQUIRED_FAILED=1
        _preflight_add_manual "$failure_class" || return 1
    elif [[ -n $failure_class ]]; then
        _preflight_safe_class "$failure_class" || return 1
    fi
    jq -cn --arg name "$name" --arg status "$status" \
        --argjson exit_status "$numeric" '
        {name: $name, status: $status, exit_status: $exit_status}
    ' >> "$_PREFLIGHT_CHECKS_FILE"
}

_preflight_required_commands() {
    local operation=$1 profile=$2 name failed=0
    local -a required=(
        bash git jq flock realpath rsync sha256sum stat timeout pacman
    )

    if [[ $operation == dotfiles ]]; then
        required+=(stow)
    else
        required+=(sed awk)
    fi
    if [[ $profile == desktop || $profile == full ]]; then
        required+=(systemctl)
    fi
    for name in "${required[@]}"; do
        _preflight_command_available "$name" >/dev/null 2>&1 || failed=1
    done
    _preflight_record required-commands "$failed" required-command-missing
}

_preflight_free_space() {
    local operation=$1 repo=$2 package_path=/var status=0 package_minimum=524288

    if [[ -d /var/cache/pacman/pkg ]]; then
        package_path=/var/cache/pacman/pkg
    elif [[ -d /var/cache/pacman ]]; then
        package_path=/var/cache/pacman
    fi
    _preflight_space_available repository "$repo" 262144 \
        >/dev/null 2>&1 || status=1
    _preflight_space_available home "$HOME" 524288 \
        >/dev/null 2>&1 || status=1
    [[ $operation != system ]] || package_minimum=2097152
    _preflight_space_available packages "$package_path" "$package_minimum" \
        >/dev/null 2>&1 || status=1
    _preflight_record free-space "$status" low-space
}

_preflight_invalidate_previous() {
    local tx_dir=$1 operation=$2 profile=$3 next

    next=$(mktemp "$tx_dir/.preflight.pending.XXXXXXXX") || return 1
    if ! jq -n --arg id "${tx_dir##*/}" --arg operation "$operation" \
        --arg profile "$profile" '
        {
            version: 1,
            transaction_id: $id,
            operation: $operation,
            profile: $profile,
            result: "in-progress",
            required_passed: false
        }
    ' > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    chmod 0600 -- "$next" || {
        rm -f -- "$next"
        return 1
    }
    mv -- "$next" "$tx_dir/preflight.json" || {
        rm -f -- "$next"
        return 1
    }
}

_preflight_publish() {
    local operation=$1 profile=$2 now result=passed required_passed=true next

    if [[ $_PREFLIGHT_REQUIRED_FAILED -ne 0 ]]; then
        result=failed
        required_passed=false
    fi
    now=$(timestamp)
    next=$(mktemp "$_PREFLIGHT_TX_DIR/.preflight.XXXXXXXX") || return 1
    if ! jq -n --slurpfile checks "$_PREFLIGHT_CHECKS_FILE" \
        --rawfile manual "$_PREFLIGHT_MANUAL_FILE" \
        --arg id "${_PREFLIGHT_TX_DIR##*/}" --arg operation "$operation" \
        --arg profile "$profile" --arg now "$now" --arg result "$result" \
        --argjson required "$required_passed" '
        {
            version: 1,
            transaction_id: $id,
            operation: $operation,
            profile: $profile,
            created_at: $now,
            result: $result,
            required_passed: $required,
            checks: $checks,
            manual_intervention: (
                $manual | split("\n") | map(select(length > 0)) | unique
            )
        }
    ' > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    chmod 0600 -- "$next" || {
        rm -f -- "$next"
        return 1
    }
    mv -- "$next" "$_PREFLIGHT_TX_DIR/preflight.json" || {
        rm -f -- "$next"
        return 1
    }
    [[ $required_passed == true ]]
}

maintenance_preflight() {
    local operation=${1:-} profile=${2:-} tx_dir=${3:-} repo=${4:-}
    local status probe provider result=0

    _preflight_context "$operation" "$profile" "$tx_dir" "$repo" || return $?
    tx_dir=$_PREFLIGHT_TX_DIR
    if [[ -e $tx_dir/preflight.json || -L $tx_dir/preflight.json ]]; then
        _maintenance_validate_owned_file "$tx_dir/preflight.json" || return 1
    fi
    umask 077
    _PREFLIGHT_CHECKS_FILE=$(mktemp "$tx_dir/.preflight-checks.XXXXXXXX") || \
        return 1
    _PREFLIGHT_MANUAL_FILE=$(mktemp "$tx_dir/.preflight-manual.XXXXXXXX") || {
        rm -f -- "$_PREFLIGHT_CHECKS_FILE"
        return 1
    }
    chmod 0600 -- "$_PREFLIGHT_CHECKS_FILE" "$_PREFLIGHT_MANUAL_FILE" || {
        rm -f -- "$_PREFLIGHT_CHECKS_FILE" "$_PREFLIGHT_MANUAL_FILE"
        return 1
    }
    _PREFLIGHT_REQUIRED_FAILED=0
    _preflight_invalidate_previous "$tx_dir" "$operation" "$profile" || {
        rm -f -- "$_PREFLIGHT_CHECKS_FILE" "$_PREFLIGHT_MANUAL_FILE"
        return 1
    }

    _preflight_required_commands "$operation" "$profile" || result=74
    _preflight_free_space "$operation" "$_PREFLIGHT_REPO" || result=74

    status=0
    _preflight_pacman_unlocked >/dev/null 2>&1 || status=$?
    _preflight_record package-manager-lock "$status" package-manager-active || \
        result=74

    status=0
    _preflight_repo_clean "$_PREFLIGHT_REPO" >/dev/null 2>&1 || status=$?
    _preflight_record repository-clean "$status" worktree-dirty || result=74

    status=0
    _preflight_remote_ready "$_PREFLIGHT_REPO" >/dev/null 2>&1 || status=$?
    _preflight_record upstream-network "$status" upstream-unavailable || result=74

    status=0
    _preflight_candidate_evidence "$tx_dir" >/dev/null 2>&1 || status=$?
    _preflight_record candidate-evidence "$status" candidate-untrusted || result=74

    status=0
    _preflight_os_supported >/dev/null 2>&1 || status=$?
    _preflight_record operating-system "$status" unsupported-operating-system || \
        result=74

    probe="$tx_dir/snapshot-probe.json"
    status=0
    if ! _preflight_snapshot_validate "$probe"; then
        status=1
    elif _preflight_snapshot_accepted "$probe"; then
        provider=$(jq -er '.provider' "$probe") || status=1
        if [[ $status -eq 0 ]]; then
            maintenance_tx_set_recovery "$tx_dir" pending "$provider" \
                "$(jq -c . "$probe")" || status=1
        fi
    else
        status=$?
    fi
    _preflight_record snapshot-coverage "$status" \
        snapshot-coverage-unaccepted || result=74

    if [[ $result -ne 0 ]]; then
        rm -f -- "$_PREFLIGHT_CHECKS_FILE" "$_PREFLIGHT_MANUAL_FILE"
        warn 'Preflight could not complete its bounded evidence.'
        return "$result"
    fi
    _preflight_publish "$operation" "$profile" || result=$?
    rm -f -- "$_PREFLIGHT_CHECKS_FILE" "$_PREFLIGHT_MANUAL_FILE"
    [[ $result -eq 0 ]] || warn 'Required maintenance preflight checks did not pass.'
    return "$result"
}
