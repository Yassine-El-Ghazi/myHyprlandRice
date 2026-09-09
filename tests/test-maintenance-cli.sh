#!/usr/bin/env bash
# shellcheck disable=SC2016  # Fixture scripts intentionally contain literal variables.
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-maintenance-cli.XXXXXXXX")
FIXTURE_REPO="$TEST_ROOT/repository"
RUN_HOME="$TEST_ROOT/home"
RUN_STATE="$TEST_ROOT/state"
RUN_RUNTIME="$TEST_ROOT/runtime"
COMMAND_LOG="$TEST_ROOT/commands.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-maintenance-cli.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Maintenance CLI test failed: %s\n' "$*" >&2
    exit 1
}

mkdir -p -- "$FIXTURE_REPO/scripts/lib" "$RUN_HOME" "$RUN_STATE" "$RUN_RUNTIME"
chmod 0700 -- "$RUN_HOME" "$RUN_STATE" "$RUN_RUNTIME"
cp -- "$PROJECT_ROOT/scripts/maintenance.sh" "$FIXTURE_REPO/scripts/maintenance.sh"
cp -- "$PROJECT_ROOT/scripts/lib.sh" "$FIXTURE_REPO/scripts/lib.sh"
cp -- "$PROJECT_ROOT/scripts/lib/maintenance-transaction.sh" \
    "$FIXTURE_REPO/scripts/lib/maintenance-transaction.sh"
if [[ -f $PROJECT_ROOT/scripts/lib/maintenance-status.sh ]]; then
    cp -- "$PROJECT_ROOT/scripts/lib/maintenance-status.sh" \
        "$FIXTURE_REPO/scripts/lib/maintenance-status.sh"
fi

write_fake_library() {
    local file=$1

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        '[[ ${_MYHYPR_CLI_FIXTURE_LOADED:-0} == 1 ]] && return 0' \
        '_MYHYPR_CLI_FIXTURE_LOADED=1' \
        '_cli_log() { printf "%s\n" "$1" >> "$CLI_TEST_COMMAND_LOG"; }' \
        'recovery_capture_owned_state() {' \
        '  local tx_dir=$1' \
        '  _cli_log capture-owned-state' \
        '  printf "fixture-owned-state\n" > "$tx_dir/owned-after.tsv"' \
        '  chmod 0600 -- "$tx_dir/owned-after.tsv"' \
        '}' \
        'recovery_checkpoint_restore() {' \
        '  local tx_dir=$1' \
        '  _cli_log configuration-restore' \
        '  if [[ ${CLI_RECOVERY_COLLISION:-0} == 1 ]]; then' \
        '    printf ".config/hypr/local.lua\\tcontent-changed\n" > "$tx_dir/needs-attention.txt"' \
        '    chmod 0600 -- "$tx_dir/needs-attention.txt"' \
        '    maintenance_journal_update "$tx_dir" '\''.recovery.configuration = "needs-attention"'\''' \
        '    return 1' \
        '  fi' \
        '  rm -f -- "$tx_dir/needs-attention.txt"' \
        '  maintenance_journal_update "$tx_dir" '\''.recovery.configuration = "recovered"'\''' \
        '}' \
        'snapshot_guidance() {' \
        '  _cli_log snapshot-guidance' \
        '  printf "Snapshot provider: %s\n" "$2"' \
        '  printf "No filesystem restore is run automatically.\n"' \
        '}' \
        'maintenance_git_restore_previous() { _cli_log git-restore; }' \
        'maintenance_git_cleanup() { _cli_log git-cleanup; }' \
        > "$file"
}

for library in maintenance-recovery maintenance-snapshot maintenance-git \
    maintenance-postflight maintenance-preflight; do
    write_fake_library "$FIXTURE_REPO/scripts/lib/$library.sh"
done

