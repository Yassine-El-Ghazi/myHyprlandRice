#!/usr/bin/env bash
# shellcheck disable=SC2016  # Fixture scripts intentionally contain literal variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-snapshot-test.XXXXXXXX")
COMMON_BIN="$TEST_ROOT/common-bin"
SNAPPER_BIN="$TEST_ROOT/snapper-bin"
TIMESHIFT_BIN="$TEST_ROOT/timeshift-bin"
DANGER_BIN="$TEST_ROOT/danger-bin"
COMMAND_LOG="$TEST_ROOT/commands.log"
HOST_COMMAND_PATH=$PATH

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-snapshot-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Maintenance snapshot test failed: %s\n' "$*" >&2
    exit 1
}

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"
# shellcheck source=scripts/lib/maintenance-transaction.sh
source "$REPO_ROOT/scripts/lib/maintenance-transaction.sh"
# shellcheck source=scripts/lib/maintenance-snapshot.sh
source "$REPO_ROOT/scripts/lib/maintenance-snapshot.sh"

# Exercise provider logic with fixture binaries while production resolves only
# audited root-owned system executables.
_snapshot_trusted_binary() {
    command -v -- "$1"
}

mkdir -p -- "$COMMON_BIN" "$SNAPPER_BIN" "$TIMESHIFT_BIN" "$DANGER_BIN"
for fixture_tool in bash jq sed tail cut chmod mv rm id realpath \
    find sort date sha256sum dirname tr cat; do
    fixture_tool_path=$(command -v "$fixture_tool")
    ln -s -- "$fixture_tool_path" "$COMMON_BIN/$fixture_tool"
done

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'if [[ ${1:-} == -Lc && ${2:-} == %i && ${3:-} == -- ]]; then' \
    '    if [[ $SNAPSHOT_TEST_SCENARIO == snapper-nested-package && ${4:-} == /var/lib ]]; then' \
    '        printf "%s\n" 256' \
    '    else' \
    '        printf "%s\n" 1024' \
    '    fi' \
    '    exit 0' \
    'fi' \
    'exec /usr/bin/stat "$@"' > "$COMMON_BIN/stat"
chmod +x -- "$COMMON_BIN/stat"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'if [[ ${SNAPSHOT_JOURNAL_UPDATE_FAIL:-0} == 1 && ${1:-} == */.journal.XXXXXXXX ]]; then' \
    '    exit 73' \
    'fi' \
    'if [[ ${SNAPSHOT_METADATA_FAIL:-0} == 1 && ${1:-} == */.snapshot.XXXXXXXX ]]; then' \
    '    exit 73' \
    'fi' \
    'exec /usr/bin/mktemp "$@"' > "$COMMON_BIN/mktemp"
chmod +x -- "$COMMON_BIN/mktemp"

for danger_command in btrfs reboot shutdown snapper systemctl timeshift; do
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "danger:%s\n" "${0##*/}" >> "$SNAPSHOT_COMMAND_LOG"' \
        'exit 97' > "$DANGER_BIN/$danger_command"
    chmod +x -- "$DANGER_BIN/$danger_command"
done

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'mount_target=' \
    'while (($#)); do' \
    '    case $1 in' \
    '        -T|--target) mount_target=$2; shift 2 ;;' \
    '        *) shift ;;' \
    '    esac' \
    'done' \
    '[[ -n $mount_target ]] || exit 64' \
    'if [[ $SNAPSHOT_TEST_SCENARIO == snapper-malformed-mount ]]; then' \
    "    printf '%s\\n' '{\"filesystems\":'" \
    '    exit 0' \
    'fi' \
    'root_type=btrfs' \
    'root_source="/dev/root[/@]"' \
    'target=/' \
    'fs_type=$root_type' \
    'source_name=$root_source' \
    'case $SNAPSHOT_TEST_SCENARIO in' \
    '    ext4-no-tool|rsync-timeshift) root_type=ext4; root_source=/dev/root; fs_type=ext4; source_name=/dev/root ;;' \
    'esac' \
    'case $mount_target in' \
    '    /|/var/lib/pacman) ;;' \
    '    /home)' \
    '        case $SNAPSHOT_TEST_SCENARIO in' \
    '            snapper-full) ;;' \
    '            btrfs-timeshift-custom-home) target=/home; source_name="/dev/root[/@custom-home]" ;;' \
    '            *) target=/home; source_name="/dev/root[/@home]" ;;' \
    '        esac' \
    '        ;;' \
    '    /boot)' \
    '        case $SNAPSHOT_TEST_SCENARIO in' \
    '            snapper-root-boot|snapper-full) ;;' \
    '            *) target=/boot; fs_type=ext4; source_name=/dev/boot ;;' \
    '        esac' \
    '        ;;' \
    '    *) exit 64 ;;' \
    'esac' \
    "jq -n --arg target \"\$target\" --arg fstype \"\$fs_type\" --arg source \"\$source_name\" '{filesystems:[{target:\$target,fstype:\$fstype,source:\$source,options:\"rw\"}]}'" \
    > "$COMMON_BIN/findmnt"
