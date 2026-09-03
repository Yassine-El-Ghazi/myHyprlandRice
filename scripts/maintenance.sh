#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single-quoted jq programs and literal backticks are intentional.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/lib/maintenance-transaction.sh
source "$SCRIPT_DIR/lib/maintenance-transaction.sh"
# shellcheck source=scripts/lib/maintenance-recovery.sh
source "$SCRIPT_DIR/lib/maintenance-recovery.sh"
# shellcheck source=scripts/lib/maintenance-snapshot.sh
source "$SCRIPT_DIR/lib/maintenance-snapshot.sh"
# shellcheck source=scripts/lib/maintenance-git.sh
source "$SCRIPT_DIR/lib/maintenance-git.sh"
# shellcheck source=scripts/lib/maintenance-postflight.sh
source "$SCRIPT_DIR/lib/maintenance-postflight.sh"
# shellcheck source=scripts/lib/maintenance-preflight.sh
source "$SCRIPT_DIR/lib/maintenance-preflight.sh"

PROFILE=desktop
ASSUME_YES=0
DRY_RUN=0
SNAPSHOT_PROVIDER=auto
COMMAND=''
OPERATION=''
TRANSACTION_ID=''
TX_DIR=''
CURRENT_COMMIT=''
CANDIDATE_COMMIT=''
CANDIDATE_CHANGED=0
LIVE_DESKTOP=0

usage() {
    cat <<'EOF'
Usage:
  scripts/maintenance.sh plan dotfiles [options]
  scripts/maintenance.sh apply dotfiles [options]
  scripts/maintenance.sh status [TRANSACTION_ID]
  scripts/maintenance.sh recover TRANSACTION_ID

Options for plan/apply dotfiles:
  --profile core|desktop|full       Package profile (default: desktop)
  --snapshot auto|none|snapper|timeshift
                                    Recovery provider (default: auto)
  --yes                             Accept prompts non-interactively
  --dry-run                         Prepare and print the plan without applying
  -h, --help                        Show this help

Compatibility: scripts/update.sh forwards its options to `apply dotfiles`.
EOF
}

cleanup_process() {
    _maintenance_close_lock_fd
}
trap cleanup_process EXIT

