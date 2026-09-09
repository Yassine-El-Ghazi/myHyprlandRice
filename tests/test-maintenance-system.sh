#!/usr/bin/env bash
# shellcheck disable=SC2016  # Fixture scripts intentionally contain literal variables.
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-system-maintenance.XXXXXXXX")
FIXTURE_REPO="$TEST_ROOT/repository"
BASE_BIN="$TEST_ROOT/base-bin"
RUN_ROOT="$TEST_ROOT/runs"
COMMAND_LOG="$TEST_ROOT/commands.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-system-maintenance.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'System maintenance test failed: %s\n' "$*" >&2
    exit 1
}

[[ -x $PROJECT_ROOT/scripts/maintenance.sh ]] || \
    fail 'scripts/maintenance.sh is missing'

mkdir -p -- "$FIXTURE_REPO/scripts/lib" "$FIXTURE_REPO/dotfiles/.config/myhypr/scripts" \
    "$BASE_BIN" "$RUN_ROOT"
cp -- "$PROJECT_ROOT/scripts/maintenance.sh" "$FIXTURE_REPO/scripts/maintenance.sh"
cp -- "$PROJECT_ROOT/scripts/repair-flatpak.sh" "$FIXTURE_REPO/scripts/repair-flatpak.sh"
cp -- "$PROJECT_ROOT/scripts/lib.sh" "$FIXTURE_REPO/scripts/lib.sh"
cp -- "$PROJECT_ROOT/scripts/lib/maintenance-transaction.sh" \
    "$FIXTURE_REPO/scripts/lib/maintenance-transaction.sh"
cp -- "$PROJECT_ROOT/scripts/lib/maintenance-status.sh" \
    "$FIXTURE_REPO/scripts/lib/maintenance-status.sh"
cp -- "$PROJECT_ROOT/dotfiles/.config/myhypr/scripts/installupdates.sh" \
    "$FIXTURE_REPO/dotfiles/.config/myhypr/scripts/installupdates.sh"

