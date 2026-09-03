#!/usr/bin/env bash

# Bounded, read-only maintenance status views shared by maintenance.sh and
# doctor.sh. This library is sourced after maintenance-transaction.sh.
# shellcheck disable=SC2016  # Single-quoted jq programs must remain literal.

maintenance_status_journal_valid() {
    local journal=${1:-}

    _maintenance_validate_owned_file "$journal" || return 1
    jq -e '
        def safe_class:
            type == "string" and test("^[a-z0-9-]{1,64}$");
        def commit:
            type == "string" and (. == "" or test("^[0-9a-f]{40}$"));
        def timestamp:
            type == "string" and test("^[0-9]{8}T[0-9]{6}Z$");
        def coverage:
            if type == "string" then . == "none"
            else
                type == "object" and .version == 1 and
                (.provider == "none" or .provider == "snapper" or
                    .provider == "timeshift") and
                (.reason | safe_class) and
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
            end;
        .version == 1 and
        (.id | type == "string" and test("^txn\\.[A-Za-z0-9]{8}$")) and
        (.operation == "dotfiles" or .operation == "system") and
        (.profile == "core" or .profile == "desktop" or .profile == "full") and
        (.state == "planned" or .state == "preflighted" or
            .state == "checkpointed" or .state == "applying" or
            .state == "verifying" or .state == "committed" or
            .state == "failed" or .state == "recovering" or
            .state == "recovered" or .state == "needs-attention") and
        (.stage | safe_class) and
        (.result == "in-progress" or .result == "planned" or
            .result == "success" or .result == "failed" or
            .result == "recovered" or .result == "needs-attention") and
        (.created_at | timestamp) and (.updated_at | timestamp) and
        (.current_commit | commit) and (.candidate_commit | commit) and
        (.completed_stages | type == "array" and length <= 32) and
        all(.completed_stages[]; safe_class) and
        (.completed_stages | length) == (.completed_stages | unique | length) and
        (.recovery | type == "object") and
        (.recovery | keys | sort) ==
            (["configuration","system_coverage","system_provider"] | sort) and
        (.recovery.configuration | safe_class) and
        (.recovery.system_provider == "none" or
            .recovery.system_provider == "snapper" or
            .recovery.system_provider == "timeshift") and
        (.recovery.system_coverage | coverage) and
        (
            (.recovery.system_coverage | type) == "string" or
            .recovery.system_coverage.provider == .recovery.system_provider
        ) and
        (
            .failure == null or
            (
                (.failure | keys | sort) ==
                    (["exit_status","message_class","stage"] | sort) and
                (.failure.stage | safe_class) and
                (.failure.exit_status | type == "number" and . >= 1 and . <= 255) and
                (.failure.message_class | safe_class)
            )
        ) and
        .artifacts == {
            checkpoint: "checkpoint/checkpoint.json",
            package_log: "logs/packages.log",
            git: "git.json",
            snapshot: "snapshot.json",
            postflight: "postflight.json"
        } and
        (keys | sort) == ([
            "artifacts","candidate_commit","completed_stages","created_at",
            "current_commit","failure","id","operation","profile","recovery",
            "result","stage","state","updated_at","version"
        ] | sort)
    ' "$journal" >/dev/null 2>&1
}