chmod +x -- "$COMMON_BIN/findmnt"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'if [[ $* == "--jsonout list-configs" ]]; then' \
    '    [[ $SNAPSHOT_TEST_SCENARIO != snapper-privileged ]] || exit 1' \
    '    case $SNAPSHOT_TEST_SCENARIO in' \
    '        broken-provider|snapper-broken-timeshift)' \
    "            printf '%s\\n' '{\"configs\":'" \
    '            ;;' \
    '        snapper-*|both-healthy)' \
    "            printf '%s\\n' '{\"configs\":[{\"config\":\"root\",\"subvolume\":\"/\"}]}'" \
    '            ;;' \
    "        *) printf '%s\\n' '{\"configs\":[]}' ;;" \
    '    esac' \
    '    exit 0' \
    'fi' \
    'exit 64' > "$SNAPPER_BIN/snapper"
chmod +x -- "$SNAPPER_BIN/snapper"

printf '%s\n' '#!/usr/bin/env bash' 'exit 64' > "$TIMESHIFT_BIN/timeshift"
chmod +x -- "$TIMESHIFT_BIN/timeshift"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'if [[ ${1:-} == -n ]]; then' \
    '    shift' \
    '    if [[ ${1##*/} == snapper && " $* " == *" --jsonout list-configs "* ]]; then' \
    '        [[ $SNAPSHOT_TEST_SCENARIO == snapper-privileged ]] || exit 1' \
    "        printf '%s\\n' '{\"configs\":[{\"config\":\"root\",\"subvolume\":\"/\"}]}'" \
    '        exit 0' \
    '    fi' \
    '    if [[ ${1##*/} == timeshift && " $* " == *" --scripted --list "* ]]; then' \
    '        case $SNAPSHOT_TEST_SCENARIO in' \
    "            btrfs-timeshift|btrfs-timeshift-custom-home|both-healthy|snapper-broken-timeshift) printf '%s\\n' 'Mode : BTRFS' 'Status : OK' ;;" \
    "            rsync-timeshift) printf '%s\\n' 'Mode : RSYNC' 'Status : OK' ;;" \
    '            *) exit 1 ;;' \
    '        esac' \
    '        exit 0' \
    '    fi' \
    '    if [[ ${1##*/} == cat && ${2:-} == /etc/timeshift/timeshift.json ]]; then' \
    '        case $SNAPSHOT_TEST_SCENARIO in' \
    "            btrfs-timeshift|btrfs-timeshift-custom-home|both-healthy|snapper-broken-timeshift) printf '%s\\n' '{\"btrfs_mode\":\"true\",\"include_btrfs_home\":\"true\",\"exclude\":[]}' ;;" \
    "            rsync-timeshift) printf '%s\\n' '{\"btrfs_mode\":\"false\",\"include_btrfs_home\":\"false\",\"exclude\":[\"/**\"]}' ;;" \
    '            *) exit 1 ;;' \
    '        esac' \
    '        exit 0' \
    '    fi' \
    '    exit 1' \
    'fi' \
    'jq -cn --args '\''$ARGS.positional'\'' -- "$@" >> "$SNAPSHOT_COMMAND_LOG"' \
    '[[ ${SNAPSHOT_CREATE_FAIL:-0} == 0 ]] || exit 42' \
    'case ${1##*/} in' \
    '    snapper)' \
    '        [[ ${SNAPSHOT_INVALID_IDENTIFIER:-0} == 0 ]] && printf "%s\n" 42 || printf "%s\n" invalid' \
    '        ;;' \
    '    timeshift)' \
    "        [[ \${SNAPSHOT_INVALID_IDENTIFIER:-0} == 0 ]] && printf '%s\\n' \"Tagged snapshot '2026-08-29_18-30-00': ondemand\" || printf '%s\\n' 'Snapshot completed without an identifier'" \
    '        ;;' \
    '    *) exit 64 ;;' \
    'esac' > "$COMMON_BIN/sudo"
chmod +x -- "$COMMON_BIN/sudo"
export SNAPSHOT_COMMAND_LOG="$COMMAND_LOG"

matrix_path() {
    case $1 in
        snapper-root|snapper-privileged|snapper-nested-package|snapper-root-boot|snapper-full|snapper-malformed-mount|broken-provider)
            printf '%s:%s\n' "$SNAPPER_BIN" "$COMMON_BIN"
            ;;
        both-healthy|snapper-broken-timeshift)
            printf '%s:%s:%s\n' "$SNAPPER_BIN" "$TIMESHIFT_BIN" "$COMMON_BIN"
            ;;
        btrfs-timeshift|btrfs-timeshift-custom-home|rsync-timeshift)
            printf '%s:%s\n' "$TIMESHIFT_BIN" "$COMMON_BIN"
            ;;
        ext4-no-tool) printf '%s\n' "$COMMON_BIN" ;;
        *) return 1 ;;
    esac
}