write_fake_maintenance_library() {
    local file=$1

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        '[[ ${_MYHYPR_SYSTEM_FIXTURE_LOADED:-0} == 1 ]] && return 0' \
        '_MYHYPR_SYSTEM_FIXTURE_LOADED=1' \
        '_system_log() { printf "%s\n" "$1" >> "$SYSTEM_TEST_COMMAND_LOG"; }' \
        'maintenance_git_prepare() { _system_log unexpected-git-prepare; return 97; }' \
        'maintenance_git_promote() { _system_log unexpected-git-promote; return 97; }' \
        'maintenance_git_restore_previous() { _system_log unexpected-git-restore; return 97; }' \
        'maintenance_git_cleanup() { _system_log unexpected-git-cleanup; return 97; }' \
        'snapshot_probe() {' \
        '  _system_log snapshot-probe' \
        '  printf '\''{"version":1,"provider":"none","coverage":{"root":false,"package_db":false,"home":false,"boot":false},"system_restorable":false,"reason":"explicitly-disabled"}\n'\''' \
        '}' \
        'snapshot_create() {' \
        '  local tx_dir=$1' \
        '  _system_log snapshot-create' \
        '  jq -n '\''{version:1,provider:"none",identifier:"none",coverage:{root:false,package_db:false,home:false,boot:false},created_at:"20260903T000000Z"}'\'' > "$tx_dir/snapshot.json"' \
        '  chmod 0600 -- "$tx_dir/snapshot.json"' \
        '}' \
        'snapshot_guidance() { _system_log snapshot-guidance; }' \
        'maintenance_preflight() {' \
        '  local operation=$1 profile=$2 tx_dir=$3' \
        '  _system_log preflight' \
        '  command -v pacman >/dev/null 2>&1 || return 69' \
        '  jq -n --arg id "${tx_dir##*/}" --arg operation "$operation" --arg profile "$profile" '\''{version:1,transaction_id:$id,operation:$operation,profile:$profile,created_at:"20260903T000000Z",result:"passed",required_passed:true,checks:[],manual_intervention:[]}'\'' > "$tx_dir/preflight.json"' \
        '  chmod 0600 -- "$tx_dir/preflight.json"' \
        '  maintenance_tx_set_recovery "$tx_dir" pending none '\''{"version":1,"provider":"none","coverage":{"root":false,"package_db":false,"home":false,"boot":false},"system_restorable":false,"reason":"explicitly-disabled"}'\''' \
        '}' \
        'recovery_checkpoint_create() {' \
        '  local tx_dir=$1' \
        '  _system_log checkpoint-create' \
        '  mkdir -m 0700 -- "$tx_dir/checkpoint"' \
        '  printf '\''{}\n'\'' > "$tx_dir/checkpoint/checkpoint.json"' \
        '  chmod 0600 -- "$tx_dir/checkpoint/checkpoint.json"' \
        '  maintenance_journal_update "$tx_dir" '\''.recovery.configuration = "ready"'\''' \
        '}' \
        'recovery_capture_owned_state() {' \
        '  local tx_dir=$1 state' \
        '  state=$(jq -er .state "$tx_dir/journal.json")' \
        '  if [[ $state == recovering ]]; then _system_log recovery-owned-state; else _system_log owned-state; fi' \
        '  printf '\''fixture-owned-state\n'\'' > "$tx_dir/owned-after.tsv"' \
        '  chmod 0600 -- "$tx_dir/owned-after.tsv"' \
        '}' \
        'recovery_checkpoint_restore() {' \
        '  local tx_dir=$1' \
        '  _system_log configuration-restore' \
        '  maintenance_journal_update "$tx_dir" '\''.recovery.configuration = "recovered"'\''' \
        '}' \
        'maintenance_postflight() {' \
        '  local operation=$1 profile=$2 tx_dir=$3' \
        '  _system_log postflight' \
        '  jq -n --arg id "${tx_dir##*/}" --arg operation "$operation" --arg profile "$profile" '\''{version:1,transaction_id:$id,operation:$operation,profile:$profile,live_session:false,created_at:"20260903T000000Z",result:"passed",required_passed:true,needs_attention:false,checks:[],recommendations:[]}'\'' > "$tx_dir/postflight.json"' \
        '  chmod 0600 -- "$tx_dir/postflight.json"' \
        '}' \
        > "$file"
}

for library in maintenance-recovery maintenance-snapshot maintenance-git \
    maintenance-postflight maintenance-preflight; do
    write_fake_maintenance_library "$FIXTURE_REPO/scripts/lib/$library.sh"
done

for command_name in bash cat chmod cut date dirname find flock grep head id jq kill \
    mkdir mktemp mv readlink realpath rm sed sha256sum sleep sort stat tail tee \
    timeout tr wc awk git; do
    ln -s -- "/usr/bin/$command_name" "$BASE_BIN/$command_name"