git -C "$FIXTURE_REPO" init -q -b main
git -C "$FIXTURE_REPO" config user.name 'Maintenance CLI Fixture'
git -C "$FIXTURE_REPO" config user.email 'maintenance-cli@example.invalid'
git -C "$FIXTURE_REPO" add .
git -C "$FIXTURE_REPO" commit -q -m fixture
CURRENT_COMMIT=$(git -C "$FIXTURE_REPO" rev-parse HEAD)
STATE_ROOT="$RUN_STATE/myhyprlandrice"
TX_ROOT="$STATE_ROOT/transactions"
mkdir -p -- "$TX_ROOT"
chmod 0700 -- "$STATE_ROOT" "$TX_ROOT"
: > "$COMMAND_LOG"
export CLI_TEST_COMMAND_LOG="$COMMAND_LOG"

write_transaction() {
    local id=$1 state=$2 provider=${3:-none}
    local tx_dir="$TX_ROOT/$id"
    local result stage recovery failure

    case $state in
        planned|preflighted|checkpointed|applying|verifying)
            result=in-progress
            stage=packages
            recovery=pending
            failure=null
            ;;
        committed)
            result=success
            stage=known-good
            recovery=ready
            failure=null
            ;;
        failed)
            result=failed
            stage=packages
            recovery=ready
            failure='{"stage":"packages","exit_status":42,"message_class":"packages-failed"}'
            ;;
        recovered)
            result=recovered
            stage=recovery
            recovery=recovered
            failure='{"stage":"packages","exit_status":42,"message_class":"packages-failed"}'
            ;;
        needs-attention)
            result=needs-attention
            stage=recovery
            recovery=needs-attention
            failure='{"stage":"packages","exit_status":42,"message_class":"packages-failed"}'
            ;;
        *) fail "invalid transaction state: $state" ;;
    esac

    mkdir -p -- "$tx_dir/logs"
    chmod 0700 -- "$tx_dir" "$tx_dir/logs"
    jq -n --arg id "$id" --arg state "$state" --arg result "$result" \
        --arg stage "$stage" --arg recovery "$recovery" --arg provider "$provider" \
        --arg commit "$CURRENT_COMMIT" --argjson failure "$failure" '
        {
            version: 1,
            id: $id,
            operation: "system",
            profile: "desktop",
            state: $state,
            stage: $stage,
            result: $result,
            created_at: "20260903T000000Z",
            updated_at: "20260903T000100Z",
            current_commit: $commit,
            candidate_commit: "",
            completed_stages: [],
            recovery: {
                configuration: $recovery,
                system_provider: $provider,
                system_coverage: (
                    if $provider == "none" then "none"
                    else {
                        version: 1,
                        provider: $provider,
                        coverage: {root: true, package_db: true, home: false, boot: true},
                        system_restorable: true,
                        reason: "partial-coverage"
                    } end
                )
            },
            failure: $failure,
            artifacts: {
                checkpoint: "checkpoint/checkpoint.json",
                package_log: "logs/packages.log",
                git: "git.json",
                snapshot: "snapshot.json",
                postflight: "postflight.json"
            }
        }
    ' > "$tx_dir/journal.json"
    jq -n --arg id "$id" '
        {
            version: 1,
            transaction_id: $id,
            operation: "system",
            profile: "desktop",
            live_session: false,
            created_at: "20260903T000200Z",
            result: "passed",
            required_passed: true,
            needs_attention: false,
            checks: [{
                name: "fixture-optional",
                required: false,
                class: "optional",
                status: "failed",
                exit_status: 7
            }],
            recommendations: [{class: "pacnew-findings", count: 1, capped: false}]
        }
    ' > "$tx_dir/postflight.json"
    printf 'private-package-output-must-not-leak\n' > "$tx_dir/logs/packages.log"
    chmod 0600 -- "$tx_dir/journal.json" "$tx_dir/postflight.json" \
        "$tx_dir/logs/packages.log"
}

write_known_good() {
    local id=$1

    jq -n --arg id "$id" --arg commit "$CURRENT_COMMIT" '
        {
            version: 1,
            transaction_id: $id,
            operation: "system",
            commit: $commit,
            timestamp: "20260903T000300Z"
        }
    ' > "$STATE_ROOT/known-good.json"
    chmod 0600 -- "$STATE_ROOT/known-good.json"
}