probe_case() {
    local scenario=$1 expected_provider=$2 expected_root=$3 expected_package=$4
    local expected_home=$5 expected_boot=$6 expected_restorable=$7 expected_reason=$8
    local selector=${9:-auto} probe probe_status=0 fixture_path

    fixture_path=$(matrix_path "$scenario")
    probe=$(PATH="$fixture_path" SNAPSHOT_TEST_SCENARIO="$scenario" \
        MYHYPR_SNAPSHOT_PROVIDER="$selector" snapshot_probe) || probe_status=$?
    [[ $probe_status -eq 0 ]] || fail "$scenario probe returned $probe_status"
    jq -e --arg provider "$expected_provider" --arg reason "$expected_reason" \
        --argjson root "$expected_root" --argjson package_db "$expected_package" \
        --argjson home "$expected_home" --argjson boot "$expected_boot" \
        --argjson restorable "$expected_restorable" '
        .version == 1 and .provider == $provider and .reason == $reason and
        .coverage.root == $root and .coverage.package_db == $package_db and
        .coverage.home == $home and .coverage.boot == $boot and
        .system_restorable == $restorable and
        (keys | sort) == (["coverage","provider","reason","system_restorable","version"] | sort)
    ' <<< "$probe" >/dev/null || fail "$scenario returned incorrect bounded coverage"
    printf '%s\n' "$probe"
}

probe_case ext4-no-tool none false false false false false no-provider >/dev/null
probe_none=$(probe_case ext4-no-tool none false false false false false explicitly-disabled none)
probe_snapper_root=$(probe_case snapper-root snapper true true false false false healthy)
probe_case snapper-privileged snapper true true false false false healthy >/dev/null
probe_case snapper-nested-package snapper true false false false false healthy >/dev/null
probe_case snapper-root-boot snapper true true false true true healthy >/dev/null
probe_snapper_full=$(probe_case snapper-full snapper true true true true true healthy)
probe_timeshift=$(probe_case btrfs-timeshift timeshift true true true false false healthy)
probe_case btrfs-timeshift-custom-home timeshift true true false false false healthy >/dev/null
probe_case rsync-timeshift none false false false false false probe-failed >/dev/null
probe_case both-healthy snapper true true false false false healthy >/dev/null
probe_case snapper-broken-timeshift timeshift true true true false false healthy >/dev/null
probe_case snapper-malformed-mount none false false false false false probe-failed >/dev/null
probe_case broken-provider none false false false false false probe-failed >/dev/null

IFS=:
_snapshot_uncovered_layers "$probe_snapper_root" >/dev/null
[[ ${IFS-} == : ]] || fail 'uncovered-layer formatting modified the caller IFS'
unset IFS

set +e
forced_output=$(PATH="$COMMON_BIN" SNAPSHOT_TEST_SCENARIO=ext4-no-tool \
    MYHYPR_SNAPSHOT_PROVIDER=snapper snapshot_probe 2>&1)
forced_status=$?
set -e
[[ $forced_status -ne 0 ]] || fail 'a forced unavailable provider was accepted'
[[ $forced_output == *snapper* ]] || fail 'forced-provider failure omitted its bounded class'
set +e
forced_timeshift_output=$(PATH="$COMMON_BIN" SNAPSHOT_TEST_SCENARIO=ext4-no-tool \
    MYHYPR_SNAPSHOT_PROVIDER=timeshift snapshot_probe 2>&1)
forced_timeshift_status=$?
invalid_selector_output=$(PATH="$COMMON_BIN" SNAPSHOT_TEST_SCENARIO=ext4-no-tool \
    MYHYPR_SNAPSHOT_PROVIDER=invalid snapshot_probe 2>&1)
invalid_selector_status=$?
set -e
[[ $forced_timeshift_status -ne 0 && $forced_timeshift_output == *timeshift* ]] || \
    fail 'forced unavailable Timeshift did not fail with its bounded class'
[[ $invalid_selector_status -eq 64 && $invalid_selector_output == *'auto, none, snapper, or timeshift'* ]] || \
    fail 'invalid provider selector was accepted or poorly diagnosed'
[[ ! -s $COMMAND_LOG ]] || fail 'read-only provider probing executed a snapshot command'

CURRENT_COMMIT=$(printf '1%.0s' {1..40})
CANDIDATE_COMMIT=$(printf '2%.0s' {1..40})