done

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "checkupdates\n" >> "$SYSTEM_TEST_COMMAND_LOG"' \
    '[[ ${SYSTEM_TEST_QUERY_FAIL:-0} == 0 ]] || exit 43' \
    'printf "%s\n" "linux 1 -> 2" "mesa 1 -> 2"' \
    > "$BASE_BIN/checkupdates"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'name=${0##*/}' \
    'if [[ ${1:-} == -Qua ]]; then' \
    '  printf "%s %s\n" "$name" "$*" >> "$SYSTEM_TEST_COMMAND_LOG"' \
    '  printf "%s\n" "fixture-aur 1 -> 2"' \
    '  exit 0' \
    'fi' \
    'printf "%s %s\n" "$name" "$*" >> "$SYSTEM_TEST_COMMAND_LOG"' \
    'printf "%s\n" "$SYSTEM_TEST_PACKAGE_PAYLOAD"' \
    '[[ ${SYSTEM_TEST_PACKAGE_FAIL:-0} == 0 ]] || exit 42' \
    > "$BASE_BIN/aur-helper"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "pacman %s\n" "$*" >> "$SYSTEM_TEST_COMMAND_LOG"' \
    'if [[ " $* " == *" -Syu "* ]]; then' \
    '  printf "%s\n" "$SYSTEM_TEST_PACKAGE_PAYLOAD"' \
    '  [[ ${SYSTEM_TEST_PACKAGE_FAIL:-0} == 0 ]] || exit 42' \
    'fi' \
    > "$BASE_BIN/pacman"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ ${1:-} == -v || ( ${1:-} == -n && ${2:-} == -v ) ]]; then' \
    '  printf "auth %s\n" "$*" >> "$SYSTEM_TEST_COMMAND_LOG"' \
    '  exit 0' \
    'fi' \
    'printf "sudo %s\n" "$*" >> "$SYSTEM_TEST_COMMAND_LOG"' \
    'exec "$@"' \
    > "$BASE_BIN/sudo"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'scope=user' \
    '[[ " $* " != *" --system "* ]] || scope=system' \
    'if [[ $scope == user ]]; then remotes=$SYSTEM_TEST_USER_REMOTES; refs=$SYSTEM_TEST_USER_REFS; else remotes=$SYSTEM_TEST_SYSTEM_REMOTES; refs=$SYSTEM_TEST_SYSTEM_REFS; fi' \
    'printf "flatpak %s\n" "$*" >> "$SYSTEM_TEST_COMMAND_LOG"' \
    'case " $* " in' \
    '  *" remotes "*) command cat -- "$remotes" ;;' \
    '  *" list "*) command cat -- "$refs" ;;' \
    '  *" remote-delete "*)' \
    '    sed -i '\''/^ml4w-repo$/d'\'' "$remotes"' \
    '    ;;' \
    '  *" update "*) ;;' \
    '  *) exit 64 ;;' \
    'esac' \
    > "$BASE_BIN/flatpak"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" /etc/example.pacnew' \
    > "$BASE_BIN/pacdiff"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "fixture security notice"' \
    > "$BASE_BIN/arch-audit"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$BASE_BIN/informant"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$BASE_BIN/needrestart"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$BASE_BIN/checkrebuild"
chmod 0755 -- "$BASE_BIN/checkupdates" "$BASE_BIN/aur-helper" \
    "$BASE_BIN/pacman" "$BASE_BIN/sudo" "$BASE_BIN/flatpak" \
    "$BASE_BIN/pacdiff" "$BASE_BIN/arch-audit" "$BASE_BIN/informant" \
    "$BASE_BIN/needrestart" "$BASE_BIN/checkrebuild"

git -C "$FIXTURE_REPO" init -q -b main
git -C "$FIXTURE_REPO" config user.name 'System Maintenance Fixture'
git -C "$FIXTURE_REPO" config user.email 'system-maintenance@example.invalid'
git -C "$FIXTURE_REPO" add .
git -C "$FIXTURE_REPO" commit -q -m fixture

private_value='synthetic-private-'
private_value+='credential'
uri_credential='fixture-user:fixture-pass'
PACKAGE_PAYLOAD=$(printf '\033[31mupgrade output\033[0m\npassword=%s\nhttps://%s@example.invalid/repository' \
    "$private_value" "$uri_credential")

