#!/usr/bin/env bash

# Private, atomic transaction state for MyHyprlandRice maintenance commands.
# This library is sourced after scripts/lib.sh and intentionally does not set
# shell options for its caller.
# shellcheck disable=SC2016  # Single-quoted jq programs must not expand in Bash.

_maintenance_safe_class() {
    [[ ${1:-} =~ ^[a-z0-9-]{1,64}$ ]]
}

_maintenance_safe_transaction_id() {
    [[ ${1:-} =~ ^txn\.[A-Za-z0-9]{8}$ ]]
}

_maintenance_path_has_traversal() {
    local path=${1:-}
    [[ /$path/ == *'/../'* || /$path/ == *'/./'* ]]
}

_maintenance_validate_owned_directory() {
    local path=$1 owner mode numeric_mode

    [[ -d $path && ! -L $path ]] || return 1
    owner=$(stat -c %u -- "$path" 2>/dev/null) || return 1
    [[ $owner == "$(id -u)" ]] || return 1
    mode=$(stat -c %a -- "$path" 2>/dev/null) || return 1
    [[ $mode =~ ^[0-7]{3,4}$ ]] || return 1
    numeric_mode=$((8#$mode))
    (( (numeric_mode & 0022) == 0 ))
}

_maintenance_validate_owned_file() {
    local path=$1 owner mode numeric_mode

    [[ -f $path && ! -L $path ]] || return 1
    owner=$(stat -c %u -- "$path" 2>/dev/null) || return 1
    [[ $owner == "$(id -u)" ]] || return 1
    mode=$(stat -c %a -- "$path" 2>/dev/null) || return 1
    [[ $mode =~ ^[0-7]{3,4}$ ]] || return 1
    numeric_mode=$((8#$mode))
    (( (numeric_mode & 0077) == 0 ))
}

_maintenance_validate_private_directory() {
    local path=$1 mode numeric_mode

    _maintenance_validate_owned_directory "$path" || return 1
    mode=$(stat -c %a -- "$path" 2>/dev/null) || return 1
    numeric_mode=$((8#$mode))
    (( (numeric_mode & 0077) == 0 ))
}

_maintenance_prepare_xdg_root() {
    local configured=$1 canonical

    [[ $configured == /* && $configured != / ]] || {
        warn 'Maintenance XDG roots must be absolute private directories below /.'
        return 1
    }
    [[ $configured != *$'\n'* && $configured != *$'\t'* ]] || return 1
    if _maintenance_path_has_traversal "$configured"; then
        warn 'Maintenance XDG roots may not contain traversal components.'
        return 1
    fi
    [[ ! -L $configured ]] || {
        warn 'A configured maintenance XDG root is a symlink.'
        return 1
    }
    if [[ ! -e $configured ]]; then
        mkdir -p -- "$configured" || return 1
        chmod 0700 -- "$configured" || return 1
    fi
    _maintenance_validate_owned_directory "$configured" || {
        warn 'A maintenance XDG root has unsafe ownership or permissions.'
        return 1
    }
    canonical=$(realpath -e -- "$configured" 2>/dev/null) || return 1
    [[ $canonical != / ]] || return 1
    printf '%s\n' "$canonical"
}

_maintenance_prepare_private_root() {
    local parent=$1 leaf=$2 path canonical_parent canonical

    canonical_parent=$(realpath -e -- "$parent" 2>/dev/null) || return 1
    path="$canonical_parent/$leaf"
    [[ ! -L $path ]] || {
        warn 'A maintenance-owned root is a symlink.'
        return 1
    }
    if [[ ! -e $path ]]; then
        mkdir -m 0700 -- "$path" || return 1
    fi
    _maintenance_validate_owned_directory "$path" || {
        warn 'A maintenance-owned root has unsafe ownership or permissions.'
        return 1
    }
    chmod 0700 -- "$path" || return 1
    _maintenance_validate_private_directory "$path" || return 1
    canonical=$(realpath -e -- "$path" 2>/dev/null) || return 1
    [[ $canonical == "$canonical_parent/$leaf" ]] || return 1
    printf '%s\n' "$canonical"
}

maintenance_paths_init() {
    local state_base runtime_base state_config runtime_config

    state_config=${XDG_STATE_HOME:-${HOME:?HOME is required}/.local/state}
    runtime_config=${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-${HOME:?HOME is required}/.cache}}
    umask 077

    state_base=$(_maintenance_prepare_xdg_root "$state_config") || return 1
    runtime_base=$(_maintenance_prepare_xdg_root "$runtime_config") || return 1
    MAINTENANCE_STATE_ROOT=$(
        _maintenance_prepare_private_root "$state_base" myhyprlandrice
    ) || return 1
    MAINTENANCE_RUNTIME_ROOT=$(
        _maintenance_prepare_private_root "$runtime_base" myhypr
    ) || return 1
    MAINTENANCE_TX_ROOT=$(
        _maintenance_prepare_private_root "$MAINTENANCE_STATE_ROOT" transactions
    ) || return 1
    export MAINTENANCE_STATE_ROOT MAINTENANCE_RUNTIME_ROOT MAINTENANCE_TX_ROOT
}

_maintenance_close_lock_fd() {
    local fd=${MYHYPR_MAINTENANCE_LOCK_FD:-}

    [[ $fd =~ ^[0-9]+$ ]] || return 0
    eval "exec ${fd}>&-"
    unset MYHYPR_MAINTENANCE_LOCK_FD
}

maintenance_lock_acquire() {
    local lock_file active=initializing

    [[ -n ${MAINTENANCE_RUNTIME_ROOT:-} ]] || maintenance_paths_init || return 1
    if [[ ${MYHYPR_MAINTENANCE_LOCK_FD:-} =~ ^[0-9]+$ && \
        -e /proc/$$/fd/$MYHYPR_MAINTENANCE_LOCK_FD ]]; then
        warn 'This process already holds a MyHypr maintenance lock.'
        return 75
    fi
    lock_file="$MAINTENANCE_RUNTIME_ROOT/maintenance.lock"
    if [[ -e $lock_file || -L $lock_file ]]; then
        _maintenance_validate_owned_file "$lock_file" || {
            warn 'The maintenance lock file has unsafe ownership or permissions.'
            return 1
        }
    fi

    exec {MYHYPR_MAINTENANCE_LOCK_FD}>>"$lock_file" || return 1
    chmod 0600 -- "$lock_file" || {
        _maintenance_close_lock_fd
        return 1
    }
    if ! flock -n "$MYHYPR_MAINTENANCE_LOCK_FD"; then
        if IFS= read -r active < "$lock_file" && ! _maintenance_safe_transaction_id "$active"; then
            active=initializing
        fi
        warn "Another MyHypr maintenance transaction is active: $active"
        _maintenance_close_lock_fd
        return 75
    fi
    printf 'initializing\n' > "$lock_file" || {
        _maintenance_close_lock_fd
        return 1
    }
}

_maintenance_commit_value_valid() {
    [[ -z ${1:-} || ${1:-} =~ ^[0-9a-f]{40}$ ]]
}

maintenance_tx_begin() {
    local operation=${1:-} profile=${2:-} current=${3:-} candidate=${4:-}
    local tx_dir tx_id journal_tmp now lock_file lock_target lock_canonical

    [[ ${MYHYPR_MAINTENANCE_LOCK_FD:-} =~ ^[0-9]+$ ]] || {
        warn 'The maintenance lock must be acquired before beginning a transaction.'
        return 1
    }
    [[ -e /proc/$$/fd/$MYHYPR_MAINTENANCE_LOCK_FD ]] || return 1
    lock_file="$MAINTENANCE_RUNTIME_ROOT/maintenance.lock"
    lock_target=$(readlink -f -- "/proc/$$/fd/$MYHYPR_MAINTENANCE_LOCK_FD" 2>/dev/null) || \
        return 1
    lock_canonical=$(realpath -e -- "$lock_file" 2>/dev/null) || return 1
    [[ $lock_target == "$lock_canonical" ]] || return 1
    flock -n "$MYHYPR_MAINTENANCE_LOCK_FD" || return 75
    [[ -z ${MYHYPR_TRANSACTION_DIR:-} ]] || {
        warn 'This process already owns a maintenance transaction.'
        return 1
    }
    _maintenance_safe_class "$operation" && _maintenance_safe_class "$profile" || return 1
    _maintenance_commit_value_valid "$current" && \
        _maintenance_commit_value_valid "$candidate" || return 1

    tx_dir=$(mktemp -d "$MAINTENANCE_TX_ROOT/txn.XXXXXXXX") || return 1
    chmod 0700 -- "$tx_dir" || {
        rm -rf -- "$tx_dir"
        return 1
    }
    tx_id=${tx_dir##*/}
    if ! _maintenance_safe_transaction_id "$tx_id"; then
        rm -rf -- "$tx_dir"
        return 1
    fi
    journal_tmp=$(mktemp "$tx_dir/.journal.new.XXXXXXXX") || {
        rm -rf -- "$tx_dir"
        return 1
    }
    now=$(timestamp)
    if ! jq -n \
        --arg id "$tx_id" \
        --arg operation "$operation" \
        --arg profile "$profile" \
        --arg now "$now" \
        --arg current "$current" \
        --arg candidate "$candidate" '
        {
            version: 1,
            id: $id,
            operation: $operation,
            profile: $profile,
            state: "planned",
            stage: "initializing",
            result: "in-progress",
            created_at: $now,
            updated_at: $now,
            current_commit: $current,
            candidate_commit: $candidate,
            completed_stages: [],
            recovery: {
                configuration: "pending",
                system_provider: "none",
                system_coverage: "none"
            },
            failure: null,
            artifacts: {
                checkpoint: "checkpoint/checkpoint.json",
                package_log: "logs/packages.log",
                git: "git.json",
                snapshot: "snapshot.json",
                postflight: "postflight.json"
            }
        }
    ' > "$journal_tmp"; then
        rm -f -- "$journal_tmp"
        rm -rf -- "$tx_dir"
        return 1
    fi
    chmod 0600 -- "$journal_tmp" || {
        rm -f -- "$journal_tmp"
        rm -rf -- "$tx_dir"
        return 1
    }
    mv -- "$journal_tmp" "$tx_dir/journal.json" || {
        rm -f -- "$journal_tmp"
        rm -rf -- "$tx_dir"
        return 1
    }

    printf '%s\n' "$tx_id" > "$lock_file" || {
        rm -rf -- "$tx_dir"
        return 1
    }
    MYHYPR_TRANSACTION_DIR=$tx_dir
    export MYHYPR_TRANSACTION_DIR
}

_maintenance_tx_validate() {
    local requested=${1:-} canonical root_canonical id journal_id version

    [[ -n ${MAINTENANCE_TX_ROOT:-} && -n $requested ]] || return 1
    [[ $requested == "$MAINTENANCE_TX_ROOT"/* ]] || return 1
    [[ $(dirname -- "$requested") == "$MAINTENANCE_TX_ROOT" ]] || return 1
    id=${requested##*/}
    _maintenance_safe_transaction_id "$id" || return 1
    _maintenance_validate_private_directory "$requested" || return 1
    canonical=$(realpath -e -- "$requested" 2>/dev/null) || return 1
    root_canonical=$(realpath -e -- "$MAINTENANCE_TX_ROOT" 2>/dev/null) || return 1
    [[ $canonical == "$root_canonical/$id" ]] || return 1
    _maintenance_validate_owned_file "$canonical/journal.json" || return 1
    version=$(jq -er '.version | select(type == "number")' \
        "$canonical/journal.json" 2>/dev/null) || return 1
    journal_id=$(jq -er '.id | select(type == "string")' \
        "$canonical/journal.json" 2>/dev/null) || return 1
    [[ $version == 1 && $journal_id == "$id" ]] || return 1
    _MAINTENANCE_VALIDATED_TX_DIR=$canonical
}

_maintenance_tx_require_active() {
    local requested=$1 active fd lock_file lock_target lock_canonical lock_id

    _maintenance_tx_validate "$requested" || return 1
    [[ -n ${MYHYPR_TRANSACTION_DIR:-} ]] || return 1
    active=$(realpath -e -- "$MYHYPR_TRANSACTION_DIR" 2>/dev/null) || return 1
    [[ $_MAINTENANCE_VALIDATED_TX_DIR == "$active" ]] || return 1

    fd=${MYHYPR_MAINTENANCE_LOCK_FD:-}
    [[ $fd =~ ^[0-9]+$ && -e /proc/$$/fd/$fd ]] || return 1
    lock_file="$MAINTENANCE_RUNTIME_ROOT/maintenance.lock"
    _maintenance_validate_owned_file "$lock_file" || return 1
    lock_target=$(readlink -f -- "/proc/$$/fd/$fd" 2>/dev/null) || return 1
    lock_canonical=$(realpath -e -- "$lock_file" 2>/dev/null) || return 1
    [[ $lock_target == "$lock_canonical" ]] || return 1
    flock -n "$fd" || return 75
    IFS= read -r lock_id < "$lock_file" || return 1
    [[ $lock_id == "${_MAINTENANCE_VALIDATED_TX_DIR##*/}" ]]
}

maintenance_journal_update() {
    local tx_dir=$1 filter=$2 journal next
    shift 2

    _maintenance_tx_require_active "$tx_dir" || return 1
    tx_dir=$_MAINTENANCE_VALIDATED_TX_DIR
    journal="$tx_dir/journal.json"
    next=$(mktemp "$tx_dir/.journal.XXXXXXXX") || return 1
    if ! jq "$@" "$filter" "$journal" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    if ! jq -e --arg id "${tx_dir##*/}" \
        '.version == 1 and .id == $id' "$next" >/dev/null; then
        rm -f -- "$next"
        return 1
    fi
    chmod 0600 -- "$next" || {
        rm -f -- "$next"
        return 1
    }
    if ! mv -- "$next" "$journal"; then
        rm -f -- "$next"
        return 1
    fi
}

_maintenance_transition_allowed() {
    case ${1:-}:${2:-} in
        planned:preflighted|preflighted:checkpointed|checkpointed:applying|\
            applying:verifying|verifying:committed|planned:failed|\
            preflighted:failed|checkpointed:failed|applying:failed|\
            verifying:failed|failed:recovering|recovering:recovered|\
            recovering:needs-attention|needs-attention:recovering) return 0 ;;
        *) return 1 ;;
    esac
}

maintenance_tx_transition() {
    local tx_dir=${1:-} expected=${2:-} next=${3:-} stage=${4:-}
    local current now result=in-progress

    _maintenance_safe_class "$stage" || return 1
    _maintenance_transition_allowed "$expected" "$next" || return 1
    _maintenance_tx_require_active "$tx_dir" || return 1
    current=$(jq -er '.state | select(type == "string")' \
        "$_MAINTENANCE_VALIDATED_TX_DIR/journal.json" 2>/dev/null) || return 1
    [[ $current == "$expected" ]] || return 1
    case $next in
        committed) result=success ;;
        failed) result=failed ;;
        recovered) result=recovered ;;
        needs-attention) result=needs-attention ;;
    esac
    now=$(timestamp)
    maintenance_journal_update "$tx_dir" '
        .state = $next |
        .stage = $stage |
        .result = $result |
        .updated_at = $now
    ' --arg next "$next" --arg stage "$stage" --arg result "$result" --arg now "$now"
}

maintenance_tx_complete_stage() {
    local tx_dir=${1:-} stage=${2:-} now

    _maintenance_safe_class "$stage" || return 1
    now=$(timestamp)
    maintenance_journal_update "$tx_dir" '
        .stage = $stage |
        .updated_at = $now |
        if (.completed_stages | index($stage)) == null then
            .completed_stages += [$stage]
        else . end
    ' --arg stage "$stage" --arg now "$now"
}

maintenance_tx_fail() {
    local tx_dir=${1:-} stage=${2:-} exit_status=${3:-} message_class=${4:-}
    local current now numeric_status

    _maintenance_safe_class "$stage" && _maintenance_safe_class "$message_class" || return 1
    [[ $exit_status =~ ^[0-9]{1,3}$ ]] || return 1
    numeric_status=$((10#$exit_status))
    (( numeric_status >= 1 && numeric_status <= 255 )) || return 1
    _maintenance_tx_require_active "$tx_dir" || return 1
    current=$(jq -er '.state | select(type == "string")' \
        "$_MAINTENANCE_VALIDATED_TX_DIR/journal.json" 2>/dev/null) || return 1
    _maintenance_transition_allowed "$current" failed || return 1
    now=$(timestamp)
    maintenance_journal_update "$tx_dir" '
        .state = "failed" |
        .stage = $stage |
        .result = "failed" |
        .updated_at = $now |
        .failure = {
            stage: $stage,
            exit_status: $exit_status,
            message_class: $message_class
        }
    ' --arg stage "$stage" --argjson exit_status "$numeric_status" \
        --arg message_class "$message_class" --arg now "$now"
}

maintenance_tx_set_recovery() {
    local tx_dir=${1:-} configuration=${2:-} provider=${3:-} coverage=${4:-}
    local coverage_json now

    _maintenance_safe_class "$configuration" && _maintenance_safe_class "$provider" || return 1
    if jq -e . >/dev/null 2>&1 <<< "$coverage"; then
        coverage_json=$(jq -c . <<< "$coverage") || return 1
    else
        _maintenance_safe_class "$coverage" || return 1
        coverage_json=$(jq -Rn --arg value "$coverage" '$value') || return 1
    fi
    now=$(timestamp)
    maintenance_journal_update "$tx_dir" '
        .recovery.configuration = $configuration |
        .recovery.system_provider = $provider |
        .recovery.system_coverage = $coverage |
        .updated_at = $now
    ' --arg configuration "$configuration" --arg provider "$provider" \
        --argjson coverage "$coverage_json" --arg now "$now"
}

maintenance_tx_latest() {
    local candidate id mtime latest_path='' latest_mtime=-1

    [[ -n ${MAINTENANCE_TX_ROOT:-} ]] || maintenance_paths_init || return 1
    while IFS= read -r -d '' candidate; do
        id=${candidate##*/}
        _maintenance_safe_transaction_id "$id" || continue
        _maintenance_tx_validate "$candidate" || continue
        mtime=$(stat -c %Y -- "$_MAINTENANCE_VALIDATED_TX_DIR" 2>/dev/null) || continue
        if (( mtime > latest_mtime )) || \
            { (( mtime == latest_mtime )) && [[ $candidate > $latest_path ]]; }; then
            latest_mtime=$mtime
            latest_path=$_MAINTENANCE_VALIDATED_TX_DIR
        fi
    done < <(find "$MAINTENANCE_TX_ROOT" -mindepth 1 -maxdepth 1 -type d -print0)
    [[ -n $latest_path ]] || return 1
    printf '%s\n' "$latest_path"
}

_maintenance_postflight_passed() {
    local tx_dir=$1
    local postflight="$tx_dir/postflight.json"

    _maintenance_validate_owned_file "$postflight" || return 1
    jq -e '.required_passed == true' "$postflight" >/dev/null 2>&1
}

maintenance_known_good_prepare() {
    local tx_dir=${1:-} journal state operation commit id now
    local pending pending_digest pending_tmp digest_tmp digest

    _maintenance_tx_require_active "$tx_dir" || return 1
    tx_dir=$_MAINTENANCE_VALIDATED_TX_DIR
    journal="$tx_dir/journal.json"
    state=$(jq -er '.state' "$journal" 2>/dev/null) || return 1
    [[ $state == verifying ]] || return 1
    jq -e '.completed_stages | index("postflight") != null' "$journal" >/dev/null || return 1
    _maintenance_postflight_passed "$tx_dir" || return 1
    operation=$(jq -er '.operation | select(type == "string")' "$journal") || return 1
    commit=$(jq -er '
        if .candidate_commit != "" then .candidate_commit else .current_commit end |
        select(type == "string")
    ' "$journal") || return 1
    _maintenance_commit_value_valid "$commit" && [[ -n $commit ]] || return 1
    id=${tx_dir##*/}
    now=$(timestamp)
    pending="$MAINTENANCE_STATE_ROOT/known-good.pending.json"
    pending_digest="$MAINTENANCE_STATE_ROOT/known-good.pending.sha256"
    [[ ! -L $pending && ! -L $pending_digest ]] || return 1
    pending_tmp=$(mktemp "$MAINTENANCE_STATE_ROOT/.known-good.pending.XXXXXXXX") || return 1
    digest_tmp=$(mktemp "$MAINTENANCE_STATE_ROOT/.known-good.digest.XXXXXXXX") || {
        rm -f -- "$pending_tmp"
        return 1
    }
    if ! jq -n --arg id "$id" --arg operation "$operation" \
        --arg commit "$commit" --arg now "$now" '
        {
            version: 1,
            transaction_id: $id,
            operation: $operation,
            commit: $commit,
            timestamp: $now
        }
    ' > "$pending_tmp"; then
        rm -f -- "$pending_tmp" "$digest_tmp"
        return 1
    fi
    chmod 0600 -- "$pending_tmp" "$digest_tmp" || {
        rm -f -- "$pending_tmp" "$digest_tmp"
        return 1
    }
    mv -- "$pending_tmp" "$pending" || {
        rm -f -- "$pending_tmp" "$digest_tmp"
        return 1
    }
    digest=$(sha256sum "$pending" | cut -d' ' -f1) || {
        rm -f -- "$digest_tmp"
        return 1
    }
    printf '%s  known-good.pending.json\n' "$digest" > "$digest_tmp" || {
        rm -f -- "$digest_tmp"
        return 1
    }
    mv -- "$digest_tmp" "$pending_digest" || {
        rm -f -- "$digest_tmp"
        return 1
    }
}

maintenance_known_good_promote() {
    local tx_dir=${1:-} journal state pending pending_digest known_good
    local expected actual id operation commit final_tmp

    _maintenance_tx_require_active "$tx_dir" || return 1
    tx_dir=$_MAINTENANCE_VALIDATED_TX_DIR
    journal="$tx_dir/journal.json"
    state=$(jq -er '.state' "$journal" 2>/dev/null) || return 1
    [[ $state == committed ]] || return 1
    pending="$MAINTENANCE_STATE_ROOT/known-good.pending.json"
    pending_digest="$MAINTENANCE_STATE_ROOT/known-good.pending.sha256"
    known_good="$MAINTENANCE_STATE_ROOT/known-good.json"
    _maintenance_validate_owned_file "$pending" || return 1
    _maintenance_validate_owned_file "$pending_digest" || return 1
    read -r expected _ < "$pending_digest" || return 1
    [[ $expected =~ ^[0-9a-f]{64}$ ]] || return 1
    actual=$(sha256sum "$pending" | cut -d' ' -f1) || return 1
    [[ $actual == "$expected" ]] || return 1

    id=${tx_dir##*/}
    operation=$(jq -er '.operation' "$journal") || return 1
    commit=$(jq -er '
        if .candidate_commit != "" then .candidate_commit else .current_commit end
    ' "$journal") || return 1
    jq -e --arg id "$id" --arg operation "$operation" --arg commit "$commit" '
        .version == 1 and .transaction_id == $id and
        .operation == $operation and .commit == $commit and
        (.timestamp | type == "string") and
        (keys | sort) == (["commit","operation","timestamp","transaction_id","version"] | sort)
    ' "$pending" >/dev/null || return 1
    [[ ! -L $known_good ]] || return 1
    final_tmp=$(mktemp "$MAINTENANCE_STATE_ROOT/.known-good.XXXXXXXX") || return 1
    if ! jq '{version,transaction_id,operation,commit,timestamp}' \
        "$pending" > "$final_tmp"; then
        rm -f -- "$final_tmp"
        return 1
    fi
    chmod 0600 -- "$final_tmp" || {
        rm -f -- "$final_tmp"
        return 1
    }
    mv -- "$final_tmp" "$known_good" || {
        rm -f -- "$final_tmp"
        return 1
    }
    rm -f -- "$pending" "$pending_digest"
}

_maintenance_log_filter() {
    LC_ALL=C sed -E \
        -e $'s/\033\\[[0-?]*[ -\\/]*[@-~]//g' \
        -e 's#([A-Za-z][A-Za-z0-9+.-]*://)[^/@[:space:]]+@#\1[REDACTED]@#g' \
        -e 's/(Authorization:[[:space:]]*Bearer)[[:space:]]+[^[:space:]]+/\1 [REDACTED]/gI' \
        -e 's/(password|passwd|token|secret|api[_-]?key)([[:space:]]*[:=][[:space:]]*|[[:space:]]+)[^[:space:]]+/\1\2[REDACTED]/gI' \
        -e 's/(gh[pousr]_[A-Za-z0-9]{20,}|AKIA[A-Z0-9]{16})/[REDACTED]/g' |
        LC_ALL=C tr -d '\000-\010\013\014\016-\037\177'
}

maintenance_log_run() {
    local tx_dir=${1:-} log_name=${2:-} logs_dir final next
    local had_errexit=0 command_status filter_status tee_status
    local -a pipeline_status
    shift 2 || return 1

    [[ $log_name =~ ^[a-z0-9][a-z0-9._-]{0,63}$ && $# -gt 0 ]] || return 1
    _maintenance_tx_require_active "$tx_dir" || return 1
    tx_dir=$_MAINTENANCE_VALIDATED_TX_DIR
    logs_dir="$tx_dir/logs"
    [[ ! -L $logs_dir ]] || return 1
    if [[ ! -e $logs_dir ]]; then
        mkdir -m 0700 -- "$logs_dir" || return 1
    fi
    _maintenance_validate_private_directory "$logs_dir" || return 1
    chmod 0700 -- "$logs_dir" || return 1
    final="$logs_dir/$log_name"
    [[ ! -L $final ]] || return 1
    next=$(mktemp "$logs_dir/.filtered.XXXXXXXX") || return 1
    chmod 0600 -- "$next" || {
        rm -f -- "$next"
        return 1
    }

    [[ $- == *e* ]] && had_errexit=1
    set +e
    "$@" 2>&1 | _maintenance_log_filter | tee "$next"
    pipeline_status=("${PIPESTATUS[@]}")
    command_status=${pipeline_status[0]}
    filter_status=${pipeline_status[1]}
    tee_status=${pipeline_status[2]}
    (( had_errexit == 0 )) || set -e
    if (( filter_status != 0 || tee_status != 0 )); then
        rm -f -- "$next"
        (( filter_status != 0 )) && return "$filter_status"
        return "$tee_status"
    fi
    mv -- "$next" "$final" || {
        rm -f -- "$next"
        return 1
    }
    return "$command_status"
}

maintenance_retention_prune() {
    local candidate state mtime id rank=0 cutoff line tx_dir
    local -a successful=()

    [[ -n ${MAINTENANCE_TX_ROOT:-} ]] || maintenance_paths_init || return 1
    cutoff=$(date -u -d '30 days ago' +%s) || return 1
    while IFS= read -r -d '' candidate; do
        id=${candidate##*/}
        _maintenance_safe_transaction_id "$id" || continue
        _maintenance_tx_validate "$candidate" || continue
        tx_dir=$_MAINTENANCE_VALIDATED_TX_DIR
        state=$(jq -er '.state | select(type == "string")' \
            "$tx_dir/journal.json" 2>/dev/null) || continue
        case $state in
            committed|recovered)
                mtime=$(stat -c %Y -- "$tx_dir" 2>/dev/null) || continue
                successful+=("$mtime"$'\t'"$id")
                ;;
            failed|needs-attention|planned|preflighted|checkpointed|applying|verifying|recovering)
                ;;
        esac
    done < <(find "$MAINTENANCE_TX_ROOT" -mindepth 1 -maxdepth 1 -type d -print0)

    while IFS= read -r line; do
        [[ -n $line ]] || continue
        mtime=${line%%$'\t'*}
        id=${line#*$'\t'}
        rank=$((rank + 1))
        if (( rank > 10 || mtime < cutoff )); then
            tx_dir="$MAINTENANCE_TX_ROOT/$id"
            _maintenance_tx_validate "$tx_dir" || return 1
            if [[ -n ${MYHYPR_TRANSACTION_DIR:-} && \
                $_MAINTENANCE_VALIDATED_TX_DIR == "$MYHYPR_TRANSACTION_DIR" ]]; then
                continue
            fi
            rm -rf -- "$_MAINTENANCE_VALIDATED_TX_DIR" || return 1
        fi
    done < <(printf '%s\n' "${successful[@]}" | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2r)
}