release_transaction_lock() {
    local lock_fd=${MYHYPR_MAINTENANCE_LOCK_FD:-}

    if [[ $lock_fd =~ ^[0-9]+$ ]]; then
        flock -u "$lock_fd" || true
        eval "exec ${lock_fd}>&-"
    fi
    unset MYHYPR_MAINTENANCE_LOCK_FD MYHYPR_TRANSACTION_DIR
}

prepare_transaction() {
    local fixture_name=$1 provider=$2 coverage=$3

    HOME="$TEST_ROOT/$fixture_name/home"
    XDG_STATE_HOME="$TEST_ROOT/$fixture_name/state"
    XDG_RUNTIME_DIR="$TEST_ROOT/$fixture_name/run"
    export HOME XDG_STATE_HOME XDG_RUNTIME_DIR
    mkdir -p -- "$HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
    chmod 0700 -- "$HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
    unset MAINTENANCE_STATE_ROOT MAINTENANCE_RUNTIME_ROOT MAINTENANCE_TX_ROOT
    unset MYHYPR_TRANSACTION_DIR MYHYPR_MAINTENANCE_LOCK_FD
    maintenance_paths_init
    maintenance_lock_acquire
    maintenance_tx_begin system desktop "$CURRENT_COMMIT" "$CANDIDATE_COMMIT"
    maintenance_tx_transition "$MYHYPR_TRANSACTION_DIR" planned preflighted preflight
    maintenance_tx_complete_stage "$MYHYPR_TRANSACTION_DIR" preflight
    maintenance_tx_transition "$MYHYPR_TRANSACTION_DIR" preflighted checkpointed checkpoint
    maintenance_tx_complete_stage "$MYHYPR_TRANSACTION_DIR" checkpoint
    maintenance_tx_set_recovery "$MYHYPR_TRANSACTION_DIR" ready "$provider" "$coverage"
}

prepare_transaction incomplete snapper "$probe_snapper_root"
incomplete_tx=$MYHYPR_TRANSACTION_DIR
: > "$COMMAND_LOG"
set +e
incomplete_output=$(PATH="$SNAPPER_BIN:$COMMON_BIN:$HOST_COMMAND_PATH" \
    SNAPSHOT_TEST_SCENARIO=snapper-root ASSUME_YES=0 \
    snapshot_create "$incomplete_tx" snapper </dev/null 2>&1)
incomplete_status=$?
set -e
[[ $incomplete_status -eq 2 ]] || \
    fail "unaccepted incomplete coverage returned $incomplete_status instead of 2"
[[ $incomplete_output == *home* && $incomplete_output == *boot* ]] || \
    fail 'incomplete coverage did not expose exact uncovered layers'
[[ ! -s $COMMAND_LOG && ! -e $incomplete_tx/snapshot.json ]] || \
    fail 'unaccepted incomplete coverage created a snapshot'

PATH="$SNAPPER_BIN:$COMMON_BIN:$HOST_COMMAND_PATH" \
SNAPSHOT_TEST_SCENARIO=snapper-root ASSUME_YES=1 \
    snapshot_create "$incomplete_tx" snapper
[[ $(wc -l < "$COMMAND_LOG") -eq 1 ]] || fail 'Snapper creation invoked more than one command'
snapper_description="MyHypr ${incomplete_tx##*/}"
snapper_userdata="myhypr_transaction=${incomplete_tx##*/}"
jq -e --arg binary "$SNAPPER_BIN/snapper" --arg description "$snapper_description" \
    --arg userdata "$snapper_userdata" '
    . == [$binary,"-c","root","create","--type","single","--print-number",
          "--description",$description,"--userdata",$userdata]
' "$COMMAND_LOG" >/dev/null || \
    fail 'Snapper creation command did not match the approved adapter'
jq -e '
    .version == 1 and .provider == "snapper" and .identifier == "42" and
    .coverage.root == true and .coverage.package_db == true and
    .coverage.home == false and .coverage.boot == false and
    (.created_at | test("^[0-9]{8}T[0-9]{6}Z$")) and
    (keys | sort) == (["coverage","created_at","identifier","provider","version"] | sort)
' "$incomplete_tx/snapshot.json" >/dev/null || fail 'Snapper metadata is unbounded or incorrect'
[[ $(stat -c %a "$incomplete_tx/snapshot.json") == 600 ]] || \
    fail 'Snapper metadata is not private'
before_guidance_commands=$(wc -l < "$COMMAND_LOG")
guidance=$(PATH="$DANGER_BIN:$COMMON_BIN" \
    snapshot_guidance "$incomplete_tx" snapper)
[[ $guidance == *snapper* && $guidance == *42* && $guidance == *home* && \
    $guidance == *boot* && $guidance == *'/var/log/pacman.log'* && \
    $guidance == *'https://'* ]] || fail 'Snapper guidance omitted bounded recovery references'