prepare_run() {
    local name=$1 helper=${2-paru} user_remotes=${3-flathub}
    local system_remotes=${4-}

    CASE_ROOT="$RUN_ROOT/$name"
    CASE_HOME="$CASE_ROOT/home"
    CASE_STATE="$CASE_ROOT/state"
    CASE_RUNTIME="$CASE_ROOT/run"
    CASE_BIN="$CASE_ROOT/bin"
    CASE_OUTPUT="$CASE_ROOT/output.log"
    USER_REMOTES="$CASE_ROOT/user-remotes"
    SYSTEM_REMOTES="$CASE_ROOT/system-remotes"
    USER_REFS="$CASE_ROOT/user-refs"
    SYSTEM_REFS="$CASE_ROOT/system-refs"
    mkdir -p -- "$CASE_HOME" "$CASE_STATE" "$CASE_RUNTIME" "$CASE_BIN"
    chmod 0700 -- "$CASE_HOME" "$CASE_STATE" "$CASE_RUNTIME" "$CASE_BIN"
    for command_path in "$BASE_BIN"/*; do
        ln -s -- "$command_path" "$CASE_BIN/${command_path##*/}"
    done
    case $helper in
        paru|yay) ln -s -- "$BASE_BIN/aur-helper" "$CASE_BIN/$helper" ;;
        pacman) ;;
        *) fail "invalid fixture helper: $helper" ;;
    esac
    printf '%s\n' "$user_remotes" | sed '/^$/d' > "$USER_REMOTES"
    printf '%s\n' "$system_remotes" | sed '/^$/d' > "$SYSTEM_REMOTES"
    : > "$USER_REFS"
    : > "$SYSTEM_REFS"
    : > "$COMMAND_LOG"
    SYSTEM_TEST_PACKAGE_FAIL=0
    SYSTEM_TEST_QUERY_FAIL=0
    export SYSTEM_TEST_PACKAGE_FAIL SYSTEM_TEST_QUERY_FAIL
    export SYSTEM_TEST_COMMAND_LOG="$COMMAND_LOG"
    export SYSTEM_TEST_PACKAGE_PAYLOAD="$PACKAGE_PAYLOAD"
    export SYSTEM_TEST_USER_REMOTES="$USER_REMOTES"
    export SYSTEM_TEST_SYSTEM_REMOTES="$SYSTEM_REMOTES"
    export SYSTEM_TEST_USER_REFS="$USER_REFS"
    export SYSTEM_TEST_SYSTEM_REFS="$SYSTEM_REFS"
}

run_maintenance() {
    local expected=$1 actual
    shift

    set +e
    HOME="$CASE_HOME" XDG_STATE_HOME="$CASE_STATE" \
        XDG_RUNTIME_DIR="$CASE_RUNTIME" PATH="$CASE_BIN" \
        "$FIXTURE_REPO/scripts/maintenance.sh" "$@" \
        </dev/null > "$CASE_OUTPUT" 2>&1
    actual=$?
    set -e
    [[ $actual -eq $expected ]] || {
        sed -n '1,180p' "$CASE_OUTPUT" >&2
        fail "maintenance $* returned $actual instead of $expected"
    }
}

latest_tx() {
    find "$CASE_STATE/myhyprlandrice/transactions" -mindepth 1 -maxdepth 1 \
        -type d -name 'txn.*' -print -quit
}

assert_no_mutation() {
    if rg -q '(^| )(paru|yay|pacman).* -Syu|remote-delete|update .* -y|auth ' \
        "$COMMAND_LOG"; then
        fail 'system plan executed a mutating or authentication command'
    fi
}

prepare_run plan paru flathub ml4w-repo
run_maintenance 0 plan system --snapshot none --yes
PLAN_TX=$(latest_tx)
jq -e '
    .state == "preflighted" and .result == "planned" and
    (.completed_stages | index("preflight")) != null and
    (.completed_stages | index("checkpoint")) == null
' "$PLAN_TX/journal.json" >/dev/null || fail 'system plan mutated past preflight'
jq -e '
    .version == 1 and .official.status == "passed" and .official.count == 2 and
    .aur.status == "passed" and .aur.helper == "paru" and .aur.count == 1 and
    .flatpak.user_remotes == 1 and .flatpak.system_remotes == 1 and
    .flatpak.stale_system == true and
    .config_merges.pacnew == 1 and
    .optional_checks.needrestart == "available" and
    .optional_checks.checkrebuild == "available" and
    .notices.security.status == "passed" and
    .reboot_sensitive_classes == ["graphics-stack","kernel"]
' "$PLAN_TX/system-plan.json" >/dev/null || fail 'bounded system plan is incomplete'
[[ $(stat -c %a -- "$PLAN_TX/system-plan.json") == 600 ]] || \
    fail 'system plan is not private'
rg -q '^Operation: system$' "$CASE_OUTPUT" || fail 'system plan omitted operation'
rg -q '^Package updates: repository=2,aur=1' "$CASE_OUTPUT" || \
    fail 'system plan omitted package counts'
rg -q '^Mutable stages: checkpoint,snapshot,packages,flatpak,owned-state,postflight,known-good$' \
    "$CASE_OUTPUT" || fail 'system plan omitted exact stages'
assert_no_mutation