run_cli() {
    local expected=$1 actual
    shift

    set +e
    CLI_OUTPUT=$(HOME="$RUN_HOME" XDG_STATE_HOME="$RUN_STATE" \
        XDG_RUNTIME_DIR="$RUN_RUNTIME" "$FIXTURE_REPO/scripts/maintenance.sh" \
        "$@" 2>&1)
    actual=$?
    set -e
    [[ $actual -eq $expected ]] || {
        printf '%s\n' "$CLI_OUTPUT" >&2
        fail "maintenance $* returned $actual instead of $expected"
    }
}

write_transaction txn.A0000001 recovered snapper
write_transaction txn.B0000002 committed none
write_known_good txn.B0000002
touch -d '2026-09-03 00:00:01 UTC' "$TX_ROOT/txn.A0000001"
touch -d '2026-09-03 00:00:02 UTC' "$TX_ROOT/txn.B0000002"

run_cli 0 status
[[ $CLI_OUTPUT == *'Transaction: txn.B0000002'* ]] || fail 'status did not select latest'
[[ $CLI_OUTPUT == *"Transaction directory: $TX_ROOT/txn.B0000002"* ]] || \
    fail 'human status omitted the local evidence directory'
[[ $CLI_OUTPUT == *'Failed postflight checks: fixture-optional'* ]] || \
    fail 'human status omitted bounded postflight failures'
[[ $CLI_OUTPUT != *private-package-output-must-not-leak* ]] || \
    fail 'human status leaked a private package log'

run_cli 0 status --json
STATUS_JSON=$CLI_OUTPUT
jq -e --arg tx "$TX_ROOT/txn.B0000002" '
    .version == 1 and .id == "txn.B0000002" and .state == "committed" and
    .transaction_directory == $tx and .known_good == true and
    .postflight.failed_checks == ["fixture-optional"] and
    .postflight.recommendations == [{class:"pacnew-findings",count:1,capped:false}] and
    (has("artifacts") | not) and (has("completed_stages") | not)
' <<< "$STATUS_JSON" >/dev/null || fail 'JSON status is missing or unbounded'
[[ $STATUS_JSON != *private-package-output-must-not-leak* ]] || \
    fail 'JSON status leaked a private package log'

run_cli 0 status txn.A0000001 --json
jq -e '.id == "txn.A0000001" and .state == "recovered"' \
    <<< "$CLI_OUTPUT" >/dev/null || fail 'explicit JSON status selected the wrong ID'
run_cli 64 status ../escape
run_cli 64 status --json --json
ln -s -- "$TX_ROOT/txn.A0000001" "$TX_ROOT/txn.H0000008"
run_cli 1 status txn.H0000008
rm -- "$TX_ROOT/txn.H0000008"

write_transaction txn.G0000007 verifying none
jq -n '
    {
        version: 1,
        transaction_id: "txn.G0000007",
        operation: "system",
        profile: "desktop",
        result: "in-progress",
        required_passed: false
    }
' > "$TX_ROOT/txn.G0000007/postflight.json"
chmod 0600 -- "$TX_ROOT/txn.G0000007/postflight.json"
run_cli 0 status txn.G0000007 --json
jq -e '
    .state == "verifying" and .postflight == {
        result: "in-progress",
        required_passed: false,
        needs_attention: false,
        failed_checks: [],
        recommendations: []
    }
' <<< "$CLI_OUTPUT" >/dev/null || \
    fail 'bounded status rejected an active in-progress postflight record'
touch -d '2035-09-03 00:00:07 UTC' "$TX_ROOT/txn.G0000007"
set +e
HOME="$RUN_HOME" XDG_STATE_HOME="$RUN_STATE" XDG_RUNTIME_DIR="$RUN_RUNTIME" \
    "$PROJECT_ROOT/scripts/doctor.sh" --profile core --quick \
    > "$TEST_ROOT/doctor-verifying.log" 2>&1
set -e
rg -q 'WARN.*Latest maintenance transaction.*verifying' \
    "$TEST_ROOT/doctor-verifying.log" || \
    fail 'doctor rejected a valid in-progress postflight record'
! rg -q 'Maintenance transaction evidence is corrupt or unsafe' \
    "$TEST_ROOT/doctor-verifying.log" || \
    fail 'doctor mislabeled in-progress postflight evidence as corrupt'