[[ $(wc -l < "$COMMAND_LOG") -eq $before_guidance_commands ]] || \
    fail 'snapshot guidance executed a command'

coverage_tampered="$incomplete_tx/.snapshot-coverage-tampered.json"
jq '.coverage.home = true' "$incomplete_tx/snapshot.json" > "$coverage_tampered"
chmod 0600 -- "$coverage_tampered"
mv -- "$coverage_tampered" "$incomplete_tx/snapshot.json"
set +e
coverage_guidance=$(snapshot_guidance "$incomplete_tx" snapper 2>&1)
coverage_guidance_status=$?
set -e
[[ $coverage_guidance_status -ne 0 && -z $coverage_guidance ]] || \
    fail 'snapshot guidance accepted coverage that disagrees with the journal'
coverage_restored="$incomplete_tx/.snapshot-coverage-restored.json"
jq '.coverage.home = false' "$incomplete_tx/snapshot.json" > "$coverage_restored"
chmod 0600 -- "$coverage_restored"
mv -- "$coverage_restored" "$incomplete_tx/snapshot.json"

set +e
PATH="$SNAPPER_BIN:$COMMON_BIN:$HOST_COMMAND_PATH" \
SNAPSHOT_TEST_SCENARIO=snapper-root ASSUME_YES=1 \
    snapshot_create "$incomplete_tx" snapper >/dev/null 2>&1
duplicate_status=$?
set -e
[[ $duplicate_status -ne 0 ]] || fail 'duplicate snapshot creation was accepted'
[[ $(wc -l < "$COMMAND_LOG") -eq $before_guidance_commands ]] || \
    fail 'duplicate snapshot creation invoked the provider before rejecting existing metadata'

metadata_next="$incomplete_tx/.snapshot-tampered.json"
jq '.identifier = "42\u001b[31m\nunsafe"' "$incomplete_tx/snapshot.json" > "$metadata_next"
chmod 0600 -- "$metadata_next"
mv -- "$metadata_next" "$incomplete_tx/snapshot.json"
set +e
tampered_guidance=$(snapshot_guidance "$incomplete_tx" snapper 2>&1)
tampered_guidance_status=$?
set -e
[[ $tampered_guidance_status -ne 0 && -z $tampered_guidance ]] || \
    fail 'tampered snapshot identifier reached recovery guidance'
release_transaction_lock

prepare_transaction explicit-none none "$probe_none"
explicit_none_tx=$MYHYPR_TRANSACTION_DIR
: > "$COMMAND_LOG"
PATH="$COMMON_BIN:$HOST_COMMAND_PATH" SNAPSHOT_TEST_SCENARIO=ext4-no-tool ASSUME_YES=0 \
    snapshot_create "$explicit_none_tx" none
[[ ! -s $COMMAND_LOG ]] || fail 'explicit none selection invoked a provider command'
jq -e '.provider == "none" and .identifier == "none" and
    (.coverage | all(. == false))' "$explicit_none_tx/snapshot.json" >/dev/null || \
    fail 'explicit none selection did not publish bounded metadata'
release_transaction_lock

prepare_transaction missing-checkpoint snapper "$probe_snapper_full"
missing_checkpoint_tx=$MYHYPR_TRANSACTION_DIR
maintenance_journal_update "$missing_checkpoint_tx" \
    '.completed_stages -= ["checkpoint"]'
: > "$COMMAND_LOG"
set +e
PATH="$SNAPPER_BIN:$COMMON_BIN:$HOST_COMMAND_PATH" \
SNAPSHOT_TEST_SCENARIO=snapper-full ASSUME_YES=1 \
    snapshot_create "$missing_checkpoint_tx" snapper >/dev/null 2>&1
missing_checkpoint_status=$?
set -e
[[ $missing_checkpoint_status -ne 0 && ! -s $COMMAND_LOG ]] || \
    fail 'snapshot creation without a completed checkpoint reached the provider'
release_transaction_lock

prepare_transaction unready-recovery snapper "$probe_snapper_full"
unready_recovery_tx=$MYHYPR_TRANSACTION_DIR
maintenance_journal_update "$unready_recovery_tx" \
    '.recovery.configuration = "pending"'
: > "$COMMAND_LOG"
set +e
PATH="$SNAPPER_BIN:$COMMON_BIN:$HOST_COMMAND_PATH" \
SNAPSHOT_TEST_SCENARIO=snapper-full ASSUME_YES=1 \
    snapshot_create "$unready_recovery_tx" snapper >/dev/null 2>&1
unready_recovery_status=$?
set -e
[[ $unready_recovery_status -ne 0 && ! -s $COMMAND_LOG ]] || \
    fail 'snapshot creation without ready configuration recovery reached the provider'
release_transaction_lock