run_apply_case() {
    local helper=$1 expected_command=$2

    prepare_run "apply-$helper" "$helper" '' ''
    run_maintenance 0 apply system --snapshot none --yes
    APPLY_TX=$(latest_tx)
    jq -e '
        .state == "committed" and .result == "success" and
        .completed_stages == ["preflight","checkpoint","snapshot","packages",
            "flatpak","owned-state","postflight","known-good"]
    ' "$APPLY_TX/journal.json" >/dev/null || fail "$helper apply did not commit"
    rg -Fxq "$expected_command" "$COMMAND_LOG" || \
        fail "$helper package command differs"
    [[ $(rg -c '^auth -n -v$' "$COMMAND_LOG") -eq 1 ]] || \
        fail "$helper apply did not authenticate exactly once"
    if rg -q '^flatpak .* update ' "$COMMAND_LOG"; then
        fail "$helper apply updated Flatpak without a remote"
    fi
    rg -q 'System update committed successfully' "$CASE_OUTPUT" || \
        fail "$helper apply omitted committed success"
}

run_apply_case paru 'paru --sudoloop --useask -Syu'
run_apply_case yay 'yay --sudoloop --answerclean None --answerdiff None -Syu'
run_apply_case pacman 'pacman -Syu'

prepare_run package-fail paru flathub ''
SYSTEM_TEST_PACKAGE_FAIL=1
export SYSTEM_TEST_PACKAGE_FAIL
run_maintenance 42 apply system --snapshot none --yes
FAILED_TX=$(latest_tx)
jq -e '.state == "recovered" and .result != "success" and .failure.stage == "packages"' \
    "$FAILED_TX/journal.json" >/dev/null || fail 'package failure was hidden'
! rg -q '^flatpak .* (remote-delete|update) ' "$COMMAND_LOG" || \
    fail 'Flatpak mutation continued after package failure'
[[ ! -e $CASE_STATE/myhyprlandrice/known-good.json ]] || \
    fail 'package failure advanced known-good'
! rg -q 'System update committed successfully' "$CASE_OUTPUT" || \
    fail 'package failure printed success'
[[ -f $FAILED_TX/logs/packages.log && \
    $(stat -c %a -- "$FAILED_TX/logs/packages.log") == 600 ]] || \
    fail 'private package log is missing or has unsafe permissions'
for filtered in "$FAILED_TX/logs/packages.log" "$CASE_OUTPUT"; do
    ! rg -Fq "$private_value" "$filtered" || fail 'package output leaked a credential value'
    ! rg -Fq "$uri_credential" "$filtered" || fail 'package output leaked URI userinfo'
    rg -Fq '[REDACTED]' "$filtered" || fail 'package output omitted redaction marker'
    ! LC_ALL=C rg -q $'\033' "$filtered" || fail 'package output retained ANSI controls'
done

prepare_run flatpak paru $'flathub\nml4w-repo' $'flathub-system\nml4w-repo'
run_maintenance 0 apply system --snapshot none --yes
rg -Fxq 'flatpak --user remote-delete ml4w-repo' "$COMMAND_LOG" || \
    fail 'unused user legacy remote was not removed'
rg -Fxq 'sudo flatpak --system remote-delete ml4w-repo' "$COMMAND_LOG" || \
    fail 'system legacy remote did not reuse sudo'
rg -Fxq 'flatpak --user update -y' "$COMMAND_LOG" || \
    fail 'user Flatpak remotes were not updated'
rg -Fxq 'sudo flatpak --system update -y' "$COMMAND_LOG" || \
    fail 'system Flatpak remotes were not updated through sudo'
[[ $(rg -c '^auth -n -v$' "$COMMAND_LOG") -eq 1 ]] || \
    fail 'Flatpak work acquired another authentication session'

prepare_run blocked-legacy paru ml4w-repo ''
printf 'ml4w-repo\n' > "$USER_REFS"
run_maintenance 1 apply system --snapshot none --yes
BLOCKED_TX=$(latest_tx)
jq -e '.state == "recovered" and .failure.stage == "flatpak"' \
    "$BLOCKED_TX/journal.json" >/dev/null || fail 'legacy refs did not block safely'