parse_cli() {
    (($# >= 1)) || {
        usage >&2
        return 64
    }
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        plan|apply)
            COMMAND=$1
            shift
            (($# >= 1)) || {
                usage >&2
                return 64
            }
            OPERATION=$1
            shift
            [[ $OPERATION == dotfiles ]] || {
                warn "Unsupported maintenance operation: $OPERATION"
                return 64
            }
            while (($#)); do
                case $1 in
                    --profile)
                        (($# >= 2)) || return 64
                        PROFILE=$2
                        shift 2
                        ;;
                    --snapshot)
                        (($# >= 2)) || return 64
                        SNAPSHOT_PROVIDER=$2
                        shift 2
                        ;;
                    --yes)
                        ASSUME_YES=1
                        shift
                        ;;
                    --dry-run)
                        DRY_RUN=1
                        shift
                        ;;
                    -h|--help)
                        usage
                        exit 0
                        ;;
                    *)
                        warn "Unknown maintenance option: $1"
                        return 64
                        ;;
                esac
            done
            case $PROFILE in core|desktop|full) ;; *) return 64 ;; esac
            case $SNAPSHOT_PROVIDER in
                auto|none|snapper|timeshift) ;;
                *) return 64 ;;
            esac
            [[ $COMMAND != apply || $DRY_RUN -eq 0 ]] || COMMAND=plan
            ;;
        status)
            COMMAND=status
            shift
            (($# <= 1)) || return 64
            TRANSACTION_ID=${1:-}
            ;;
        recover)
            COMMAND=recover
            shift
            (($# == 1)) || return 64
            TRANSACTION_ID=$1
            ;;
        *)
            usage >&2
            return 64
            ;;
    esac
}

transaction_state() {
    jq -er '.state | select(type == "string")' "$1/journal.json" 2>/dev/null
}

transaction_has_stage() {
    jq -e --arg stage "$2" '.completed_stages | index($stage) != null' \
        "$1/journal.json" >/dev/null 2>&1
}

maintenance_maybe_inject_failure() {
    local stage=$1 position=$2 requested=${MYHYPR_MAINTENANCE_FAIL_STAGE:-}

    [[ -n $requested ]] || return 0
    [[ $requested == "$position:$stage" ]] || return 0
    warn "Injected maintenance interruption at $position:$stage."
    if [[ ${MYHYPR_MAINTENANCE_FAIL_MODE:-failure} == interrupt ]]; then
        exit 99
    fi
    return 97
}

record_stage_failure() {
    local stage=$1 status=$2 state

    state=$(transaction_state "$TX_DIR") || return 1
    [[ $state == failed ]] && return 0
    maintenance_tx_fail "$TX_DIR" "$stage" "$status" "${stage}-failed"
}

run_stage() {
    local stage=$1
    shift
    local stage_status=0

    if maintenance_maybe_inject_failure "$stage" before; then
        :
    else
        stage_status=$?
        record_stage_failure "$stage" "$stage_status" || return 74
        return "$stage_status"
    fi
    if "$@"; then
        stage_status=0
    else
        stage_status=$?
        ((stage_status != 0)) || stage_status=1
        record_stage_failure "$stage" "$stage_status" || return 74
        return "$stage_status"
    fi
    maintenance_tx_complete_stage "$TX_DIR" "$stage" || {
        record_stage_failure "$stage" 74 || return 74
        return 74
    }
    if maintenance_maybe_inject_failure "$stage" after; then
        :
    else
        stage_status=$?
        record_stage_failure "$stage" "$stage_status" || return 74
        return "$stage_status"
    fi
}

write_snapshot_probe() {
    local output next

    if output=$(MYHYPR_SNAPSHOT_PROVIDER="$SNAPSHOT_PROVIDER" snapshot_probe); then
        :
    else
        return $?
    fi
    next=$(mktemp "$TX_DIR/.snapshot-probe.XXXXXXXX") || return 1
    if ! printf '%s\n' "$output" > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    chmod 0600 -- "$next" || {
        rm -f -- "$next"
        return 1
    }
    mv -- "$next" "$TX_DIR/snapshot-probe.json" || {
        rm -f -- "$next"
        return 1
    }
}

prepare_update() {
    maintenance_git_prepare "$TX_DIR" "$REPO_ROOT" || return $?
    write_snapshot_probe || return $?
    maintenance_preflight "$OPERATION" "$PROFILE" "$TX_DIR" "$REPO_ROOT"
}

package_counts() {
    local candidate_root=$1 manifest line spec package selected
    local -a manifests=() specs=() alternatives=()
    local -A seen=()

    PACKAGE_REPOSITORY_COUNT=0
    PACKAGE_AUR_COUNT=0
    PACKAGE_COUNTS_AVAILABLE=false
    manifests+=("$candidate_root/packages/arch/core.txt")
    if [[ $PROFILE == desktop || $PROFILE == full ]]; then
        manifests+=("$candidate_root/packages/arch/desktop.txt")
    fi
    [[ $PROFILE != full ]] || manifests+=("$candidate_root/packages/arch/full.txt")
    for manifest in "${manifests[@]}"; do
        [[ -r $manifest ]] || return 0
        while IFS= read -r line || [[ -n $line ]]; do
            line=${line%%#*}
            line=${line//[[:space:]]/}
            [[ -n $line && -z ${seen[$line]+x} ]] || continue
            seen["$line"]=1
            specs+=("$line")
        done < "$manifest"
    done
    command -v pacman >/dev/null 2>&1 || return 0
    for spec in "${specs[@]}"; do
        IFS='|' read -r -a alternatives <<< "$spec"
        selected=''
        for package in "${alternatives[@]}"; do
            if pacman -T -- "$package" >/dev/null 2>&1; then
                selected=$package
                break
            fi
        done
        [[ -z $selected ]] || continue
        for package in "${alternatives[@]}"; do
            if pacman -Si -- "$package" >/dev/null 2>&1; then
                selected=$package
                PACKAGE_REPOSITORY_COUNT=$((PACKAGE_REPOSITORY_COUNT + 1))
                break
            fi
        done
        [[ -n $selected ]] || PACKAGE_AUR_COUNT=$((PACKAGE_AUR_COUNT + 1))
    done
    PACKAGE_COUNTS_AVAILABLE=true
}

flatpak_repair_count() {
    local scope

    FLATPAK_REPAIR_COUNT=0
    FLATPAK_COUNT_AVAILABLE=false
    command -v flatpak >/dev/null 2>&1 || return 0
    for scope in user system; do
        if flatpak remotes "--$scope" --columns=name 2>/dev/null | \
            grep -Fxq -- ml4w-repo; then
            FLATPAK_REPAIR_COUNT=$((FLATPAK_REPAIR_COUNT + 1))
        fi
    done
    FLATPAK_COUNT_AVAILABLE=true
}

mutable_stages() {
    local -a stages=(checkpoint snapshot git-promote packages migration)

    if [[ $PROFILE == desktop || $PROFILE == full ]]; then
        stages+=(flatpak)
    fi
    if [[ $CANDIDATE_CHANGED -eq 1 ]]; then
        stages+=(links)
    fi
    stages+=(seed)
    if [[ $PROFILE == desktop || $PROFILE == full ]]; then
        stages+=(system-config)
    fi
    stages+=(owned-state)
    if [[ $LIVE_DESKTOP -eq 1 && $CANDIDATE_CHANGED -eq 1 ]]; then
        stages+=(desktop-reload)
    fi
    stages+=(postflight known-good)
    local IFS=,
    printf '%s\n' "${stages[*]}"
}

print_plan() {
    local probe manual stages changed=no

    probe="$TX_DIR/snapshot-probe.json"
    manual=$(jq -r '
        if .manual_intervention | length == 0 then "none"
        else .manual_intervention | join(",") end
    ' "$TX_DIR/preflight.json") || return 1
    stages=$(mutable_stages) || return 1
    package_counts "$TX_DIR/candidate"
    flatpak_repair_count
    [[ $CANDIDATE_CHANGED -eq 0 ]] || changed=yes

    printf 'Transaction: %s\n' "${TX_DIR##*/}"
    printf 'Operation: %s\n' "$OPERATION"
    printf 'Profile: %s\n' "$PROFILE"
    printf 'Current commit: %s\n' "$CURRENT_COMMIT"
    printf 'Candidate commit: %s\n' "$CANDIDATE_COMMIT"
    printf 'Candidate changed: %s\n' "$changed"
    printf 'Mutable stages: %s\n' "$stages"
    if [[ $PACKAGE_COUNTS_AVAILABLE == true ]]; then
        printf 'Package actions: repository=%s,aur=%s\n' \
            "$PACKAGE_REPOSITORY_COUNT" "$PACKAGE_AUR_COUNT"
    else
        printf 'Package actions: unavailable\n'
    fi
    if [[ $PROFILE == desktop || $PROFILE == full ]]; then
        if [[ $FLATPAK_COUNT_AVAILABLE == true ]]; then
            printf 'Flatpak repair actions: %s\n' "$FLATPAK_REPAIR_COUNT"
        else
            printf 'Flatpak repair actions: unavailable\n'
        fi
    fi
    printf 'Manual intervention: %s\n' "$manual"
    printf 'Recovery provider: %s\n' "$(jq -r '.provider' "$probe")"
    printf 'Recovery coverage: root=%s,package-db=%s,home=%s,boot=%s\n' \
        "$(jq -r '.coverage.root' "$probe")" \
        "$(jq -r '.coverage.package_db' "$probe")" \
        "$(jq -r '.coverage.home' "$probe")" \
        "$(jq -r '.coverage.boot' "$probe")"
}

authenticate_once() {
    if [[ ${MYHYPR_SUDO_SESSION_READY:-0} == 1 ]]; then
        return 0
    fi
    command -v sudo >/dev/null 2>&1 || return 127
    info 'Authenticating once for privileged maintenance stages'
    if [[ -t 0 ]]; then
        sudo -v || return $?
    else
        sudo -n -v >/dev/null 2>&1 || return $?
    fi
    MYHYPR_SUDO_SESSION_READY=1
    export MYHYPR_SUDO_SESSION_READY
}

run_helper_logged() {
    local log_name=$1 helper=$2
    shift 2

    [[ -x $helper && $helper == "$REPO_ROOT/scripts/"* ]] || return 1
    maintenance_log_run "$TX_DIR" "$log_name" "$helper" "$@"
}

desktop_reload() {
    local waybar="$REPO_ROOT/dotfiles/.config/waybar/launch.sh"
    local dock="$REPO_ROOT/dotfiles/.config/nwg-dock-hyprland/launch.sh"
    local dock_pid dock_status=0

    [[ -x $waybar && -x $dock ]] || return 1
    timeout --kill-after=1 10 hyprctl reload >/dev/null 2>&1 || return $?
    "$waybar" >/dev/null 2>&1 || return $?
    "$dock" >/dev/null 2>&1 &
    dock_pid=$!
    sleep 0.5
    if ! kill -0 "$dock_pid" >/dev/null 2>&1; then
        wait "$dock_pid" || dock_status=$?
        [[ $dock_status -eq 0 ]] || return "$dock_status"
    fi
    timeout --kill-after=1 5 qs ipc show >/dev/null 2>&1 || return $?
    timeout --kill-after=1 5 swaync-client --reload-css >/dev/null 2>&1
}

checkpoint_stage() {
    recovery_checkpoint_create "$TX_DIR" "$REPO_ROOT" "$HOME"
}

snapshot_stage() {
    local saved_yes=$ASSUME_YES status=0

    ASSUME_YES=1
    snapshot_create "$TX_DIR" "$SNAPSHOT_PROVIDER" || status=$?
    ASSUME_YES=$saved_yes
    return "$status"
}

packages_stage() {
    local -a args=(--profile "$PROFILE")

    [[ $ASSUME_YES -eq 0 ]] || args+=(--yes)
    run_helper_logged packages "$REPO_ROOT/scripts/install-packages.sh" "${args[@]}"
}

migration_stage() {
    local -a args=()

    [[ $ASSUME_YES -eq 0 ]] || args+=(--yes)
    run_helper_logged migration "$REPO_ROOT/scripts/migrate-namespace.sh" "${args[@]}"
}

flatpak_stage() {
    local -a args=()

    [[ $ASSUME_YES -eq 0 ]] || args+=(--yes)
    run_helper_logged flatpak "$REPO_ROOT/scripts/repair-flatpak.sh" "${args[@]}"
}

links_stage() {
    local -a args=(--backup-conflicts)

    [[ $ASSUME_YES -eq 0 ]] || args+=(--yes)
    run_helper_logged links "$REPO_ROOT/scripts/link-dotfiles.sh" "${args[@]}"
}

seed_stage() {
    run_helper_logged seed "$REPO_ROOT/scripts/seed-runtime.sh"
}

system_config_stage() {
    local -a args=()

    [[ $ASSUME_YES -eq 0 ]] || args+=(--yes)
    run_helper_logged system-config "$REPO_ROOT/scripts/configure-system.sh" \
        "${args[@]}"
}

known_good_stage() {
    maintenance_known_good_prepare "$TX_DIR"
}

pending_known_good_discard() {
    local pending="$MAINTENANCE_STATE_ROOT/known-good.pending.json"
    local digest="$MAINTENANCE_STATE_ROOT/known-good.pending.sha256" id

    _maintenance_validate_owned_file "$pending" || return 0
    _maintenance_validate_owned_file "$digest" || return 0
    id=$(jq -er '.transaction_id | select(type == "string")' "$pending" \
        2>/dev/null) || return 0
    [[ $id == "${TX_DIR##*/}" ]] || return 0
    rm -f -- "$pending" "$digest"
}

restore_git_state() {
    local current candidate active

    current=$(jq -er '.current_commit | select(type == "string")' \
        "$TX_DIR/journal.json" 2>/dev/null) || return 1
    candidate=$(jq -er '.candidate_commit | select(type == "string")' \
        "$TX_DIR/journal.json" 2>/dev/null) || return 1
    active=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null) || return 1
    if [[ $active == "$current" ]]; then
        return 0
    fi
    if [[ -n $candidate && $active == "$candidate" ]]; then
        maintenance_git_restore_previous "$TX_DIR" "$REPO_ROOT"
        return
    fi
    warn 'Git recovery needs attention because active HEAD is transaction-external.'
    return 1
}

recover_active_transaction() {
    local original_status=${1:-1} state stage recovery_failed=0

    state=$(transaction_state "$TX_DIR") || return 74
    case $state in
        recovered) return 0 ;;
        needs-attention) return 1 ;;
        committed) return 0 ;;
        failed) ;;
        planned|preflighted|checkpointed|applying|verifying)
            stage=$(jq -er '.stage | select(type == "string")' \
                "$TX_DIR/journal.json" 2>/dev/null) || stage=interrupted
            _maintenance_safe_class "$stage" || stage=interrupted
            maintenance_tx_fail "$TX_DIR" "$stage" "$original_status" \
                interrupted || return 74
            ;;
        recovering) ;;
        *) return 74 ;;
    esac
    state=$(transaction_state "$TX_DIR") || return 74
    if [[ $state == failed ]]; then
        maintenance_tx_transition "$TX_DIR" failed recovering recovery || return 74
    fi

    if [[ -d $TX_DIR/checkpoint && ! -L $TX_DIR/checkpoint ]]; then
        if [[ ! -e $TX_DIR/owned-after.tsv && ! -L $TX_DIR/owned-after.tsv ]]; then
            recovery_capture_owned_state "$TX_DIR" "$REPO_ROOT" "$HOME" || \
                recovery_failed=1
        fi
        if [[ $recovery_failed -eq 0 ]]; then
            recovery_checkpoint_restore "$TX_DIR" "$REPO_ROOT" "$HOME" || \
                recovery_failed=1
        fi
    else
        maintenance_journal_update "$TX_DIR" '
            .recovery.configuration = "not-needed" |
            .updated_at = $now
        ' --arg now "$(timestamp)" || recovery_failed=1
    fi

    if [[ -f $TX_DIR/git.json && ! -L $TX_DIR/git.json ]]; then
        restore_git_state || recovery_failed=1
    fi
    if [[ -f $TX_DIR/git.json && ! -L $TX_DIR/git.json ]]; then
        maintenance_git_cleanup "$TX_DIR" "$REPO_ROOT" || recovery_failed=1
    fi
    pending_known_good_discard || recovery_failed=1

    if [[ $recovery_failed -eq 0 ]]; then
        maintenance_tx_transition "$TX_DIR" recovering recovered recovery || return 74
        return 0
    fi
    maintenance_tx_transition "$TX_DIR" recovering needs-attention recovery || return 74
    return 1
}