prepare_transaction none-metadata-failure none "$probe_none"
none_metadata_tx=$MYHYPR_TRANSACTION_DIR
: > "$COMMAND_LOG"
set +e
PATH="$COMMON_BIN:$HOST_COMMAND_PATH" SNAPSHOT_TEST_SCENARIO=ext4-no-tool \
SNAPSHOT_METADATA_FAIL=1 ASSUME_YES=0 \
    snapshot_create "$none_metadata_tx" none >/dev/null 2>&1
none_metadata_status=$?
set -e
[[ $none_metadata_status -eq 74 ]] || \
    fail "none metadata failure returned $none_metadata_status instead of 74"
[[ ! -s $COMMAND_LOG && ! -e $none_metadata_tx/snapshot.json ]] || \
    fail 'none metadata failure invoked a provider or published metadata'
jq -e '.state == "failed" and
    .failure.message_class == "snapshot-metadata-failed"' \
    "$none_metadata_tx/journal.json" >/dev/null || \
    fail 'none metadata failure was not journaled'
release_transaction_lock

prepare_transaction lockless snapper "$probe_snapper_full"
lockless_tx=$MYHYPR_TRANSACTION_DIR
lockless_fd=$MYHYPR_MAINTENANCE_LOCK_FD
flock -u "$lockless_fd"
eval "exec ${lockless_fd}>&-"
unset MYHYPR_MAINTENANCE_LOCK_FD
: > "$COMMAND_LOG"
set +e
PATH="$SNAPPER_BIN:$COMMON_BIN:$HOST_COMMAND_PATH" \
SNAPSHOT_TEST_SCENARIO=snapper-full ASSUME_YES=1 \
    snapshot_create "$lockless_tx" snapper >/dev/null 2>&1
lockless_status=$?
set -e
[[ $lockless_status -ne 0 ]] || fail 'snapshot creation without the transaction lock was accepted'
[[ ! -s $COMMAND_LOG && ! -e $lockless_tx/snapshot.json ]] || \
    fail 'lockless snapshot creation reached provider mutation or metadata'
unset MYHYPR_TRANSACTION_DIR

prepare_transaction stale snapper "$probe_snapper_full"
stale_tx=$MYHYPR_TRANSACTION_DIR
: > "$COMMAND_LOG"
set +e
PATH="$SNAPPER_BIN:$COMMON_BIN:$HOST_COMMAND_PATH" \
SNAPSHOT_TEST_SCENARIO=snapper-root ASSUME_YES=1 \
    snapshot_create "$stale_tx" snapper >/dev/null 2>&1
stale_status=$?
set -e
[[ $stale_status -ne 0 ]] || fail 'stale snapshot coverage was accepted'
[[ ! -s $COMMAND_LOG && ! -e $stale_tx/snapshot.json ]] || \
    fail 'stale snapshot coverage reached provider mutation or metadata'
jq -e '.state == "failed" and
    .failure.message_class == "snapshot-coverage-changed"' \
    "$stale_tx/journal.json" >/dev/null || \
    fail 'stale snapshot coverage was not journaled as a blocking failure'
release_transaction_lock

prepare_transaction tampered snapper "$probe_snapper_full"
tampered_tx=$MYHYPR_TRANSACTION_DIR
maintenance_journal_update "$tampered_tx" \
    '.recovery.system_coverage.coverage.untrusted = true'
: > "$COMMAND_LOG"
set +e
PATH="$SNAPPER_BIN:$COMMON_BIN:$HOST_COMMAND_PATH" \
SNAPSHOT_TEST_SCENARIO=snapper-full ASSUME_YES=1 \
    snapshot_create "$tampered_tx" snapper >/dev/null 2>&1
tampered_status=$?
set -e
[[ $tampered_status -ne 0 ]] || fail 'unbounded journal coverage was accepted'
[[ ! -s $COMMAND_LOG && ! -e $tampered_tx/snapshot.json ]] || \
    fail 'unbounded journal coverage reached the provider or snapshot metadata'
release_transaction_lock

prepare_transaction invalid-snapper-id snapper "$probe_snapper_full"
invalid_snapper_tx=$MYHYPR_TRANSACTION_DIR
: > "$COMMAND_LOG"
set +e
PATH="$SNAPPER_BIN:$COMMON_BIN:$HOST_COMMAND_PATH" \
SNAPSHOT_TEST_SCENARIO=snapper-full SNAPSHOT_INVALID_IDENTIFIER=1 ASSUME_YES=1 \
    snapshot_create "$invalid_snapper_tx" snapper >/dev/null 2>&1
invalid_snapper_status=$?
set -e
[[ $invalid_snapper_status -eq 65 ]] || \
    fail "invalid Snapper identifier returned $invalid_snapper_status instead of 65"
[[ $(wc -l < "$COMMAND_LOG") -eq 1 && ! -e $invalid_snapper_tx/snapshot.json ]] || \
    fail 'invalid Snapper identifier retried or published metadata'