before=$(sha256sum "$TX_ROOT/txn.A0000001/journal.json" | cut -d' ' -f1)
run_cli 0 recover txn.A0000001
after=$(sha256sum "$TX_ROOT/txn.A0000001/journal.json" | cut -d' ' -f1)
[[ $before == "$after" ]] || fail 'idempotent recovered state was mutated'
[[ $CLI_OUTPUT == *'Snapshot provider: snapper'* ]] || \
    fail 'idempotent recovery omitted snapshot guidance'

run_cli 2 recover txn.B0000002
[[ $CLI_OUTPUT == *'already committed'* ]] || fail 'committed recovery was not rejected'

write_transaction txn.C0000003 applying snapper
mkdir -p -- "$TX_ROOT/txn.C0000003/checkpoint"
chmod 0700 -- "$TX_ROOT/txn.C0000003/checkpoint"
run_cli 0 status txn.C0000003
LOCK_FILE="$RUN_RUNTIME/myhypr/maintenance.lock"
exec {lock_fd}>>"$LOCK_FILE"
flock -n "$lock_fd" || fail 'could not hold the fixture maintenance lock'
printf 'txn.C0000003\n' > "$LOCK_FILE"
chmod 0600 -- "$LOCK_FILE"
before=$(sha256sum "$TX_ROOT/txn.C0000003/journal.json" | cut -d' ' -f1)
run_cli 75 recover txn.C0000003
after=$(sha256sum "$TX_ROOT/txn.C0000003/journal.json" | cut -d' ' -f1)
[[ $before == "$after" ]] || fail 'active transaction changed while its lock was held'
exec {lock_fd}>&-
run_cli 0 recover txn.C0000003
jq -e '.state == "recovered" and .result == "recovered"' \
    "$TX_ROOT/txn.C0000003/journal.json" >/dev/null || \
    fail 'stale nonterminal transaction was not recovered after lock proof'
[[ $CLI_OUTPUT == *'Snapshot provider: snapper'* ]] || \
    fail 'stale recovery omitted snapshot guidance'

write_transaction txn.D0000004 failed none
mkdir -p -- "$TX_ROOT/txn.D0000004/checkpoint"
chmod 0700 -- "$TX_ROOT/txn.D0000004/checkpoint"
run_cli 0 recover txn.D0000004
jq -e '.state == "recovered" and .recovery.configuration == "recovered"' \
    "$TX_ROOT/txn.D0000004/journal.json" >/dev/null || \
    fail 'failed transaction did not restore universal configuration'

write_transaction txn.E0000005 failed snapper
mkdir -p -- "$TX_ROOT/txn.E0000005/checkpoint"
chmod 0700 -- "$TX_ROOT/txn.E0000005/checkpoint"
export CLI_RECOVERY_COLLISION=1
run_cli 1 recover txn.E0000005
unset CLI_RECOVERY_COLLISION
jq -e '.state == "needs-attention"' \
    "$TX_ROOT/txn.E0000005/journal.json" >/dev/null || \
    fail 'recovery collision was not retained as needs-attention'
[[ $CLI_OUTPUT == *"$TX_ROOT/txn.E0000005/needs-attention.txt"* ]] || \
    fail 'collision output omitted the exact local evidence path'
run_cli 0 recover txn.E0000005
jq -e '.state == "recovered"' "$TX_ROOT/txn.E0000005/journal.json" \
    >/dev/null || fail 'resolved collision could not be retried'
! rg -q 'snapshot-(restore|rollback)|timeshift --restore|snapper .* undochange' \
    "$COMMAND_LOG" || fail 'recovery executed an automatic snapshot restore'

MYHYPR_FIXTURE="$TEST_ROOT/myhyprctl"
mkdir -p -- "$MYHYPR_FIXTURE/dotfiles/.config/myhypr/bin" "$MYHYPR_FIXTURE/scripts"
cp -- "$PROJECT_ROOT/dotfiles/.config/myhypr/bin/myhyprctl" \
    "$MYHYPR_FIXTURE/dotfiles/.config/myhypr/bin/myhyprctl"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "<%s>" "$@"' \
    'printf "\n"' \
    > "$MYHYPR_FIXTURE/scripts/maintenance.sh"