handle_apply_failure() {
    local status=$1

    recover_active_transaction "$status" >/dev/null 2>&1 || true
    return "$status"
}

begin_dotfiles_transaction() {
    unset MYHYPR_TRANSACTION_DIR MYHYPR_MAINTENANCE_LOCK_FD
    maintenance_paths_init || return $?
    maintenance_lock_acquire || return $?
    CURRENT_COMMIT=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null) || return 1
    [[ $CURRENT_COMMIT =~ ^[0-9a-f]{40}$ ]] || return 1
    maintenance_tx_begin dotfiles "$PROFILE" "$CURRENT_COMMIT" '' || return $?
    TX_DIR=$MYHYPR_TRANSACTION_DIR
}

run_plan() {
    local status

    begin_dotfiles_transaction || return $?
    if run_stage preflight prepare_update; then
        :
    else
        status=$?
        [[ -f $TX_DIR/git.json ]] && maintenance_git_cleanup "$TX_DIR" "$REPO_ROOT" \
            >/dev/null 2>&1 || true
        handle_apply_failure "$status"
        return "$status"
    fi
    CANDIDATE_COMMIT=$(jq -er '.candidate_commit' "$TX_DIR/journal.json") || return 1
    [[ $CANDIDATE_COMMIT != "$CURRENT_COMMIT" ]] && CANDIDATE_CHANGED=1
    if [[ $PROFILE != core && -n ${WAYLAND_DISPLAY:-} && \
        -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
        LIVE_DESKTOP=1
    fi
    maintenance_tx_transition "$TX_DIR" planned preflighted preflight || return 1
    maintenance_journal_update "$TX_DIR" '
        .result = "planned" |
        .updated_at = $now
    ' --arg now "$(timestamp)" || return 1
    print_plan || return 1
    maintenance_git_cleanup "$TX_DIR" "$REPO_ROOT" || {
        maintenance_tx_fail "$TX_DIR" preflight 74 candidate-cleanup-failed || true
        return 74
    }
    success 'Plan completed without changing the active configuration.'
}

run_apply() {
    local status stage function stage_function

    begin_dotfiles_transaction || return $?
    if run_stage preflight prepare_update; then
        :
    else
        status=$?
        handle_apply_failure "$status"
        return "$status"
    fi
    CANDIDATE_COMMIT=$(jq -er '.candidate_commit' "$TX_DIR/journal.json") || return 1
    [[ $CANDIDATE_COMMIT != "$CURRENT_COMMIT" ]] && CANDIDATE_CHANGED=1
    if [[ $PROFILE != core && -n ${WAYLAND_DISPLAY:-} && \
        -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
        LIVE_DESKTOP=1
    fi
    maintenance_tx_transition "$TX_DIR" planned preflighted preflight || return 1

    if run_stage checkpoint checkpoint_stage; then
        :
    else
        status=$?
        handle_apply_failure "$status"
        return "$status"
    fi
    maintenance_tx_transition "$TX_DIR" preflighted checkpointed checkpoint || return 1

    if [[ $SNAPSHOT_PROVIDER != none ]]; then
        if authenticate_once; then
            :
        else
            status=$?
            record_stage_failure snapshot "$status" || return 74
            handle_apply_failure "$status"
            return "$status"
        fi
    fi
    if run_stage snapshot snapshot_stage; then
        :
    else
        status=$?
        handle_apply_failure "$status"
        return "$status"
    fi
    maintenance_tx_transition "$TX_DIR" checkpointed applying snapshot || return 1

    if run_stage git-promote maintenance_git_promote "$TX_DIR" "$REPO_ROOT"; then
        :
    else
        status=$?
        handle_apply_failure "$status"
        return "$status"
    fi
    if authenticate_once; then
        :
    else
        status=$?
        record_stage_failure packages "$status" || return 74
        handle_apply_failure "$status"
        return "$status"
    fi

    for stage_function in packages:packages_stage migration:migration_stage; do
        stage=${stage_function%%:*}
        function=${stage_function#*:}
        if run_stage "$stage" "$function"; then
            :
        else
            status=$?
            handle_apply_failure "$status"
            return "$status"
        fi
    done
    if [[ $PROFILE == desktop || $PROFILE == full ]]; then
        if run_stage flatpak flatpak_stage; then
            :
        else
            status=$?
            handle_apply_failure "$status"
            return "$status"
        fi
    fi
    if [[ $CANDIDATE_CHANGED -eq 1 ]]; then
        if run_stage links links_stage; then
            :
        else
            status=$?
            handle_apply_failure "$status"
            return "$status"
        fi
    fi
    if run_stage seed seed_stage; then
        :
    else
        status=$?
        handle_apply_failure "$status"
        return "$status"
    fi
    if [[ $PROFILE == desktop || $PROFILE == full ]]; then
        if run_stage system-config system_config_stage; then
            :
        else
            status=$?
            handle_apply_failure "$status"
            return "$status"
        fi
    fi
    if run_stage owned-state recovery_capture_owned_state \
        "$TX_DIR" "$REPO_ROOT" "$HOME"; then
        :
    else
        status=$?
        handle_apply_failure "$status"
        return "$status"
    fi
    if [[ $LIVE_DESKTOP -eq 1 && $CANDIDATE_CHANGED -eq 1 ]]; then
        if run_stage desktop-reload desktop_reload; then
            :
        else
            status=$?
            handle_apply_failure "$status"
            return "$status"
        fi
    fi

    maintenance_tx_transition "$TX_DIR" applying verifying postflight || return 1
    if run_stage postflight maintenance_postflight dotfiles "$PROFILE" "$TX_DIR"; then
        :
    else
        status=$?
        handle_apply_failure "$status"
        return "$status"
    fi
    if run_stage known-good known_good_stage; then
        :
    else
        status=$?
        handle_apply_failure "$status"
        return "$status"
    fi
    maintenance_tx_transition "$TX_DIR" verifying committed known-good || return 1
    maintenance_known_good_promote "$TX_DIR" || {
        warn 'Known-good promotion was interrupted; `maintenance.sh status` can reconcile it.'
        return 74
    }
    maintenance_git_cleanup "$TX_DIR" "$REPO_ROOT" || \
        warn 'The validated candidate worktree could not be pruned automatically.'
    maintenance_retention_prune || warn 'Old successful maintenance evidence was not pruned.'
    success 'Dotfiles update committed successfully.'
}

adopt_transaction() {
    local id=$1 requested lock_file

    _maintenance_safe_transaction_id "$id" || return 64
    requested="$MAINTENANCE_TX_ROOT/$id"
    _maintenance_tx_validate "$requested" || return 1
    TX_DIR=$_MAINTENANCE_VALIDATED_TX_DIR
    lock_file="$MAINTENANCE_RUNTIME_ROOT/maintenance.lock"
    printf '%s\n' "$id" > "$lock_file" || return 1
    MYHYPR_TRANSACTION_DIR=$TX_DIR
    export MYHYPR_TRANSACTION_DIR
    _maintenance_tx_require_active "$TX_DIR"
}

reconcile_known_good() {
    local pending="$MAINTENANCE_STATE_ROOT/known-good.pending.json"
    local digest="$MAINTENANCE_STATE_ROOT/known-good.pending.sha256" id state

    _maintenance_validate_owned_file "$pending" || return 0
    _maintenance_validate_owned_file "$digest" || return 0
    id=$(jq -er '
        .transaction_id |
        select(type == "string" and test("^txn\\.[A-Za-z0-9]{8}$"))
    ' "$pending" 2>/dev/null) || return 0
    _maintenance_tx_validate "$MAINTENANCE_TX_ROOT/$id" || return 0
    state=$(transaction_state "$_MAINTENANCE_VALIDATED_TX_DIR") || return 0
    [[ $state == committed ]] || return 0
    adopt_transaction "$id" || return 0
    maintenance_known_good_promote "$TX_DIR" || return 0
    success "Reconciled committed known-good transaction $id."
}

resolve_transaction_for_status() {
    local requested=$1

    if [[ -n $requested ]]; then
        _maintenance_safe_transaction_id "$requested" || return 64
        _maintenance_tx_validate "$MAINTENANCE_TX_ROOT/$requested" || return 1
        printf '%s\n' "$_MAINTENANCE_VALIDATED_TX_DIR"
    else
        maintenance_tx_latest
    fi
}

status_journal_valid() {
    jq -e '
        .version == 1 and
        (.id | type == "string" and test("^txn\\.[A-Za-z0-9]{8}$")) and
        (.operation == "dotfiles" or .operation == "system") and
        (.profile == "core" or .profile == "desktop" or .profile == "full") and
        (.state == "planned" or .state == "preflighted" or
            .state == "checkpointed" or .state == "applying" or
            .state == "verifying" or .state == "committed" or
            .state == "failed" or .state == "recovering" or
            .state == "recovered" or .state == "needs-attention") and
        (.stage | type == "string" and test("^[a-z0-9-]{1,64}$")) and
        (.result == "in-progress" or .result == "planned" or
            .result == "success" or .result == "failed" or
            .result == "recovered" or .result == "needs-attention") and
        (.created_at | type == "string" and test("^[0-9]{8}T[0-9]{6}Z$")) and
        (.updated_at | type == "string" and test("^[0-9]{8}T[0-9]{6}Z$")) and
        (.current_commit | type == "string" and
            (. == "" or test("^[0-9a-f]{40}$"))) and
        (.candidate_commit | type == "string" and
            (. == "" or test("^[0-9a-f]{40}$"))) and
        (.completed_stages | type == "array" and length <= 32) and
        all(.completed_stages[];
            type == "string" and test("^[a-z0-9-]{1,64}$")) and
        (.completed_stages | length) == (.completed_stages | unique | length) and
        (.recovery | type == "object") and
        (.recovery.configuration | type == "string" and
            test("^[a-z0-9-]{1,64}$")) and
        (.recovery.system_provider == "none" or
            .recovery.system_provider == "snapper" or
            .recovery.system_provider == "timeshift") and
        ((.recovery.system_coverage | type) == "string" or
            (.recovery.system_coverage | type) == "object") and
        (
            .failure == null or
            (
                (.failure | keys | sort) ==
                    (["exit_status","message_class","stage"] | sort) and
                (.failure.stage | type == "string" and
                    test("^[a-z0-9-]{1,64}$")) and
                (.failure.exit_status | type == "number" and . >= 1 and . <= 255) and
                (.failure.message_class | type == "string" and
                    test("^[a-z0-9-]{1,64}$"))
            )
        ) and
        (.artifacts | type == "object") and
        (keys | sort) == ([
            "artifacts","candidate_commit","completed_stages","created_at",
            "current_commit","failure","id","operation","profile","recovery",
            "result","stage","state","updated_at","version"
        ] | sort)
    ' "$1" >/dev/null 2>&1
}

print_status() {
    local requested=${1:-} status_tx journal failure manual known_good lock_status

    unset MYHYPR_TRANSACTION_DIR MYHYPR_MAINTENANCE_LOCK_FD
    maintenance_paths_init || return $?
    if maintenance_lock_acquire; then
        reconcile_known_good || true
    else
        lock_status=$?
        [[ $lock_status -eq 75 ]] || return "$lock_status"
    fi
    if ! status_tx=$(resolve_transaction_for_status "$requested"); then
        if [[ -z $requested ]]; then
            printf 'No maintenance transactions found.\n'
            return 0
        fi
        return 1
    fi
    journal="$status_tx/journal.json"
    status_journal_valid "$journal" || return 1
    printf 'Transaction: %s\n' "${status_tx##*/}"
    printf 'Operation: %s\n' "$(jq -r '.operation' "$journal")"
    printf 'Profile: %s\n' "$(jq -r '.profile' "$journal")"
    printf 'State: %s\n' "$(jq -r '.state' "$journal")"
    printf 'Stage: %s\n' "$(jq -r '.stage' "$journal")"
    printf 'Result: %s\n' "$(jq -r '.result' "$journal")"
    printf 'Completed stages: %s\n' "$(jq -r '.completed_stages | join(",")' "$journal")"
    failure=$(jq -r 'if .failure == null then "none" else .failure.message_class end' \
        "$journal") || return 1
    printf 'Failure class: %s\n' "$failure"
    printf 'Configuration recovery: %s\n' \
        "$(jq -r '.recovery.configuration' "$journal")"
    printf 'System recovery provider: %s\n' \
        "$(jq -r '.recovery.system_provider' "$journal")"
    if [[ -f $status_tx/preflight.json && ! -L $status_tx/preflight.json ]]; then
        manual=$(jq -er '
            .manual_intervention |
            select(type == "array" and length <= 8) |
            select(all(.[]; type == "string" and test("^[a-z0-9-]{1,64}$"))) |
            if length > 0 then join(",") else "none" end
        ' "$status_tx/preflight.json" 2>/dev/null) || manual=unavailable
        printf 'Manual intervention: %s\n' "$manual"
    fi
    known_good="$MAINTENANCE_STATE_ROOT/known-good.json"
    if _maintenance_validate_owned_file "$known_good" && \
        jq -e --arg id "${status_tx##*/}" '.transaction_id == $id' \
            "$known_good" >/dev/null 2>&1; then
        printf 'Known good: yes\n'
    else
        printf 'Known good: no\n'
    fi
}

recover_transaction() {
    local id=$1 state status=0

    unset MYHYPR_TRANSACTION_DIR MYHYPR_MAINTENANCE_LOCK_FD
    maintenance_paths_init || return $?
    maintenance_lock_acquire || return $?
    adopt_transaction "$id" || return $?
    status_journal_valid "$TX_DIR/journal.json" || return 1
    state=$(transaction_state "$TX_DIR") || return 1
    case $state in
        recovered)
            success "Transaction $id is already recovered."
            return 0
            ;;
        needs-attention)
            warn "Transaction $id still needs manual attention."
            return 1
            ;;
        committed)
            success "Transaction $id is already committed."
            return 0
            ;;
    esac
    recover_active_transaction 99 || status=$?
    if [[ $status -eq 0 ]]; then
        success "Transaction $id recovered."
    else
        warn "Transaction $id needs manual attention; evidence was retained."
    fi
    return "$status"
}

main() {
    local status

    if ! parse_cli "$@"; then
        status=$?
        ((status != 0)) || status=64
        usage >&2
        return "$status"
    fi
    case $COMMAND in
        plan) run_plan ;;
        apply) run_apply ;;
        status) print_status "$TRANSACTION_ID" ;;
        recover) recover_transaction "$TRANSACTION_ID" ;;
    esac
}

main "$@"