maintenance_status_postflight_summary() {
    local tx_dir=${1:-} postflight journal id operation profile state

    postflight="$tx_dir/postflight.json"
    if [[ ! -e $postflight && ! -L $postflight ]]; then
        printf 'null\n'
        return 0
    fi
    _maintenance_validate_owned_file "$postflight" || return 1
    journal="$tx_dir/journal.json"
    id=${tx_dir##*/}
    operation=$(jq -er '.operation | select(type == "string")' "$journal") || return 1
    profile=$(jq -er '.profile | select(type == "string")' "$journal") || return 1
    state=$(jq -er '.state | select(type == "string")' "$journal") || return 1
    if [[ $state == verifying || $state == failed || $state == recovering || \
        $state == recovered || $state == needs-attention ]] && \
        jq -e --arg id "$id" --arg operation "$operation" --arg profile "$profile" '
            .version == 1 and .transaction_id == $id and
            .operation == $operation and .profile == $profile and
            .result == "in-progress" and .required_passed == false and
            (keys | sort) == ([
                "operation","profile","required_passed","result",
                "transaction_id","version"
            ] | sort)
        ' "$postflight" >/dev/null 2>&1; then
        jq -cn '
            {
                result: "in-progress",
                required_passed: false,
                needs_attention: false,
                failed_checks: [],
                recommendations: []
            }
        '
        return 0
    fi
    jq -e --arg id "$id" --arg operation "$operation" --arg profile "$profile" '
        def safe_name:
            type == "string" and test("^[a-z0-9-]{1,64}$");
        .version == 1 and .transaction_id == $id and
        .operation == $operation and .profile == $profile and
        (.live_session | type == "boolean") and
        (.created_at | type == "string" and test("^[0-9]{8}T[0-9]{6}Z$")) and
        (.result == "passed" or .result == "failed" or
            .result == "needs-attention") and
        (.required_passed | type == "boolean") and
        (.needs_attention | type == "boolean") and
        (.checks | type == "array" and length <= 128) and
        all(.checks[];
            (keys | sort) ==
                (["class","exit_status","name","required","status"] | sort) and
            (.name | safe_name) and (.required | type == "boolean") and
            (.class == "health" or .class == "optional" or .class == "package") and
            (.status == "passed" or .status == "failed" or
                .status == "unavailable" or .status == "needs-attention") and
            (.exit_status | type == "number" and . >= 0 and . <= 255)
        ) and
        (.recommendations | type == "array" and length <= 32) and
        all(.recommendations[];
            (keys | sort) == (["capped","class","count"] | sort) and
            (.class == "pacnew-findings" or .class == "pacsave-findings" or
                .class == "outdated-processes" or .class == "aur-rebuilds" or
                .class == "reboot-sensitive") and
            (.count | type == "number" and . >= 1 and . <= 1000) and
            (.capped | type == "boolean")
        ) and
        (keys | sort) == ([
            "checks","created_at","live_session","needs_attention","operation",
            "profile","recommendations","required_passed","result",
            "transaction_id","version"
        ] | sort)
    ' "$postflight" >/dev/null 2>&1 || return 1
    jq -c '
        {
            result,
            required_passed,
            needs_attention,
            failed_checks: ([
                .checks[] |
                select(.status == "failed" or .status == "needs-attention") |
                .name
            ] | unique),
            recommendations
        }
    ' "$postflight"
}

maintenance_status_known_good() {
    local tx_dir=${1:-} known_good id operation commit

    known_good="$MAINTENANCE_STATE_ROOT/known-good.json"
    if [[ ! -e $known_good && ! -L $known_good ]]; then
        printf 'false\n'
        return 0
    fi
    _maintenance_validate_owned_file "$known_good" || return 1
    jq -e '
        .version == 1 and
        (.transaction_id | type == "string" and test("^txn\\.[A-Za-z0-9]{8}$")) and
        (.operation == "dotfiles" or .operation == "system") and
        (.commit | type == "string" and test("^[0-9a-f]{40}$")) and
        (.timestamp | type == "string" and test("^[0-9]{8}T[0-9]{6}Z$")) and
        (keys | sort) ==
            (["commit","operation","timestamp","transaction_id","version"] | sort)
    ' "$known_good" >/dev/null 2>&1 || return 1
    id=${tx_dir##*/}
    operation=$(jq -er '.operation' "$tx_dir/journal.json") || return 1
    commit=$(jq -er '
        if .candidate_commit != "" then .candidate_commit else .current_commit end
    ' "$tx_dir/journal.json") || return 1
    if jq -e --arg id "$id" --arg operation "$operation" --arg commit "$commit" '
        .transaction_id == $id and .operation == $operation and .commit == $commit
    ' "$known_good" >/dev/null 2>&1; then
        printf 'true\n'
    else
        printf 'false\n'
    fi
}

maintenance_status_transaction_json() {
    local requested=${1:-} tx_dir postflight known_good

    _maintenance_tx_validate "$requested" || return 1
    tx_dir=$_MAINTENANCE_VALIDATED_TX_DIR
    maintenance_status_journal_valid "$tx_dir/journal.json" || return 1
    postflight=$(maintenance_status_postflight_summary "$tx_dir") || return 1
    known_good=$(maintenance_status_known_good "$tx_dir") || return 1
    jq -n --slurpfile journal "$tx_dir/journal.json" --arg tx_dir "$tx_dir" \
        --argjson postflight "$postflight" --argjson known_good "$known_good" '
        $journal[0] as $entry |
        {
            version: $entry.version,
            id: $entry.id,
            operation: $entry.operation,
            profile: $entry.profile,
            state: $entry.state,
            stage: $entry.stage,
            result: $entry.result,
            created_at: $entry.created_at,
            updated_at: $entry.updated_at,
            current_commit: $entry.current_commit,
            candidate_commit: $entry.candidate_commit,
            recovery: $entry.recovery,
            failure: $entry.failure,
            transaction_directory: $tx_dir,
            postflight: $postflight,
            known_good: $known_good
        }
    '
}

maintenance_status_store_valid() {
    local candidate id summary

    [[ -n ${MAINTENANCE_TX_ROOT:-} ]] || return 1
    while IFS= read -r -d '' candidate; do
        id=${candidate##*/}
        _maintenance_safe_transaction_id "$id" || return 1
        _maintenance_tx_validate "$candidate" || return 1
        maintenance_status_journal_valid \
            "$_MAINTENANCE_VALIDATED_TX_DIR/journal.json" || return 1
        summary=$(maintenance_status_postflight_summary \
            "$_MAINTENANCE_VALIDATED_TX_DIR") || return 1
        [[ -n $summary ]] || return 1
    done < <(find "$MAINTENANCE_TX_ROOT" -mindepth 1 -maxdepth 1 -print0)
}

maintenance_status_resolve() {
    local requested=${1:-}

    if [[ -n $requested ]]; then
        _maintenance_safe_transaction_id "$requested" || return 64
        _maintenance_tx_validate "$MAINTENANCE_TX_ROOT/$requested" || return 1
        maintenance_status_journal_valid \
            "$_MAINTENANCE_VALIDATED_TX_DIR/journal.json" || return 1
        MAINTENANCE_STATUS_TX_DIR=$_MAINTENANCE_VALIDATED_TX_DIR
        return 0
    fi
    maintenance_status_store_valid || return 74
    if ! MAINTENANCE_STATUS_TX_DIR=$(maintenance_tx_latest); then
        MAINTENANCE_STATUS_TX_DIR=''
        return 3
    fi
    _maintenance_tx_validate "$MAINTENANCE_STATUS_TX_DIR" || return 1
    MAINTENANCE_STATUS_TX_DIR=$_MAINTENANCE_VALIDATED_TX_DIR
    maintenance_status_journal_valid \
        "$MAINTENANCE_STATUS_TX_DIR/journal.json"
}
