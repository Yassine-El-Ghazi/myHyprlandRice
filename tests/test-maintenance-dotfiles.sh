#!/usr/bin/env bash
# shellcheck disable=SC2016  # Fixture scripts intentionally contain literal variables.
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-dotfiles-maintenance.XXXXXXXX")
FIXTURE_REPO="$TEST_ROOT/repository"
FIXTURE_BIN="$TEST_ROOT/bin"
RUN_ROOT="$TEST_ROOT/runs"
ORCHESTRATOR_LOG="$TEST_ROOT/orchestrator.log"
ACTIVE_COMMIT_FILE="$TEST_ROOT/active-commit"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-dotfiles-maintenance.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Dotfiles maintenance test failed: %s\n' "$*" >&2
    exit 1
}

[[ -x $PROJECT_ROOT/scripts/maintenance.sh ]] || \
    fail 'scripts/maintenance.sh is missing'

mkdir -p -- "$FIXTURE_REPO/scripts/lib" "$FIXTURE_REPO/dotfiles/.config/waybar" \
    "$FIXTURE_REPO/dotfiles/.config/nwg-dock-hyprland" "$FIXTURE_BIN" "$RUN_ROOT"
cp -- "$PROJECT_ROOT/scripts/maintenance.sh" "$FIXTURE_REPO/scripts/maintenance.sh"
cp -- "$PROJECT_ROOT/scripts/update.sh" "$FIXTURE_REPO/scripts/update.sh"
cp -- "$PROJECT_ROOT/scripts/lib.sh" "$FIXTURE_REPO/scripts/lib.sh"
cp -- "$PROJECT_ROOT/scripts/lib/maintenance-transaction.sh" \
    "$FIXTURE_REPO/scripts/lib/maintenance-transaction.sh"
cp -- "$PROJECT_ROOT/scripts/lib/maintenance-status.sh" \
    "$FIXTURE_REPO/scripts/lib/maintenance-status.sh"