chmod 0755 -- "$MYHYPR_FIXTURE/dotfiles/.config/myhypr/bin/myhyprctl" \
    "$MYHYPR_FIXTURE/scripts/maintenance.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "simple-system\\n"' \
    > "$MYHYPR_FIXTURE/scripts/update-system.sh"
chmod +x -- "$MYHYPR_FIXTURE/scripts/update-system.sh"

route() {
    HOME="$RUN_HOME" "$MYHYPR_FIXTURE/dotfiles/.config/myhypr/bin/myhyprctl" "$@"
}

[[ $(route update) == '<apply><dotfiles><--profile><desktop>' ]] || \
    fail 'myhyprctl update route differs'
[[ $(route update-system) == 'simple-system' ]] || \
    fail 'myhyprctl update-system route differs'
[[ $(route update-plan) == '<plan><dotfiles><--profile><desktop>' ]] || \
    fail 'myhyprctl update-plan route differs'
[[ $(route update-status) == '<status>' ]] || fail 'myhyprctl status route differs'
[[ $(route update-status txn.A0000001) == '<status><txn.A0000001>' ]] || \
    fail 'myhyprctl explicit status route differs'
[[ $(route recover txn.A0000001) == '<recover><txn.A0000001>' ]] || \
    fail 'myhyprctl recovery route differs'
if route recover >/dev/null 2>&1; then
    fail 'myhyprctl accepted recovery without a transaction ID'
fi

write_transaction txn.F0000006 failed none
touch -d '2036-09-03 00:00:06 UTC' "$TX_ROOT/txn.F0000006"
run_cli 0 status --json
jq -e '.id == "txn.F0000006" and .state == "failed"' <<< "$CLI_OUTPUT" \
    >/dev/null || fail 'latest failed transaction is not valid status evidence'
set +e
HOME="$RUN_HOME" XDG_STATE_HOME="$RUN_STATE" XDG_RUNTIME_DIR="$RUN_RUNTIME" \
    "$PROJECT_ROOT/scripts/doctor.sh" --profile core --quick \
    > "$TEST_ROOT/doctor-failed.log" 2>&1
set -e
if ! rg -q 'WARN.*Latest maintenance transaction.*failed' \
    "$TEST_ROOT/doctor-failed.log"; then
    sed -n '1,220p' "$TEST_ROOT/doctor-failed.log" >&2
    fail 'doctor omitted failed maintenance warning'
fi

write_transaction txn.F0000006 committed none
write_known_good txn.F0000006
set +e
HOME="$RUN_HOME" XDG_STATE_HOME="$RUN_STATE" XDG_RUNTIME_DIR="$RUN_RUNTIME" \
    "$PROJECT_ROOT/scripts/doctor.sh" --profile core --quick \
    > "$TEST_ROOT/doctor-committed.log" 2>&1
set -e
if ! rg -q 'OK.*Latest maintenance transaction.*committed known-good' \
    "$TEST_ROOT/doctor-committed.log"; then
    sed -n '1,220p' "$TEST_ROOT/doctor-committed.log" >&2
    fail 'doctor omitted committed known-good status'
fi

printf '{broken\n' > "$TX_ROOT/txn.F0000006/journal.json"
set +e
HOME="$RUN_HOME" XDG_STATE_HOME="$RUN_STATE" XDG_RUNTIME_DIR="$RUN_RUNTIME" \
    "$PROJECT_ROOT/scripts/doctor.sh" --profile core --quick \
    > "$TEST_ROOT/doctor-corrupt.log" 2>&1
set -e
if ! rg -q 'FAIL.*Maintenance transaction evidence is corrupt or unsafe' \
    "$TEST_ROOT/doctor-corrupt.log"; then
    sed -n '1,220p' "$TEST_ROOT/doctor-corrupt.log" >&2
    fail 'doctor accepted corrupt maintenance evidence'
fi

for target in update-plan update update-system status; do
    rg -q "^$target:" "$PROJECT_ROOT/Makefile" || fail "Makefile is missing $target"
done
rg -q 'test-maintenance-cli\.sh' "$PROJECT_ROOT/scripts/check.sh" || \
    fail 'repository checks do not include the maintenance CLI fixture'

printf 'Maintenance status, recovery, and public routes are bounded and guarded.\n'