jq -e '.status == "creating" and .identifier == ""' \
    "$invalid_snapper_tx/snapshot.pending.json" >/dev/null || \
    fail 'invalid Snapper identifier lost pending provider evidence'
jq -e '.state == "failed" and
    .failure.message_class == "snapshot-identifier-invalid"' \
    "$invalid_snapper_tx/journal.json" >/dev/null || \
    fail 'invalid Snapper identifier was not journaled'
before_unresolved_guidance=$(wc -l < "$COMMAND_LOG")
unresolved_guidance=$(PATH="$DANGER_BIN:$COMMON_BIN" \
    snapshot_guidance "$invalid_snapper_tx" snapper)
[[ $unresolved_guidance == *creating* && $unresolved_guidance == *unresolved* &&
    $unresolved_guidance == *"MyHypr ${invalid_snapper_tx##*/}"* ]] || \
    fail 'unresolved provider evidence lacks deterministic recovery guidance'
[[ $(wc -l < "$COMMAND_LOG") -eq $before_unresolved_guidance ]] || \
    fail 'unresolved snapshot guidance executed a restore, delete, or reboot command'
release_transaction_lock

prepare_transaction timeshift timeshift "$probe_timeshift"
timeshift_tx=$MYHYPR_TRANSACTION_DIR
: > "$COMMAND_LOG"
PATH="$TIMESHIFT_BIN:$COMMON_BIN:$HOST_COMMAND_PATH" \
SNAPSHOT_TEST_SCENARIO=btrfs-timeshift ASSUME_YES=1 \
    snapshot_create "$timeshift_tx" timeshift
[[ $(wc -l < "$COMMAND_LOG") -eq 1 ]] || fail 'Timeshift creation invoked more than one command'
timeshift_comment="MyHypr ${timeshift_tx##*/}"
jq -e --arg binary "$TIMESHIFT_BIN/timeshift" --arg comment "$timeshift_comment" '
    . == [$binary,"--create","--comments",$comment]
' "$COMMAND_LOG" >/dev/null || \
    fail 'Timeshift creation command did not match the approved adapter'
jq -e '.provider == "timeshift" and .identifier == "2026-08-29_18-30-00" and
    .coverage.root == true and .coverage.package_db == true and
    .coverage.home == true and .coverage.boot == false' \
    "$timeshift_tx/snapshot.json" >/dev/null || fail 'Timeshift metadata is incorrect'
[[ $(stat -c %a "$timeshift_tx/snapshot.json") == 600 &&
    ! -e $timeshift_tx/snapshot.pending.json ]] || \
    fail 'Timeshift metadata is not private and final'
release_transaction_lock

prepare_transaction invalid-timeshift-id timeshift "$probe_timeshift"
invalid_timeshift_tx=$MYHYPR_TRANSACTION_DIR
: > "$COMMAND_LOG"
set +e
PATH="$TIMESHIFT_BIN:$COMMON_BIN:$HOST_COMMAND_PATH" \
SNAPSHOT_TEST_SCENARIO=btrfs-timeshift SNAPSHOT_INVALID_IDENTIFIER=1 ASSUME_YES=1 \
    snapshot_create "$invalid_timeshift_tx" timeshift >/dev/null 2>&1
invalid_timeshift_status=$?
set -e
[[ $invalid_timeshift_status -eq 65 ]] || \
    fail "invalid Timeshift identifier returned $invalid_timeshift_status instead of 65"
[[ $(wc -l < "$COMMAND_LOG") -eq 1 && ! -e $invalid_timeshift_tx/snapshot.json ]] || \
    fail 'invalid Timeshift identifier retried or published metadata'
jq -e '.status == "creating" and .identifier == ""' \
    "$invalid_timeshift_tx/snapshot.pending.json" >/dev/null || \
    fail 'invalid Timeshift identifier lost pending provider evidence'
jq -e '.state == "failed" and
    .failure.message_class == "snapshot-identifier-invalid"' \
    "$invalid_timeshift_tx/journal.json" >/dev/null || \
    fail 'invalid Timeshift identifier was not journaled'
release_transaction_lock

prepare_transaction failed snapper "$probe_snapper_full"
failed_tx=$MYHYPR_TRANSACTION_DIR
: > "$COMMAND_LOG"
set +e
PATH="$SNAPPER_BIN:$COMMON_BIN:$HOST_COMMAND_PATH" \
SNAPSHOT_TEST_SCENARIO=snapper-full SNAPSHOT_CREATE_FAIL=1 ASSUME_YES=0 \
    snapshot_create "$failed_tx" snapper >/dev/null 2>&1
