#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2030,SC2031
# Fixture scripts contain literal variables; fixture globals are reset between subshell cases.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-transaction-test.XXXXXXXX")
REAL_MV=$(command -v mv)

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-transaction-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Maintenance transaction test failed: %s\n' "$*" >&2
    exit 1
}

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"
# shellcheck source=scripts/lib/maintenance-transaction.sh
source "$REPO_ROOT/scripts/lib/maintenance-transaction.sh"

CURRENT_COMMIT=$(printf '1%.0s' {1..40})
CANDIDATE_COMMIT=$(printf '2%.0s' {1..40})

prepare_fixture() {
    local name=$1

    HOME="$TEST_ROOT/$name/home"
    XDG_STATE_HOME="$TEST_ROOT/$name/state"
    XDG_RUNTIME_DIR="$TEST_ROOT/$name/run"
    XDG_CACHE_HOME="$TEST_ROOT/$name/cache"
    export HOME XDG_STATE_HOME XDG_RUNTIME_DIR XDG_CACHE_HOME
    mkdir -p -- "$HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" "$XDG_CACHE_HOME"
    chmod 0700 -- "$HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" "$XDG_CACHE_HOME"
    unset MAINTENANCE_STATE_ROOT MAINTENANCE_RUNTIME_ROOT MAINTENANCE_TX_ROOT
    unset MYHYPR_TRANSACTION_DIR MYHYPR_MAINTENANCE_LOCK_FD
}

release_lock() {
    local fd=${MYHYPR_MAINTENANCE_LOCK_FD:-}

    if [[ $fd =~ ^[0-9]+$ ]]; then
        flock -u "$fd" || true
        eval "exec ${fd}>&-"
    fi
    unset MYHYPR_MAINTENANCE_LOCK_FD MYHYPR_TRANSACTION_DIR
}

if (
    prepare_fixture root-state
    XDG_STATE_HOME=/
    export XDG_STATE_HOME
    maintenance_paths_init
); then
    fail 'the filesystem root was accepted as an XDG state root'
fi

if (
    prepare_fixture traversal-state
    mkdir -p -- "$TEST_ROOT/traversal-state/outside"
    chmod 0700 -- "$TEST_ROOT/traversal-state/outside"
    XDG_STATE_HOME="$TEST_ROOT/traversal-state/state/../outside"
    export XDG_STATE_HOME
    maintenance_paths_init
); then
    fail 'an XDG path containing traversal was accepted'
fi

if (
    prepare_fixture writable-state
    chmod 0770 "$XDG_STATE_HOME"
    maintenance_paths_init
); then
    fail 'a group-writable XDG root was accepted'
fi

if (
    prepare_fixture symlink-state
    mkdir -p -- "$TEST_ROOT/symlink-state/outside"
    chmod 0700 -- "$TEST_ROOT/symlink-state/outside"
    ln -s -- "$TEST_ROOT/symlink-state/outside" "$XDG_STATE_HOME/myhyprlandrice"
    maintenance_paths_init
); then
    fail 'a symlink maintenance state root was accepted'
fi

if (
    prepare_fixture wrong-owner
    mkdir -p -- "$TEST_ROOT/wrong-owner/bin"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        'if [[ ${1:-} == -c && ${2:-} == %u ]]; then' \
        '    printf "%s\n" "$((UID + 1))"' \
        '    exit 0' \
        'fi' \
        'exec /usr/bin/stat "$@"' > "$TEST_ROOT/wrong-owner/bin/stat"
    chmod +x -- "$TEST_ROOT/wrong-owner/bin/stat"
    PATH="$TEST_ROOT/wrong-owner/bin:/usr/bin:/bin" maintenance_paths_init
); then
    fail 'an XDG root owned by a different user was accepted'
fi

prepare_fixture core
maintenance_paths_init || fail 'private maintenance paths could not be initialized'
[[ $(stat -c %a "$MAINTENANCE_STATE_ROOT") == 700 ]] || \
    fail 'maintenance state root is not mode 0700'
[[ $(stat -c %a "$MAINTENANCE_RUNTIME_ROOT") == 700 ]] || \
    fail 'maintenance runtime root is not mode 0700'
[[ $(stat -c %a "$MAINTENANCE_TX_ROOT") == 700 ]] || \
    fail 'transaction root is not mode 0700'