write_fake_maintenance_library() {
    local file=$1

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        '[[ ${_MYHYPR_ORCHESTRATOR_FIXTURE_LOADED:-0} == 1 ]] && return 0' \
        '_MYHYPR_ORCHESTRATOR_FIXTURE_LOADED=1' \
        '_fixture_log() { printf "%s\n" "$1" >> "$ORCHESTRATOR_LOG"; }' \
        'maintenance_git_prepare() {' \
        '  local tx_dir=$1 candidate=$ORCHESTRATOR_CANDIDATE_COMMIT' \
        '  _fixture_log git-prepare' \
        '  maintenance_journal_update "$tx_dir" ".candidate_commit = \$candidate" --arg candidate "$candidate"' \
        '  mkdir -m 0700 -- "$tx_dir/candidate"' \
        '  jq -n --arg id "${tx_dir##*/}" --arg candidate "$candidate" '\''{version:1,transaction_id:$id,candidate_commit:$candidate,checks:{trusted_scan:0,audit:0,quick:0}}'\'' > "$tx_dir/git.json"' \
        '  chmod 0600 -- "$tx_dir/git.json"' \
        '}' \
        'maintenance_git_promote() {' \
        '  local tx_dir=$1 candidate' \
        '  _fixture_log git-promote' \
        '  candidate=$(jq -er .candidate_commit "$tx_dir/journal.json")' \
        '  printf "%s\n" "$candidate" > "$ORCHESTRATOR_ACTIVE_COMMIT_FILE"' \
        '  [[ ${ORCHESTRATOR_SCENARIO:-passed} != promote-after-write-fail ]] || return 45' \
        '}' \
        'maintenance_git_restore_previous() {' \
        '  local tx_dir=$1 current' \
        '  _fixture_log git-restore' \
        '  [[ ${ORCHESTRATOR_SCENARIO:-passed} != restore-collision ]] || return 1' \
        '  current=$(jq -er .current_commit "$tx_dir/journal.json")' \
        '  printf "%s\n" "$current" > "$ORCHESTRATOR_ACTIVE_COMMIT_FILE"' \
        '}' \
        'maintenance_git_cleanup() {' \
        '  _fixture_log git-cleanup' \
        '  [[ ! -d $1/candidate ]] || rm -rf -- "$1/candidate"' \
        '}' \
        'snapshot_probe() {' \
        '  _fixture_log snapshot-probe' \
        '  printf '\''{"version":1,"provider":"none","coverage":{"root":false,"package_db":false,"home":false,"boot":false},"system_restorable":false,"reason":"explicitly-disabled"}\n'\''' \
        '}' \
        'snapshot_create() {' \
        '  local tx_dir=$1 provider=$2' \
        '  _fixture_log snapshot-create' \
        '  jq -n --arg provider "$provider" '\''{version:1,provider:$provider,identifier:"none",coverage:{root:false,package_db:false,home:false,boot:false},created_at:"20260901T000000Z"}'\'' > "$tx_dir/snapshot.json"' \
        '  chmod 0600 -- "$tx_dir/snapshot.json"' \
        '}' \
        'snapshot_guidance() { _fixture_log snapshot-guidance; }' \
        'maintenance_preflight() {' \
        '  local operation=$1 profile=$2 tx_dir=$3' \
        '  _fixture_log preflight' \
        '  jq -n --arg id "${tx_dir##*/}" --arg operation "$operation" --arg profile "$profile" '\''{version:1,transaction_id:$id,operation:$operation,profile:$profile,created_at:"20260901T000000Z",result:"passed",required_passed:true,checks:[],manual_intervention:[]}'\'' > "$tx_dir/preflight.json"' \
        '  chmod 0600 -- "$tx_dir/preflight.json"' \
        '  maintenance_tx_set_recovery "$tx_dir" pending none '\''{"version":1,"provider":"none","coverage":{"root":false,"package_db":false,"home":false,"boot":false},"system_restorable":false,"reason":"explicitly-disabled"}'\''' \
        '}' \
        'recovery_checkpoint_create() {' \
        '  local tx_dir=$1' \
        '  _fixture_log checkpoint-create' \
        '  mkdir -m 0700 -- "$tx_dir/checkpoint"' \
        '  printf '\''{}\n'\'' > "$tx_dir/checkpoint/checkpoint.json"' \
        '  chmod 0600 -- "$tx_dir/checkpoint/checkpoint.json"' \
        '  maintenance_journal_update "$tx_dir" '\''.recovery.configuration = "ready"'\''' \
        '}' \
        'recovery_capture_owned_state() {' \
        '  local tx_dir=$1 state' \
        '  state=$(jq -er .state "$tx_dir/journal.json")' \
        '  if [[ $state == recovering ]]; then _fixture_log recovery-owned-state; else _fixture_log owned-state; fi' \
        '  printf '\''fixture-owned-state\n'\'' > "$tx_dir/owned-after.tsv"' \
        '  chmod 0600 -- "$tx_dir/owned-after.tsv"' \
        '}' \
        'recovery_checkpoint_restore() {' \
        '  local tx_dir=$1' \
        '  _fixture_log configuration-restore' \
        '  maintenance_journal_update "$tx_dir" '\''.recovery.configuration = "recovered"'\''' \
        '}' \
        'maintenance_postflight() {' \
        '  local operation=$1 profile=$2 tx_dir=$3 passed=true result=passed' \
        '  _fixture_log postflight' \
        '  if [[ ${ORCHESTRATOR_SCENARIO:-passed} == postflight-fail || ${ORCHESTRATOR_SCENARIO:-passed} == restore-collision ]]; then passed=false; result=failed; fi' \
        '  jq -n --arg id "${tx_dir##*/}" --arg operation "$operation" --arg profile "$profile" --arg result "$result" --argjson passed "$passed" '\''{version:1,transaction_id:$id,operation:$operation,profile:$profile,live_session:true,created_at:"20260901T000000Z",result:$result,required_passed:$passed,needs_attention:false,checks:[],recommendations:[]}'\'' > "$tx_dir/postflight.json"' \
        '  chmod 0600 -- "$tx_dir/postflight.json"' \
        '  [[ $passed == true ]]' \
        '}' \
        > "$file"
}

