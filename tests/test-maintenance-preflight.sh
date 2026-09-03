#!/usr/bin/env bash
# shellcheck disable=SC2317  # Probe overrides are invoked indirectly by the library.
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-preflight-test.XXXXXXXX")
TEST_REPO="$TEST_ROOT/repository"
PROBE_LOG="$TEST_ROOT/probes.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-preflight-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Maintenance preflight test failed: %s\n' "$*" >&2
    exit 1
}

# shellcheck source=scripts/lib.sh
source "$PROJECT_ROOT/scripts/lib.sh"
# shellcheck source=scripts/lib/maintenance-transaction.sh
source "$PROJECT_ROOT/scripts/lib/maintenance-transaction.sh"
# shellcheck source=scripts/lib/maintenance-preflight.sh
source "$PROJECT_ROOT/scripts/lib/maintenance-preflight.sh"

mkdir -p -- "$TEST_REPO"
git -C "$TEST_REPO" init -q -b main
git -C "$TEST_REPO" config user.name 'Preflight Fixture'
git -C "$TEST_REPO" config user.email 'preflight@example.invalid'
printf 'fixture\n' > "$TEST_REPO/tracked.txt"
git -C "$TEST_REPO" add tracked.txt
git -C "$TEST_REPO" commit -q -m initial
CURRENT_COMMIT=$(git -C "$TEST_REPO" rev-parse HEAD)
CANDIDATE_COMMIT=$CURRENT_COMMIT

PREFLIGHT_SCENARIO=passed

probe_log() {
    printf '%s\n' "$1" >> "$PROBE_LOG"
}

_preflight_command_available() {
    local name=$1

    probe_log "command:$name"
    printf 'fixture-command-output-private-host\n'
    [[ ! ( $PREFLIGHT_SCENARIO == missing-command && $name == stow ) ]]
}

_preflight_space_available() {
    local class=$1 path=$2 minimum=$3

    probe_log "space:$class"
    printf 'fixture-space-output-private-device:%s:%s\n' "$path" "$minimum"
    [[ ! ( $PREFLIGHT_SCENARIO == low-space && $class == home ) ]]
}

_preflight_pacman_unlocked() {
    probe_log package-lock
    printf 'fixture-package-lock-private-process\n'
    [[ $PREFLIGHT_SCENARIO != package-lock ]]
}

_preflight_remote_ready() {
    probe_log upstream-network
    printf 'fixture-network-output-private-ssid\n'
    [[ $PREFLIGHT_SCENARIO != network-fail ]]
}

_preflight_os_supported() {
    probe_log operating-system
    printf 'fixture-os-output-private-host\n'
    [[ $PREFLIGHT_SCENARIO != unsupported-os ]]
}

reset_context() {
    _maintenance_close_lock_fd
    unset MYHYPR_TRANSACTION_DIR MAINTENANCE_STATE_ROOT
    unset MAINTENANCE_RUNTIME_ROOT MAINTENANCE_TX_ROOT
}

write_git_evidence() {
    local tx_dir=$1 status=${2:-0}

    jq -n --arg id "${tx_dir##*/}" --arg candidate "$CANDIDATE_COMMIT" \
        --argjson status "$status" '
        {
            version: 1,
            transaction_id: $id,
            candidate_commit: $candidate,
            checks: {
                trusted_scan: $status,
                audit: $status,
                quick: $status
            }
        }
    ' > "$tx_dir/git.json"
    chmod 0600 -- "$tx_dir/git.json"
}

write_snapshot_probe() {
    local tx_dir=$1 reason=${2:-explicitly-disabled}

    jq -n --arg reason "$reason" '
        {
            version: 1,
            provider: "none",
            coverage: {
                root: false,
                package_db: false,
                home: false,
                boot: false
            },
            system_restorable: false,
            reason: $reason
        }
    ' > "$tx_dir/snapshot-probe.json"
    chmod 0600 -- "$tx_dir/snapshot-probe.json"
}

begin_case() {
    local name=$1 operation=$2 profile=$3 case_root

    reset_context
    case_root="$TEST_ROOT/$name"
    HOME="$case_root/home"
    XDG_STATE_HOME="$case_root/state"
    XDG_RUNTIME_DIR="$case_root/run"
    export HOME XDG_STATE_HOME XDG_RUNTIME_DIR
    mkdir -p -- "$HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
    chmod 0700 -- "$HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
    maintenance_paths_init || fail "$name paths could not be initialized"
    maintenance_lock_acquire || fail "$name lock could not be acquired"
    maintenance_tx_begin "$operation" "$profile" \
        "$CURRENT_COMMIT" "$CANDIDATE_COMMIT" || \
        fail "$name transaction could not begin"
    TX_DIR=$MYHYPR_TRANSACTION_DIR
    write_git_evidence "$TX_DIR"
    write_snapshot_probe "$TX_DIR"
    : > "$PROBE_LOG"
}

run_preflight() {
    local operation=$1 profile=$2 expected=$3 actual

    set +e
    maintenance_preflight "$operation" "$profile" "$TX_DIR" "$TEST_REPO"
    actual=$?
    set -e
    [[ $actual -eq $expected ]] || \
        fail "$operation/$profile returned $actual instead of $expected"
}