maintenance_lock_acquire || fail 'the first maintenance lock was not acquired'
[[ $(stat -c %a "$MAINTENANCE_RUNTIME_ROOT/maintenance.lock") == 600 ]] || \
    fail 'the maintenance lock file is not mode 0600'

set +e
initializing_output=$(
    HOME="$HOME" XDG_STATE_HOME="$XDG_STATE_HOME" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
        bash -c '
            set -Eeuo pipefail
            source "$1/scripts/lib.sh"
            source "$1/scripts/lib/maintenance-transaction.sh"
            maintenance_paths_init
            maintenance_lock_acquire
        ' _ "$REPO_ROOT" 2>&1
)
initializing_status=$?
set -e
[[ $initializing_status -eq 75 ]] || \
    fail "pre-transaction lock contention returned $initializing_status instead of 75"
[[ $initializing_output == *initializing* ]] || \
    fail 'pre-transaction lock contention omitted the initializing state'
[[ $(find "$MAINTENANCE_TX_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l) -eq 0 ]] || \
    fail 'pre-transaction lock contention created a transaction directory'

maintenance_tx_begin dotfiles desktop "$CURRENT_COMMIT" "$CANDIDATE_COMMIT" || \
    fail 'a valid transaction could not begin'
tx_dir=$MYHYPR_TRANSACTION_DIR
tx_id=${tx_dir##*/}
[[ $tx_id =~ ^txn\.[A-Za-z0-9]{8}$ ]] || fail "invalid transaction ID: $tx_id"
[[ $(stat -c %a "$tx_dir") == 700 ]] || fail 'transaction directory is not mode 0700'
[[ $(stat -c %a "$tx_dir/journal.json") == 600 ]] || \
    fail 'transaction journal is not mode 0600'

jq -e --arg id "$tx_id" --arg current "$CURRENT_COMMIT" \
    --arg candidate "$CANDIDATE_COMMIT" '
    .version == 1 and .id == $id and .operation == "dotfiles" and
    .profile == "desktop" and .state == "planned" and
    .stage == "initializing" and .result == "in-progress" and
    .current_commit == $current and .candidate_commit == $candidate and
    (.created_at | test("^[0-9]{8}T[0-9]{6}Z$")) and
    (.updated_at | test("^[0-9]{8}T[0-9]{6}Z$")) and
    .completed_stages == [] and
    .recovery.configuration == "pending" and
    .recovery.system_provider == "none" and
    .recovery.system_coverage == "none" and
    .failure == null and
    (.artifacts | type == "object") and
    ([.artifacts[] | select(
        startswith("/") or test("(^|/)\\.\\.(/|$)")
    )] | length == 0)
' "$tx_dir/journal.json" >/dev/null || fail 'the version-1 journal schema is invalid'

chmod 0640 "$tx_dir/journal.json"
if maintenance_tx_complete_stage "$tx_dir" unsafe-mode; then
    fail 'a non-private journal mode was accepted'
fi
chmod 0600 "$tx_dir/journal.json"

before_count=$(find "$MAINTENANCE_TX_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l)
set +e
second_output=$(
    HOME="$HOME" XDG_STATE_HOME="$XDG_STATE_HOME" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
        bash -c '
            set -Eeuo pipefail
            source "$1/scripts/lib.sh"
            source "$1/scripts/lib/maintenance-transaction.sh"
            maintenance_paths_init
            maintenance_lock_acquire
            maintenance_tx_begin dotfiles desktop "$2" "$3"
        ' _ "$REPO_ROOT" "$CURRENT_COMMIT" "$CANDIDATE_COMMIT" 2>&1
)
second_status=$?
set -e
[[ $second_status -eq 75 ]] || \
    fail "a competing lock returned $second_status instead of 75"
[[ $second_output == *"$tx_id"* ]] || fail 'the lock warning omitted the bounded active ID'
after_count=$(find "$MAINTENANCE_TX_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l)
[[ $after_count -eq $before_count ]] || fail 'the competing process created a transaction'

if maintenance_tx_transition "$tx_dir" planned applying packages; then
    fail 'an invalid state transition succeeded'
fi
jq -e '.state == "planned" and .stage == "initializing"' \
    "$tx_dir/journal.json" >/dev/null || fail 'an invalid transition changed the journal'

maintenance_tx_transition "$tx_dir" planned preflighted preflight || \
    fail 'the planned-to-preflighted transition failed'
maintenance_tx_complete_stage "$tx_dir" preflight || fail 'a stage could not be completed'
maintenance_tx_complete_stage "$tx_dir" preflight || fail 'stage completion is not idempotent'
jq -e '.state == "preflighted" and .stage == "preflight" and
    .completed_stages == ["preflight"]' "$tx_dir/journal.json" >/dev/null || \
    fail 'state/stage completion was not recorded correctly'

original_digest=$(sha256sum "$tx_dir/journal.json" | cut -d' ' -f1)
mkdir -p -- "$TEST_ROOT/core/failing-bin"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'if [[ ${!#} == */journal.json ]]; then exit 73; fi' \
    'exec "$TRANSACTION_TEST_REAL_MV" "$@"' \
    > "$TEST_ROOT/core/failing-bin/mv"
chmod +x -- "$TEST_ROOT/core/failing-bin/mv"
set +e
PATH="$TEST_ROOT/core/failing-bin:$PATH" TRANSACTION_TEST_REAL_MV="$REAL_MV" \
    maintenance_tx_complete_stage "$tx_dir" interrupted-write
atomic_status=$?
set -e
[[ $atomic_status -ne 0 ]] || fail 'a failed atomic rename reported success'
jq -e . "$tx_dir/journal.json" >/dev/null || fail 'an interrupted write corrupted the journal'
[[ $(sha256sum "$tx_dir/journal.json" | cut -d' ' -f1) == "$original_digest" ]] || \
    fail 'an interrupted write replaced the previous journal'
if find "$tx_dir" -maxdepth 1 -type f -name '.journal.*' -print -quit | rg -q .; then
    fail 'an interrupted atomic write left a temporary journal'
fi

maintenance_tx_set_recovery "$tx_dir" ready snapper \
    '{"root":true,"home":false}' || fail 'valid recovery coverage was rejected'
jq -e '.recovery.configuration == "ready" and
    .recovery.system_provider == "snapper" and
    .recovery.system_coverage.root == true and
    .recovery.system_coverage.home == false' "$tx_dir/journal.json" >/dev/null || \
    fail 'recovery coverage was not recorded as bounded JSON'

before_failure=$(sha256sum "$tx_dir/journal.json" | cut -d' ' -f1)
if maintenance_tx_fail "$tx_dir" preflight not-a-number preflight-failed; then
    fail 'a nonnumeric failure status was accepted'
fi
if maintenance_tx_fail "$tx_dir" preflight 42 'contains spaces'; then
    fail 'an unbounded failure class was accepted'
fi
[[ $(sha256sum "$tx_dir/journal.json" | cut -d' ' -f1) == "$before_failure" ]] || \
    fail 'invalid failure metadata changed the journal'
maintenance_tx_fail "$tx_dir" preflight 42 preflight-failed || \
    fail 'a valid transaction failure was rejected'
jq -e '.state == "failed" and .result == "failed" and
    .failure.stage == "preflight" and .failure.exit_status == 42 and
    (.failure.exit_status | type == "number") and
    .failure.message_class == "preflight-failed"' "$tx_dir/journal.json" >/dev/null || \
    fail 'bounded failure metadata is invalid'

other_dir="$MAINTENANCE_TX_ROOT/txn.ABCDEFGH"
mkdir -m 0700 -- "$other_dir"
jq --arg id txn.ABCDEFGH '.id = $id' "$tx_dir/journal.json" > "$other_dir/journal.json"
chmod 0600 "$other_dir/journal.json"
other_digest=$(sha256sum "$other_dir/journal.json" | cut -d' ' -f1)
if maintenance_tx_complete_stage "$other_dir" cross-transaction; then
    fail 'the active transaction mutated another transaction journal'
fi
[[ $(sha256sum "$other_dir/journal.json" | cut -d' ' -f1) == "$other_digest" ]] || \
    fail 'cross-transaction containment changed another journal'
if maintenance_log_run "$tx_dir" '../escape.log' true; then
    fail 'a transaction-relative log path escaped its directory'
fi

log_key='pass'
log_key+='word'
secret_value='synthetic-private-'
secret_value+='value'
uri_credential='fixture-'
uri_credential+='pass'
uri_value="https://fixture-user:$uri_credential@example.invalid/path"
auth_header='Author'
auth_header+='ization'
log_payload=$(printf '\033[31mcolor\033[0m\n%s=%s\n%s\n%s: Bearer %s\n' \
    "$log_key" "$secret_value" "$uri_value" "$auth_header" "$secret_value")
export log_payload
set +e
maintenance_log_run "$tx_dir" packages.log \
    bash -c 'printf "%s\n" "$log_payload"; exit 42' \
    > "$TEST_ROOT/core/terminal.log"
log_status=$?
set -e
[[ $log_status -eq 42 ]] || fail "private log runner returned $log_status instead of 42"
[[ -f $tx_dir/logs/packages.log ]] || fail 'the filtered package log is missing'
[[ $(stat -c %a "$tx_dir/logs/packages.log") == 600 ]] || \
    fail 'the filtered package log is not mode 0600'
for filtered_path in "$tx_dir/logs/packages.log" "$TEST_ROOT/core/terminal.log"; do
    if rg -Fq "$secret_value" "$filtered_path" || rg -Fq "$uri_credential" "$filtered_path"; then
        fail "private log data was not redacted from $filtered_path"
    fi
    rg -Fq '[REDACTED]' "$filtered_path" || fail "redaction marker missing from $filtered_path"
    if LC_ALL=C rg -q $'\033' "$filtered_path"; then
        fail "ANSI control data remained in $filtered_path"
    fi
done

touch -d '1 minute' "$tx_dir/journal.json" "$tx_dir"
[[ $(maintenance_tx_latest) == "$tx_dir" ]] || \
    fail 'latest transaction selection did not return the validated newest path'
release_lock

prepare_fixture known-good
maintenance_paths_init
maintenance_lock_acquire
maintenance_tx_begin dotfiles desktop "$CURRENT_COMMIT" "$CANDIDATE_COMMIT"
known_tx=$MYHYPR_TRANSACTION_DIR
maintenance_tx_transition "$known_tx" planned preflighted preflight
maintenance_tx_transition "$known_tx" preflighted checkpointed checkpoint
maintenance_tx_transition "$known_tx" checkpointed applying apply
maintenance_tx_transition "$known_tx" applying verifying postflight
maintenance_tx_complete_stage "$known_tx" postflight
printf '%s\n' '{"required_passed":true}' > "$known_tx/postflight.json"
chmod 0600 "$known_tx/postflight.json"
printf '%s\n' \
    '{"version":1,"transaction_id":"txn.PREV0001","operation":"dotfiles","commit":"previous","timestamp":"20260101T000000Z"}' \
    > "$MAINTENANCE_STATE_ROOT/known-good.json"
chmod 0600 "$MAINTENANCE_STATE_ROOT/known-good.json"
previous_known_good=$(sha256sum "$MAINTENANCE_STATE_ROOT/known-good.json" | cut -d' ' -f1)
maintenance_known_good_prepare "$known_tx" || fail 'known-good pending record was not prepared'
if maintenance_known_good_promote "$known_tx"; then
    fail 'known-good was promoted before the transaction committed'
fi
[[ $(sha256sum "$MAINTENANCE_STATE_ROOT/known-good.json" | cut -d' ' -f1) == \
    "$previous_known_good" ]] || fail 'pre-commit promotion replaced known-good'
maintenance_tx_transition "$known_tx" verifying committed known-good
printf '%064d  known-good.pending.json\n' 0 \
    > "$MAINTENANCE_STATE_ROOT/known-good.pending.sha256"
if maintenance_known_good_promote "$known_tx"; then
    fail 'known-good promotion accepted a bad pending digest'
fi
[[ $(sha256sum "$MAINTENANCE_STATE_ROOT/known-good.json" | cut -d' ' -f1) == \
    "$previous_known_good" ]] || fail 'a bad pending digest replaced known-good'
pending_digest=$(sha256sum "$MAINTENANCE_STATE_ROOT/known-good.pending.json" | cut -d' ' -f1)
printf '%s  known-good.pending.json\n' "$pending_digest" \
    > "$MAINTENANCE_STATE_ROOT/known-good.pending.sha256"
chmod 0600 "$MAINTENANCE_STATE_ROOT/known-good.pending.sha256"
maintenance_known_good_promote "$known_tx" || \
    fail 'a committed, digest-verified known-good record was not promoted'
jq -e --arg id "${known_tx##*/}" --arg commit "$CANDIDATE_COMMIT" '
    .version == 1 and .transaction_id == $id and .operation == "dotfiles" and
    .commit == $commit and (.timestamp | test("^[0-9]{8}T[0-9]{6}Z$")) and
    (keys | sort) == (["commit","operation","timestamp","transaction_id","version"] | sort)
' "$MAINTENANCE_STATE_ROOT/known-good.json" >/dev/null || \
    fail 'the promoted known-good pointer is not bounded'
[[ ! -e $MAINTENANCE_STATE_ROOT/known-good.pending.json ]] || \
    fail 'promoted pending known-good JSON was not cleaned up'
[[ ! -e $MAINTENANCE_STATE_ROOT/known-good.pending.sha256 ]] || \
    fail 'promoted pending known-good digest was not cleaned up'
release_lock

prepare_fixture retention
maintenance_paths_init

make_retention_transaction() {
    local id=$1 state=$2 age=$3 result=success
    local dir="$MAINTENANCE_TX_ROOT/$id"

    case $state in
        failed|needs-attention) result=$state ;;
        planned) result=in-progress ;;
    esac
    mkdir -m 0700 -- "$dir"
    jq -n --arg id "$id" --arg state "$state" --arg result "$result" '
        {
            version: 1, id: $id, operation: "dotfiles", profile: "desktop",
            state: $state, stage: "fixture", result: $result,
            created_at: "20260101T000000Z", updated_at: "20260101T000000Z",
            current_commit: "", candidate_commit: "", completed_stages: [],
            recovery: {configuration:"pending",system_provider:"none",system_coverage:"none"},
            failure: null, artifacts: {package_log:"logs/packages.log"}
        }
    ' > "$dir/journal.json"
    chmod 0600 "$dir/journal.json"
    mkdir -m 0700 -- "$dir/logs"
    printf 'filtered fixture\n' > "$dir/logs/packages.log"
    chmod 0600 "$dir/logs/packages.log"
    touch -d "$age" "$dir/journal.json" "$dir/logs/packages.log" "$dir/logs" "$dir"
}

for number in {1..12}; do
    printf -v retention_id 'txn.%08d' "$number"
    make_retention_transaction "$retention_id" committed "$((12 - number)) minutes ago"
done
make_retention_transaction txn.oldgood1 committed '31 days ago'
make_retention_transaction txn.failed01 failed '60 days ago'
make_retention_transaction txn.attent01 needs-attention '60 days ago'
make_retention_transaction txn.planned1 planned '60 days ago'

latest_retention_tx=$(maintenance_tx_latest)
[[ ${latest_retention_tx##*/} == txn.00000012 ]] || \
    fail 'latest transaction did not use validated modification time'
maintenance_retention_prune || fail 'transaction retention failed'
successful_count=$(find "$MAINTENANCE_TX_ROOT" -mindepth 1 -maxdepth 1 -type d \
    -name 'txn.000000*' | wc -l)
[[ $successful_count -eq 10 ]] || \
    fail "retention kept $successful_count recent successes instead of 10"
[[ ! -e $MAINTENANCE_TX_ROOT/txn.00000001 ]] || fail 'the oldest excess success was retained'
[[ ! -e $MAINTENANCE_TX_ROOT/txn.00000002 ]] || fail 'the second excess success was retained'
[[ ! -e $MAINTENANCE_TX_ROOT/txn.oldgood1 ]] || fail 'an expired successful transaction was retained'
[[ -d $MAINTENANCE_TX_ROOT/txn.failed01 ]] || fail 'failed evidence was pruned'
[[ -d $MAINTENANCE_TX_ROOT/txn.attent01 ]] || fail 'needs-attention evidence was pruned'
[[ -d $MAINTENANCE_TX_ROOT/txn.planned1 ]] || fail 'interrupted/nonterminal evidence was pruned'

printf 'Maintenance transactions are private, atomic, bounded, and recoverable.\n'