for library in maintenance-recovery maintenance-snapshot maintenance-git \
    maintenance-postflight maintenance-preflight; do
    write_fake_maintenance_library "$FIXTURE_REPO/scripts/lib/$library.sh"
done

write_helper() {
    local path=$1 label=$2

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        "printf '%s\\n' '$label' >> \"\$ORCHESTRATOR_LOG\"" \
        > "$path"
    chmod 0755 -- "$path"
}

write_helper "$FIXTURE_REPO/scripts/install-packages.sh" helper-install-packages
write_helper "$FIXTURE_REPO/scripts/migrate-namespace.sh" helper-migrate-namespace
write_helper "$FIXTURE_REPO/scripts/repair-flatpak.sh" helper-repair-flatpak
write_helper "$FIXTURE_REPO/scripts/link-dotfiles.sh" helper-link-dotfiles
write_helper "$FIXTURE_REPO/scripts/seed-runtime.sh" helper-seed-runtime
write_helper "$FIXTURE_REPO/scripts/configure-system.sh" helper-configure-system
write_helper "$FIXTURE_REPO/dotfiles/.config/waybar/launch.sh" desktop-waybar
write_helper "$FIXTURE_REPO/dotfiles/.config/nwg-dock-hyprland/launch.sh" desktop-dock

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "auth-sudo\n" >> "$ORCHESTRATOR_LOG"' \
    'exit 0' \
    > "$FIXTURE_BIN/sudo"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ $# -eq 4 && $1 == -C && $3 == rev-parse && $4 == HEAD && -r ${ORCHESTRATOR_ACTIVE_COMMIT_FILE:-} ]]; then' \
    '  exec /usr/bin/cat -- "$ORCHESTRATOR_ACTIVE_COMMIT_FILE"' \
    'fi' \
    'exec /usr/bin/git "$@"' \
    > "$FIXTURE_BIN/git"
for command_name in hyprctl qs swaync-client; do
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "desktop-%s\n" "${0##*/}" >> "$ORCHESTRATOR_LOG"' \
        'exit 0' \
        > "$FIXTURE_BIN/$command_name"