! rg -Fxq 'flatpak --user update -y' "$COMMAND_LOG" || \
    fail 'Flatpak updated after blocked legacy migration'

prepare_run no-pacman paru '' ''
rm -f -- "$CASE_BIN/pacman"
run_maintenance 69 plan system --snapshot none --yes
NO_PACMAN_TX=$(latest_tx)
jq -e '(.completed_stages | index("checkpoint")) == null and .result != "success"' \
    "$NO_PACMAN_TX/journal.json" >/dev/null || \
    fail 'missing pacman reached mutation or success'

WRAPPER_ROOT="$TEST_ROOT/wrapper"
WRAPPER_BIN="$WRAPPER_ROOT/bin"
WRAPPER_HOME="$WRAPPER_ROOT/home"
WRAPPER_LOG="$WRAPPER_ROOT/delegation.log"
mkdir -p -- "$WRAPPER_ROOT/dotfiles/.config/myhypr/scripts" "$WRAPPER_ROOT/scripts" \
    "$WRAPPER_BIN" "$WRAPPER_HOME"
cp -- "$PROJECT_ROOT/dotfiles/.config/myhypr/scripts/installupdates.sh" \
    "$WRAPPER_ROOT/dotfiles/.config/myhypr/scripts/installupdates.sh"
for command_name in bash dirname readlink; do
    ln -s -- "/usr/bin/$command_name" "$WRAPPER_BIN/$command_name"
done
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$WRAPPER_BIN/gum"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$WRAPPER_BIN/pkill"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "<%s>" "$@" > "$SYSTEM_WRAPPER_LOG"' \
    'printf "\n" >> "$SYSTEM_WRAPPER_LOG"' \
    'exit "${SYSTEM_WRAPPER_STATUS:-0}"' \
    > "$WRAPPER_ROOT/scripts/update-system.sh"
chmod 0755 -- "$WRAPPER_BIN/gum" "$WRAPPER_BIN/pkill" \
    "$WRAPPER_ROOT/scripts/update-system.sh" \
    "$WRAPPER_ROOT/dotfiles/.config/myhypr/scripts/installupdates.sh"
SYSTEM_WRAPPER_LOG="$WRAPPER_LOG" SYSTEM_WRAPPER_STATUS=0 HOME="$WRAPPER_HOME" \
    PATH="$WRAPPER_BIN" \
    "$WRAPPER_ROOT/dotfiles/.config/myhypr/scripts/installupdates.sh" \
    > "$WRAPPER_ROOT/success.log" 2>&1
[[ $(<"$WRAPPER_LOG") == '<>' ]] || \
    fail 'graphical updater did not delegate exactly once'
rg -q 'All updates completed successfully' "$WRAPPER_ROOT/success.log" || \
    fail 'graphical updater omitted successful presentation'
set +e
SYSTEM_WRAPPER_LOG="$WRAPPER_LOG" SYSTEM_WRAPPER_STATUS=42 HOME="$WRAPPER_HOME" \
    PATH="$WRAPPER_BIN" \
    "$WRAPPER_ROOT/dotfiles/.config/myhypr/scripts/installupdates.sh" \
    > "$WRAPPER_ROOT/failure.log" 2>&1
wrapper_status=$?
set -e
[[ $wrapper_status -eq 42 ]] || fail 'graphical updater hid the transaction status'
! rg -q 'All updates completed successfully' "$WRAPPER_ROOT/failure.log" || \
    fail 'graphical updater printed false success'
rg -Fq 'package-manager output' "$WRAPPER_ROOT/failure.log" || \
    fail 'graphical updater omitted failure guidance'
if rg -q 'maintenance.sh|snapshot|recovery state' "$WRAPPER_ROOT/failure.log"; then
    fail 'everyday updater still displays transaction recovery instructions'
fi
if rg -n '(paru|yay|pacman)[[:space:]].*-Syu|flatpak[[:space:]]+update' \
    "$PROJECT_ROOT/dotfiles/.config/myhypr/scripts/installupdates.sh"; then
    fail 'graphical updater still executes package managers directly'
fi

printf 'System maintenance is planned, ordered, redacted, and presentation-only.\n'