failed_status=$?
set -e
[[ $failed_status -eq 42 ]] || fail "snapshot command failure returned $failed_status instead of 42"
[[ $(wc -l < "$COMMAND_LOG") -eq 1 ]] || fail 'failed snapshot creation retried or downgraded'
[[ ! -e $failed_tx/snapshot.json ]] || fail 'failed snapshot creation published metadata'
jq -e '.state == "failed" and .failure.exit_status == 42 and
    .failure.message_class == "snapshot-create-failed" and
    .recovery.system_provider == "snapper"' "$failed_tx/journal.json" >/dev/null || \
    fail 'snapshot failure was not journaled without provider downgrade'
set +e
PATH="$SNAPPER_BIN:$COMMON_BIN:$HOST_COMMAND_PATH" \
SNAPSHOT_TEST_SCENARIO=snapper-full ASSUME_YES=1 \
    snapshot_create "$failed_tx" snapper >/dev/null 2>&1
retry_status=$?
set -e
[[ $retry_status -ne 0 ]] || fail 'failed transaction accepted a snapshot retry'
[[ $(wc -l < "$COMMAND_LOG") -eq 1 ]] || \
    fail 'failed transaction reached the provider during a retry'
release_transaction_lock

prepare_transaction journal-failure snapper "$probe_snapper_full"
journal_failure_tx=$MYHYPR_TRANSACTION_DIR
: > "$COMMAND_LOG"
set +e
PATH="$SNAPPER_BIN:$COMMON_BIN:$HOST_COMMAND_PATH" \
SNAPSHOT_TEST_SCENARIO=snapper-full SNAPSHOT_CREATE_FAIL=1 \
SNAPSHOT_JOURNAL_UPDATE_FAIL=1 ASSUME_YES=1 \
    snapshot_create "$journal_failure_tx" snapper >/dev/null 2>&1
journal_failure_status=$?
set -e
[[ $journal_failure_status -eq 74 ]] || \
    fail "failed journal publication returned $journal_failure_status instead of 74"
[[ $(wc -l < "$COMMAND_LOG") -eq 1 && ! -e $journal_failure_tx/snapshot.json ]] || \
    fail 'journal failure retried provider mutation or published metadata'
jq -e '.state == "checkpointed" and .failure == null' \
    "$journal_failure_tx/journal.json" >/dev/null || \
    fail 'journal failure published a false transaction state'
release_transaction_lock

prepare_transaction metadata-failure snapper "$probe_snapper_full"
metadata_failure_tx=$MYHYPR_TRANSACTION_DIR
: > "$COMMAND_LOG"
set +e
PATH="$SNAPPER_BIN:$COMMON_BIN:$HOST_COMMAND_PATH" \
SNAPSHOT_TEST_SCENARIO=snapper-full SNAPSHOT_METADATA_FAIL=1 ASSUME_YES=1 \
    snapshot_create "$metadata_failure_tx" snapper >/dev/null 2>&1
metadata_failure_status=$?
set -e
[[ $metadata_failure_status -eq 74 ]] || \
    fail "metadata publication failure returned $metadata_failure_status instead of 74"
[[ $(wc -l < "$COMMAND_LOG") -eq 1 && ! -e $metadata_failure_tx/snapshot.json ]] || \
    fail 'metadata failure retried provider mutation or published final metadata'
jq -e --arg transaction_id "${metadata_failure_tx##*/}" '
    .version == 1 and .provider == "snapper" and
    .transaction_id == $transaction_id and .status == "created-unpublished" and
    .identifier == "42" and
    (.updated_at | test("^[0-9]{8}T[0-9]{6}Z$")) and
    (keys | sort) ==
        (["identifier","provider","status","transaction_id","updated_at","version"] | sort)
' "$metadata_failure_tx/snapshot.pending.json" >/dev/null || \
    fail 'metadata failure left no bounded durable provider evidence'
[[ $(stat -c %a "$metadata_failure_tx/snapshot.pending.json") == 600 ]] || \
    fail 'pending snapshot evidence is not private'
jq -e '.state == "failed" and
    .failure.message_class == "snapshot-metadata-failed"' \
    "$metadata_failure_tx/journal.json" >/dev/null || \
    fail 'metadata publication failure was not journaled'
before_pending_guidance=$(wc -l < "$COMMAND_LOG")
pending_guidance=$(PATH="$DANGER_BIN:$COMMON_BIN" \
    snapshot_guidance "$metadata_failure_tx" snapper)
[[ $pending_guidance == *snapper* && $pending_guidance == *42* &&
    $pending_guidance == *created-unpublished* ]] || \
    fail 'pending provider evidence is absent from recovery guidance'
[[ $(wc -l < "$COMMAND_LOG") -eq $before_pending_guidance ]] || \
    fail 'pending snapshot guidance executed a restore, delete, or reboot command'

printf 'Snapshot providers are conservative, explicit, and non-destructive.\n'