done
chmod 0755 -- "$FIXTURE_BIN"/*

git -C "$FIXTURE_REPO" init -q -b main
git -C "$FIXTURE_REPO" config user.name 'Orchestrator Fixture'
git -C "$FIXTURE_REPO" config user.email 'orchestrator@example.invalid'
git -C "$FIXTURE_REPO" add .
git -C "$FIXTURE_REPO" commit -q -m fixture
CURRENT_COMMIT=$(git -C "$FIXTURE_REPO" rev-parse HEAD)
CHANGED_COMMIT=2222222222222222222222222222222222222222

prepare_run() {
    local name=$1 candidate=${2:-$CHANGED_COMMIT}

    CASE_ROOT="$RUN_ROOT/$name"
    CASE_HOME="$CASE_ROOT/home"
    CASE_STATE="$CASE_ROOT/state"
    CASE_RUNTIME="$CASE_ROOT/run"
    CASE_OUTPUT="$CASE_ROOT/output.log"
    mkdir -p -- "$CASE_HOME" "$CASE_STATE" "$CASE_RUNTIME"
    chmod 0700 -- "$CASE_HOME" "$CASE_STATE" "$CASE_RUNTIME"
    : > "$ORCHESTRATOR_LOG"
    printf '%s\n' "$CURRENT_COMMIT" > "$ACTIVE_COMMIT_FILE"
    ORCHESTRATOR_CANDIDATE_COMMIT=$candidate
    ORCHESTRATOR_SCENARIO=passed
    export ORCHESTRATOR_CANDIDATE_COMMIT ORCHESTRATOR_SCENARIO
    export ORCHESTRATOR_LOG ORCHESTRATOR_ACTIVE_COMMIT_FILE="$ACTIVE_COMMIT_FILE"
}

run_maintenance() {
    local expected=$1
    shift
    local actual

    set +e
    HOME="$CASE_HOME" XDG_STATE_HOME="$CASE_STATE" \
        XDG_RUNTIME_DIR="$CASE_RUNTIME" PATH="$FIXTURE_BIN:/usr/bin:/bin" \
        "$FIXTURE_REPO/scripts/maintenance.sh" "$@" > "$CASE_OUTPUT" 2>&1
    actual=$?
    set -e
    [[ $actual -eq $expected ]] || {
        sed -n '1,160p' "$CASE_OUTPUT" >&2
        fail "maintenance $* returned $actual instead of $expected"
    }
}

latest_tx() {
    find "$CASE_STATE/myhyprlandrice/transactions" -mindepth 1 -maxdepth 1 \
        -type d -name 'txn.*' -print -quit
}

assert_log_exact() {
    local expected=$1 actual

    actual=$(<"$ORCHESTRATOR_LOG")
    [[ $actual == "$expected" ]] || {
        printf 'Expected log:\n%s\nActual log:\n%s\n' "$expected" "$actual" >&2
        fail 'orchestrator order differs'
    }
}

prepare_run plan
EXPIRED_PLAN="$CASE_STATE/myhyprlandrice/transactions/txn.oldplan1"
mkdir -p -- "$EXPIRED_PLAN"
chmod 0700 -- "$CASE_STATE/myhyprlandrice" \
    "$CASE_STATE/myhyprlandrice/transactions" "$EXPIRED_PLAN"
jq -n '
    {
        version: 1,
        id: "txn.oldplan1",
        state: "preflighted",
        result: "planned"
    }
' > "$EXPIRED_PLAN/journal.json"
chmod 0600 -- "$EXPIRED_PLAN/journal.json"
touch -d '31 days ago' "$EXPIRED_PLAN/journal.json" "$EXPIRED_PLAN"
run_maintenance 0 plan dotfiles --profile desktop --snapshot none --yes
PLAN_TX=$(find "$CASE_STATE/myhyprlandrice/transactions" \
    -mindepth 1 -maxdepth 1 -type d -name 'txn.*' \
    ! -name 'txn.oldplan1' -print -quit)
jq -e '
    .state == "preflighted" and .result == "planned" and
    (.completed_stages | index("preflight")) != null and
    (.completed_stages | index("checkpoint")) == null
' "$PLAN_TX/journal.json" >/dev/null || fail 'plan mode mutated past preflight'
assert_log_exact $'git-prepare\nsnapshot-probe\npreflight\ngit-cleanup'
rg -q '^Operation: dotfiles$' "$CASE_OUTPUT" || fail 'plan omitted operation'
rg -q '^Profile: desktop$' "$CASE_OUTPUT" || fail 'plan omitted profile'
rg -q '^Candidate commit: [0-9a-f]{40}$' "$CASE_OUTPUT" || fail 'plan omitted candidate'
rg -q '^Mutable stages:' "$CASE_OUTPUT" || fail 'plan omitted exact stages'
rg -q '^Recovery coverage:' "$CASE_OUTPUT" || fail 'plan omitted recovery coverage'
[[ ! -e $CASE_HOME/.fixture-mutated ]] || fail 'plan mutated the target home'
[[ ! -e $EXPIRED_PLAN ]] || fail 'a successful plan did not prune expired plan evidence'

prepare_run dry-run
run_maintenance 0 apply dotfiles --profile desktop --snapshot none --yes --dry-run
assert_log_exact $'git-prepare\nsnapshot-probe\npreflight\ngit-cleanup'

prepare_run apply-desktop
WAYLAND_DISPLAY=wayland-fixture HYPRLAND_INSTANCE_SIGNATURE=hypr-fixture \
    run_maintenance 0 apply dotfiles --profile desktop --snapshot none --yes
APPLY_TX=$(latest_tx)
jq -e '
    .state == "committed" and .result == "success" and
    .completed_stages == [
        "preflight","checkpoint","snapshot","git-promote","packages",
        "migration","flatpak","links","seed","system-config",
        "owned-state","desktop-reload","postflight","known-good"
    ]
' "$APPLY_TX/journal.json" >/dev/null || fail 'desktop apply did not commit exact stages'
assert_log_exact $'git-prepare\nsnapshot-probe\npreflight\ncheckpoint-create\nsnapshot-create\ngit-promote\nauth-sudo\nhelper-install-packages\nhelper-migrate-namespace\nhelper-repair-flatpak\nhelper-link-dotfiles\nhelper-seed-runtime\nhelper-configure-system\nowned-state\ndesktop-hyprctl\ndesktop-waybar\ndesktop-dock\ndesktop-qs\ndesktop-swaync-client\npostflight\ngit-cleanup'
[[ $(<"$ACTIVE_COMMIT_FILE") == "$CHANGED_COMMIT" ]] || fail 'candidate was not promoted'
jq -e --arg commit "$CHANGED_COMMIT" '.commit == $commit' \
    "$CASE_STATE/myhyprlandrice/known-good.json" >/dev/null || \
    fail 'known-good did not advance after commit'
[[ $(rg -c '^auth-sudo$' "$ORCHESTRATOR_LOG") -eq 1 ]] || \
    fail 'administrator authentication was not acquired exactly once'
rg -q 'Dotfiles update committed successfully' "$CASE_OUTPUT" || \
    fail 'committed apply did not print success'

KNOWN_GOOD="$CASE_STATE/myhyprlandrice/known-good.json"
PENDING_GOOD="$CASE_STATE/myhyprlandrice/known-good.pending.json"
PENDING_DIGEST="$CASE_STATE/myhyprlandrice/known-good.pending.sha256"
cp -- "$KNOWN_GOOD" "$PENDING_GOOD"
pending_hash=$(sha256sum "$PENDING_GOOD" | cut -d' ' -f1)
printf '%s  known-good.pending.json\n' "$pending_hash" > "$PENDING_DIGEST"
chmod 0600 -- "$PENDING_GOOD" "$PENDING_DIGEST"
rm -f -- "$KNOWN_GOOD"
run_maintenance 0 status "${APPLY_TX##*/}"
jq -e --arg id "${APPLY_TX##*/}" '.transaction_id == $id' \
    "$KNOWN_GOOD" >/dev/null || fail 'status did not reconcile committed known-good state'