assert_schema() {
    local file=$1 operation=$2 profile=$3

    [[ $(stat -c %a -- "$file") == 600 ]] || fail 'preflight evidence is not private'
    jq -e --arg id "${TX_DIR##*/}" --arg operation "$operation" \
        --arg profile "$profile" '
        .version == 1 and .transaction_id == $id and
        .operation == $operation and .profile == $profile and
        (.created_at | type == "string" and test("^[0-9]{8}T[0-9]{6}Z$")) and
        (.result == "passed" or .result == "failed") and
        (.required_passed | type == "boolean") and
        (.checks | type == "array" and length == 8) and
        ([.checks[].name] | sort) == ([
            "candidate-evidence","free-space","operating-system",
            "package-manager-lock","repository-clean","required-commands",
            "snapshot-coverage","upstream-network"
        ] | sort) and
        ([.checks[].name] | length) == ([.checks[].name] | unique | length) and
        all(.checks[];
            (keys | sort) == (["exit_status","name","status"] | sort) and
            (.name | type == "string" and test("^[a-z0-9-]{1,64}$")) and
            (.status == "passed" or .status == "failed") and
            (.exit_status | type == "number" and . >= 0 and . <= 255)
        ) and
        (.manual_intervention | type == "array" and length <= 8) and
        all(.manual_intervention[];
            type == "string" and test("^[a-z0-9-]{1,64}$")
        ) and
        (.manual_intervention | length) ==
            (.manual_intervention | unique | length) and
        (keys | sort) == ([
            "checks","created_at","manual_intervention","operation","profile",
            "required_passed","result","transaction_id","version"
        ] | sort)
    ' "$file" >/dev/null || fail 'preflight JSON schema is unbounded or incorrect'
    for private_value in fixture-command-output-private-host \
        fixture-space-output-private-device fixture-package-lock-private-process \
        fixture-network-output-private-ssid fixture-os-output-private-host \
        "$HOME" "$TEST_REPO"; do
        ! rg -Fq -- "$private_value" "$file" || \
            fail "preflight evidence leaked probe output: $private_value"
    done
}

assert_failed_class() {
    local class=$1

    jq -e --arg class "$class" '
        .required_passed == false and .result == "failed" and
        (.manual_intervention | index($class)) != null
    ' "$TX_DIR/preflight.json" >/dev/null || fail "missing failure class: $class"
}

begin_case passed dotfiles desktop
PREFLIGHT_SCENARIO=passed
ASSUME_YES=0
run_preflight dotfiles desktop 0
assert_schema "$TX_DIR/preflight.json" dotfiles desktop
jq -e '
    .required_passed == true and .result == "passed" and
    all(.checks[]; .status == "passed") and .manual_intervention == []
' "$TX_DIR/preflight.json" >/dev/null || fail 'healthy preflight did not pass'
jq -e '
    .recovery.system_provider == "none" and
    .recovery.system_coverage.reason == "explicitly-disabled"
' "$TX_DIR/journal.json" >/dev/null || fail 'snapshot coverage was not journaled'

begin_case missing-command dotfiles desktop
PREFLIGHT_SCENARIO='missing-command'
run_preflight dotfiles desktop 1
assert_schema "$TX_DIR/preflight.json" dotfiles desktop
assert_failed_class required-command-missing

begin_case low-space dotfiles desktop
PREFLIGHT_SCENARIO=low-space
run_preflight dotfiles desktop 1
assert_schema "$TX_DIR/preflight.json" dotfiles desktop
assert_failed_class low-space

begin_case package-lock dotfiles desktop
PREFLIGHT_SCENARIO=package-lock
run_preflight dotfiles desktop 1
assert_schema "$TX_DIR/preflight.json" dotfiles desktop
assert_failed_class package-manager-active

begin_case dirty-worktree dotfiles desktop
PREFLIGHT_SCENARIO=passed
printf 'private dirty worktree content\n' > "$TEST_REPO/untracked-private.txt"
run_preflight dotfiles desktop 1
rm -f -- "$TEST_REPO/untracked-private.txt"
assert_schema "$TX_DIR/preflight.json" dotfiles desktop
assert_failed_class worktree-dirty
! rg -Fq 'untracked-private' "$TX_DIR/preflight.json" || \
    fail 'dirty worktree path leaked into preflight evidence'

begin_case network-fail dotfiles desktop
PREFLIGHT_SCENARIO=network-fail
run_preflight dotfiles desktop 1
assert_schema "$TX_DIR/preflight.json" dotfiles desktop
assert_failed_class upstream-unavailable

begin_case unsupported-os system full
PREFLIGHT_SCENARIO=unsupported-os
run_preflight system full 1
assert_schema "$TX_DIR/preflight.json" system full
assert_failed_class unsupported-operating-system

begin_case snapshot-unaccepted dotfiles desktop
PREFLIGHT_SCENARIO=passed
ASSUME_YES=0
write_snapshot_probe "$TX_DIR" no-provider
run_preflight dotfiles desktop 1 </dev/null
assert_schema "$TX_DIR/preflight.json" dotfiles desktop
assert_failed_class snapshot-coverage-unaccepted

begin_case candidate-fail dotfiles desktop
PREFLIGHT_SCENARIO=passed
write_git_evidence "$TX_DIR" 23
run_preflight dotfiles desktop 1
assert_schema "$TX_DIR/preflight.json" dotfiles desktop
assert_failed_class candidate-untrusted

begin_case mismatch dotfiles core
PREFLIGHT_SCENARIO=passed
if maintenance_preflight system core "$TX_DIR" "$TEST_REPO"; then
    fail 'preflight accepted an operation that differs from its journal'
fi
[[ ! -e $TX_DIR/preflight.json ]] || fail 'rejected context wrote preflight evidence'

if rg -q '(^|:)(sudo|pkexec|install-packages|link-dotfiles|configure-system)(:|$)' \
    "$PROBE_LOG"; then
    fail 'preflight invoked a privileged or mutating helper'
fi

printf 'Maintenance preflight is read-only, bounded, and recovery-aware.\n'