cp -- "$KNOWN_GOOD" "$PENDING_GOOD"
printf '%064d  known-good.pending.json\n' 0 > "$PENDING_DIGEST"
chmod 0600 -- "$PENDING_GOOD" "$PENDING_DIGEST"
known_good_hash=$(sha256sum "$KNOWN_GOOD" | cut -d' ' -f1)
run_maintenance 0 status "${APPLY_TX##*/}"
[[ $(sha256sum "$KNOWN_GOOD" | cut -d' ' -f1) == "$known_good_hash" ]] || \
    fail 'invalid pending evidence replaced the previous known-good pointer'
cp -- "$APPLY_TX/journal.json" "$CASE_ROOT/journal.backup"
jq '.stage = "fixture-private-\u001b[31m"' "$APPLY_TX/journal.json" \
    > "$CASE_ROOT/journal.invalid"
chmod 0600 -- "$CASE_ROOT/journal.invalid"
mv -- "$CASE_ROOT/journal.invalid" "$APPLY_TX/journal.json"
run_maintenance 1 status "${APPLY_TX##*/}"
! rg -Fq 'fixture-private' "$CASE_OUTPUT" || \
    fail 'status printed untrusted journal content'
mv -- "$CASE_ROOT/journal.backup" "$APPLY_TX/journal.json"

prepare_run apply-core
run_maintenance 0 apply dotfiles --profile core --snapshot none --yes
CORE_TX=$(latest_tx)
for forbidden in helper-repair-flatpak helper-configure-system desktop-hyprctl; do
    ! rg -Fxq "$forbidden" "$ORCHESTRATOR_LOG" || \
        fail "core profile ran desktop-only stage: $forbidden"
done
jq -e '
    .state == "committed" and
    (.completed_stages | index("flatpak")) == null and
    (.completed_stages | index("system-config")) == null and
    (.completed_stages | index("desktop-reload")) == null
' "$CORE_TX/journal.json" >/dev/null || fail 'core journal contains desktop-only stages'

prepare_run no-change "$CURRENT_COMMIT"
WAYLAND_DISPLAY=wayland-fixture HYPRLAND_INSTANCE_SIGNATURE=hypr-fixture \
    run_maintenance 0 apply dotfiles --profile desktop --snapshot none --yes
NO_CHANGE_TX=$(latest_tx)
for forbidden in helper-link-dotfiles desktop-hyprctl desktop-waybar desktop-dock; do
    ! rg -Fxq "$forbidden" "$ORCHESTRATOR_LOG" || \
        fail "no-change candidate ran needless stage: $forbidden"
done
jq -e '
    .state == "committed" and
    (.completed_stages | index("checkpoint")) != null and
    (.completed_stages | index("postflight")) != null and
    (.completed_stages | index("links")) == null
' "$NO_CHANGE_TX/journal.json" >/dev/null || \
    fail 'no-change update did not checkpoint and verify safely'

stage_markers=(
    'preflight:preflight'
    'checkpoint:checkpoint-create'
    'snapshot:snapshot-create'
    'git-promote:git-promote'
    'packages:helper-install-packages'
    'migration:helper-migrate-namespace'
    'flatpak:helper-repair-flatpak'
    'links:helper-link-dotfiles'
    'seed:helper-seed-runtime'
    'system-config:helper-configure-system'
    'owned-state:owned-state'
    'desktop-reload:desktop-hyprctl'
    'postflight:postflight'
    'known-good:'
)
for index in "${!stage_markers[@]}"; do
    pair=${stage_markers[$index]}
    stage=${pair%%:*}
    marker=${pair#*:}
    for position in before after; do
        prepare_run "failure-$position-$stage"
        MYHYPR_MAINTENANCE_FAIL_STAGE="$position:$stage" \
            WAYLAND_DISPLAY=wayland-fixture \
            HYPRLAND_INSTANCE_SIGNATURE=hypr-fixture \
            run_maintenance 97 apply dotfiles --profile desktop --snapshot none --yes
        FAILURE_TX=$(latest_tx)
        jq -e --arg stage "$stage" '
            (.state == "recovered" or .state == "needs-attention") and
            .result != "success" and .failure.stage == $stage
        ' "$FAILURE_TX/journal.json" >/dev/null || \
            fail "$position failure at $stage left false success"
        ! rg -q 'Dotfiles update committed successfully' "$CASE_OUTPUT" || \
            fail "$position failure at $stage printed success"
        [[ ! -e $CASE_STATE/myhyprlandrice/known-good.json ]] || \
            fail "$position failure at $stage advanced known-good"
        if [[ -n $marker ]]; then
            if [[ $position == before ]]; then
                ! rg -Fxq "$marker" "$ORCHESTRATOR_LOG" || \
                    fail "before injection ran $stage"
            else
                rg -Fxq "$marker" "$ORCHESTRATOR_LOG" || \
                    fail "after injection skipped $stage"
            fi
        elif [[ $position == after ]]; then
            jq -e '.completed_stages | index("known-good") != null' \
                "$FAILURE_TX/journal.json" >/dev/null || \
                fail 'after known-good injection was not recorded after the stage'
        fi
        for ((later = index + 1; later < ${#stage_markers[@]}; later++)); do
            later_marker=${stage_markers[$later]#*:}
            [[ -z $later_marker ]] || ! rg -Fxq "$later_marker" \
                "$ORCHESTRATOR_LOG" || \
                fail "$position failure at $stage ran later stage $later_marker"
        done
    done
done

prepare_run promote-after-write-fail
ORCHESTRATOR_SCENARIO=promote-after-write-fail
export ORCHESTRATOR_SCENARIO
run_maintenance 45 apply dotfiles --profile desktop --snapshot none --yes
PARTIAL_PROMOTE_TX=$(latest_tx)
jq -e '
    .state == "recovered" and
    (.completed_stages | index("git-promote")) == null
' "$PARTIAL_PROMOTE_TX/journal.json" >/dev/null || \
    fail 'partially promoted Git failure did not recover'
[[ $(<"$ACTIVE_COMMIT_FILE") == "$CURRENT_COMMIT" ]] || \
    fail 'recovery trusted only the missing Git stage marker'
rg -Fxq git-restore "$ORCHESTRATOR_LOG" || \
    fail 'partially promoted Git HEAD was not restored'

prepare_run postflight-failure
ORCHESTRATOR_SCENARIO=postflight-fail
export ORCHESTRATOR_SCENARIO
WAYLAND_DISPLAY=wayland-fixture HYPRLAND_INSTANCE_SIGNATURE=hypr-fixture \
    run_maintenance 1 apply dotfiles --profile desktop --snapshot none --yes
POSTFLIGHT_TX=$(latest_tx)
[[ $(<"$ACTIVE_COMMIT_FILE") == "$CURRENT_COMMIT" ]] || \
    fail 'failed postflight did not restore the previous Git commit'
jq -e '.state == "recovered" and .recovery.configuration == "recovered"' \
    "$POSTFLIGHT_TX/journal.json" >/dev/null || fail 'postflight recovery did not complete'
config_line=$(rg -n '^configuration-restore$' "$ORCHESTRATOR_LOG" | cut -d: -f1)
git_line=$(rg -n '^git-restore$' "$ORCHESTRATOR_LOG" | cut -d: -f1)
[[ -n $config_line && -n $git_line && $config_line -lt $git_line ]] || \
    fail 'recovery did not restore configuration before Git'
[[ ! -e $CASE_STATE/myhyprlandrice/known-good.json ]] || \
    fail 'failed postflight advanced known-good'

prepare_run restore-collision
ORCHESTRATOR_SCENARIO=restore-collision
export ORCHESTRATOR_SCENARIO
WAYLAND_DISPLAY=wayland-fixture HYPRLAND_INSTANCE_SIGNATURE=hypr-fixture \
    run_maintenance 1 apply dotfiles --profile desktop --snapshot none --yes
COLLISION_TX=$(latest_tx)
jq -e '.state == "needs-attention" and .result == "needs-attention"' \
    "$COLLISION_TX/journal.json" >/dev/null || fail 'restore collision was hidden'
[[ -f $COLLISION_TX/journal.json && -f $COLLISION_TX/postflight.json ]] || \
    fail 'restore collision discarded transaction evidence'

prepare_run interrupted
MYHYPR_MAINTENANCE_FAIL_STAGE='after:links' \
    MYHYPR_MAINTENANCE_FAIL_MODE=interrupt \
    WAYLAND_DISPLAY=wayland-fixture HYPRLAND_INSTANCE_SIGNATURE=hypr-fixture \
    run_maintenance 99 apply dotfiles --profile desktop --snapshot none --yes
INTERRUPTED_TX=$(latest_tx)
INTERRUPTED_ID=${INTERRUPTED_TX##*/}
jq -e '.state == "applying" and (.completed_stages | index("links")) != null' \
    "$INTERRUPTED_TX/journal.json" >/dev/null || fail 'interrupted journal was not retained'
run_maintenance 0 status "$INTERRUPTED_ID"
rg -q '^State: applying$' "$CASE_OUTPUT" || fail 'status did not discover interruption'
[[ ! -e $CASE_STATE/myhyprlandrice/known-good.json ]] || \
    fail 'status promoted a noncommitted transaction'
run_maintenance 0 recover "$INTERRUPTED_ID"
jq -e '.state == "recovered"' "$INTERRUPTED_TX/journal.json" >/dev/null || \
    fail 'interrupted transaction was not recoverable'
recovery_count=$(rg -c '^configuration-restore$' "$ORCHESTRATOR_LOG")
run_maintenance 0 recover "$INTERRUPTED_ID"
[[ $(rg -c '^configuration-restore$' "$ORCHESTRATOR_LOG") -eq $recovery_count ]] || \
    fail 'repeated recovery reran a committed recovery stage'

prepare_run lock-contention
mkdir -p -- "$CASE_RUNTIME/myhypr"
chmod 0700 -- "$CASE_RUNTIME/myhypr"
LOCK_FILE="$CASE_RUNTIME/myhypr/maintenance.lock"
LOCK_READY="$CASE_ROOT/lock-ready"
LOCK_RELEASE="$CASE_ROOT/lock-release"
mkfifo -- "$LOCK_RELEASE"
(
    exec 9>>"$LOCK_FILE"
    chmod 0600 -- "$LOCK_FILE"
    flock 9
    printf 'txn.ABCDEFGH\n' > "$LOCK_FILE"
    : > "$LOCK_READY"
    read -r _ < "$LOCK_RELEASE"
) &
LOCK_PID=$!
for _ in {1..50}; do
    [[ -e $LOCK_READY ]] && break
    sleep 0.1
done
[[ -e $LOCK_READY ]] || fail 'lock holder did not start'
run_maintenance 75 apply dotfiles --profile desktop --snapshot none --yes
printf 'release\n' > "$LOCK_RELEASE"
wait "$LOCK_PID"
[[ ! -d $CASE_STATE/myhyprlandrice/transactions ]] || \
    [[ -z $(find "$CASE_STATE/myhyprlandrice/transactions" -mindepth 1 \
        -maxdepth 1 -type d -print -quit) ]] || \
    fail 'lock contention created a transaction'

WRAPPER_ROOT="$TEST_ROOT/wrapper"
mkdir -p -- "$WRAPPER_ROOT/scripts"
cp -- "$PROJECT_ROOT/scripts/update.sh" "$WRAPPER_ROOT/scripts/update.sh"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "<%s>" "$@" > "$WRAPPER_DELEGATION_LOG"' \
    'printf "\n" >> "$WRAPPER_DELEGATION_LOG"' \
    > "$WRAPPER_ROOT/scripts/maintenance.sh"
chmod 0755 -- "$WRAPPER_ROOT/scripts/update.sh" "$WRAPPER_ROOT/scripts/maintenance.sh"
WRAPPER_DELEGATION_LOG="$TEST_ROOT/wrapper.log" \
    "$WRAPPER_ROOT/scripts/update.sh" --profile desktop --yes
[[ $(<"$TEST_ROOT/wrapper.log") == \
    '<apply><dotfiles><--profile><desktop><--yes>' ]] || \
    fail 'legacy update wrapper did not delegate exactly once'

printf 'Dotfiles maintenance is planned, journaled, recoverable, and compatible.\n'
