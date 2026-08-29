#!/usr/bin/env bash
# shellcheck disable=SC2016  # Fixture scripts intentionally contain literal variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-recovery-test.XXXXXXXX")
REAL_GIT=$(command -v git)
FAKE_REPO="$TEST_ROOT/repo"
TEST_HOME="$TEST_ROOT/home"
FAKE_BIN="$TEST_ROOT/bin"
SERVICE_STATE="$TEST_ROOT/service-state"
SERVICE_LOG="$TEST_ROOT/service-actions.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-recovery-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Maintenance recovery test failed: %s\n' "$*" >&2
    exit 1
}

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"
# shellcheck source=scripts/lib/maintenance-transaction.sh
source "$REPO_ROOT/scripts/lib/maintenance-transaction.sh"
# shellcheck source=scripts/lib/maintenance-recovery.sh
source "$REPO_ROOT/scripts/lib/maintenance-recovery.sh"

mkdir -p -- \
    "$FAKE_REPO/defaults/.config/myhypr/settings" \
    "$FAKE_REPO/defaults/.config/ignored" \
    "$FAKE_REPO/defaults/.local/bin" \
    "$FAKE_REPO/dotfiles/.config/app" \
    "$FAKE_REPO/dotfiles/.config/folded" \
    "$TEST_HOME/.config/myhypr/settings" \
    "$TEST_HOME/.config/hypr" \
    "$TEST_HOME/.config/app" \
    "$TEST_HOME/.local/bin" \
    "$FAKE_BIN" "$SERVICE_STATE"
chmod 0700 -- "$TEST_HOME" "$SERVICE_STATE"

printf 'default example\n' > "$FAKE_REPO/defaults/.config/myhypr/settings/example"
printf 'default new\n' > "$FAKE_REPO/defaults/.config/myhypr/settings/new"
printf '#!/usr/bin/env bash\nprintf "original tool\\n"\n' \
    > "$FAKE_REPO/defaults/.local/bin/recovery-tool"
printf 'tracked app\n' > "$FAKE_REPO/dotfiles/.config/app/config"
printf 'tracked folded\n' > "$FAKE_REPO/dotfiles/.config/folded/item"
ln -s -- "$TEST_ROOT/not-part-of-defaults" \
    "$FAKE_REPO/defaults/.config/ignored/not-a-regular-file"

git -C "$FAKE_REPO" init -q
git -C "$FAKE_REPO" config user.name 'Recovery Fixture'
git -C "$FAKE_REPO" config user.email 'fixture@example.invalid'
git -C "$FAKE_REPO" add -A
git -C "$FAKE_REPO" commit -qm 'fixture recovery state'
current_commit=$(git -C "$FAKE_REPO" rev-parse HEAD)
candidate_commit=$(printf '2%.0s' {1..40})

printf 'original\n' > "$TEST_HOME/.config/myhypr/settings/example"
printf 'keep\n' > "$TEST_HOME/.config/myhypr/private"
printf 'private selector\n' > "$TEST_HOME/.config/hypr/local.lua"
printf '#!/usr/bin/env bash\nprintf "original tool\\n"\n' \
    > "$TEST_HOME/.local/bin/recovery-tool"
chmod 0755 "$TEST_HOME/.local/bin/recovery-tool"
original_app_target="$FAKE_REPO/dotfiles/.config/app/config"
ln -s -- "$original_app_target" "$TEST_HOME/.config/app/config"
original_folded="$TEST_ROOT/original-folded"
mkdir -p -- "$original_folded"
printf 'outside folded state\n' > "$original_folded/state"
ln -s -- "$original_folded" "$TEST_HOME/.config/folded"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    '[[ ${1:-} == --user ]] || exit 64' \
    'action=${2:-}' \
    'unit=${3:-}' \
    '[[ $unit =~ ^(myhypr-session\.target|elephant\.service|walker\.service)$ ]] || exit 64' \
    'case $action in' \
    '    is-active)' \
    '        if [[ -e $RECOVERY_SERVICE_STATE/$unit.active ]]; then' \
    '            printf "active\n"' \
    '            exit 0' \
    '        fi' \
    '        printf "inactive\n"' \
    '        exit 3' \
    '        ;;' \
    '    start)' \
    '        : > "$RECOVERY_SERVICE_STATE/$unit.active"' \
    '        printf "start %s\n" "$unit" >> "$RECOVERY_SERVICE_LOG"' \
    '        ;;' \
    '    stop)' \
    '        rm -f -- "$RECOVERY_SERVICE_STATE/$unit.active"' \
    '        printf "stop %s\n" "$unit" >> "$RECOVERY_SERVICE_LOG"' \
    '        ;;' \
    '    *) exit 64 ;;' \
    'esac' > "$FAKE_BIN/systemctl"
chmod +x -- "$FAKE_BIN/systemctl"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'if [[ ${RECOVERY_FAIL_LS_FILES:-0} == 1 && ${1:-} == -C && ${3:-} == ls-files ]]; then' \
    '    exit 74' \
    'fi' \
    'exec "$RECOVERY_REAL_GIT" "$@"' > "$FAKE_BIN/git"
chmod +x -- "$FAKE_BIN/git"
touch "$SERVICE_STATE/myhypr-session.target.active"
touch "$SERVICE_STATE/walker.service.active"
touch "$SERVICE_STATE/unrelated.service.active"
export RECOVERY_SERVICE_STATE="$SERVICE_STATE"
export RECOVERY_SERVICE_LOG="$SERVICE_LOG"
export RECOVERY_REAL_GIT="$REAL_GIT"
PATH="$FAKE_BIN:/usr/bin:/bin"
export PATH

HOME="$TEST_HOME"
XDG_STATE_HOME="$TEST_ROOT/state"
XDG_RUNTIME_DIR="$TEST_ROOT/run"
export HOME XDG_STATE_HOME XDG_RUNTIME_DIR
mkdir -p -- "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
chmod 0700 -- "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"

maintenance_paths_init
maintenance_lock_acquire
maintenance_tx_begin dotfiles desktop "$current_commit" "$candidate_commit"
tx_dir=$MYHYPR_TRANSACTION_DIR
tx_id=${tx_dir##*/}

if recovery_validate_relative /absolute/path || \
    recovery_validate_relative '../outside' || \
    recovery_validate_relative $'.config/bad\tpath' || \
    recovery_validate_relative $'.config/bad\npath'; then
    fail 'an unsafe recovery-relative path was accepted'
fi

ln -s -- "$TEST_HOME" "$TEST_ROOT/home-link"
if recovery_checkpoint_create "$tx_dir" "$FAKE_REPO" "$TEST_ROOT/home-link"; then
    fail 'a symlink target home was accepted'
fi
[[ ! -e $tx_dir/checkpoint ]] || fail 'a rejected checkpoint left partial state'

if RECOVERY_FAIL_LS_FILES=1 \
    recovery_checkpoint_create "$tx_dir" "$FAKE_REPO" "$TEST_HOME"; then
    fail 'a failed tracked-file inventory produced a partial checkpoint'
fi
[[ ! -e $tx_dir/checkpoint ]] || fail 'a failed tracked-file inventory left partial state'

recovery_checkpoint_create "$tx_dir" "$FAKE_REPO" "$TEST_HOME" || \
    fail 'a valid universal checkpoint could not be created'
checkpoint="$tx_dir/checkpoint"
for required in runtime manifest.tsv missing.txt managed-links.tsv file-modes.tsv \
    user-services.tsv checkpoint.json; do
    [[ -e $checkpoint/$required || -L $checkpoint/$required ]] || \
        fail "checkpoint artifact is missing: $required"
done
while IFS= read -r mode; do
    [[ $mode == 700 ]] || fail "checkpoint directory has mode $mode instead of 700"
done < <(find "$checkpoint" -type d -printf '%m\n')
while IFS= read -r mode; do
    [[ $mode == 600 ]] || fail "checkpoint file has mode $mode instead of 600"
done < <(find "$checkpoint" -type f -printf '%m\n')

jq -e --arg id "$tx_id" --arg commit "$current_commit" '
    .version == 1 and .transaction_id == $id and
    .target_scope == "target-home" and
    (.target_home_digest | test("^[0-9a-f]{64}$")) and
    .current_commit == $commit and
    (.manifest_sha256 | test("^[0-9a-f]{64}$")) and
    (.created_at | test("^[0-9]{8}T[0-9]{6}Z$"))
' "$checkpoint/checkpoint.json" >/dev/null || fail 'checkpoint binding metadata is invalid'
if rg -Fq "$TEST_ROOT" "$checkpoint/checkpoint.json"; then
    fail 'checkpoint metadata disclosed an absolute fixture path'
fi
jq -e '.recovery.configuration == "ready"' "$tx_dir/journal.json" >/dev/null || \
    fail 'the journal does not report universal recovery readiness'

rg -Fq $'file\t.config/myhypr/settings/example\t' "$checkpoint/manifest.tsv" || \
    fail 'the existing default-backed runtime file is outside the checkpoint scope'
rg -Fq $'missing\t.config/myhypr/settings/new\t-' "$checkpoint/manifest.tsv" || \
    fail 'the absent default-backed runtime file is outside the checkpoint scope'
rg -Fq $'file\t.config/hypr/local.lua\t' "$checkpoint/manifest.tsv" || \
    fail 'the private local selector is outside the checkpoint scope'
rg -Fq $'symlink\t.config/app/config\t' "$checkpoint/manifest.tsv" || \
    fail 'the managed Stow leaf is outside the checkpoint scope'
rg -Fq $'symlink\t.config/folded\t' "$checkpoint/manifest.tsv" || \
    fail 'the unexpected Stow parent conflict is outside the checkpoint scope'
if rg -Fq '.config/folded/item' "$checkpoint/manifest.tsv"; then
    fail 'scope discovery followed an unexpected parent symlink'
fi
if rg -Fq 'not-a-regular-file' "$checkpoint/manifest.tsv"; then
    fail 'scope discovery followed a symlink below defaults'
fi
if rg -Fq '.config/myhypr/private' "$checkpoint/manifest.tsv"; then
    fail 'an unrelated private neighbor entered the recovery scope'
fi
rg -Fxq '.config/myhypr/settings/new' "$checkpoint/missing.txt" || \
    fail 'the missing-path inventory omitted the absent runtime file'
rg -Fq $'.config/app/config\t' "$checkpoint/managed-links.tsv" || \
    fail 'the original managed-link topology was not recorded'
rg -Fxq $'.local/bin/recovery-tool\t755' "$checkpoint/file-modes.tsv" || \
    fail 'the original executable mode was not recorded privately'
[[ $(<"$checkpoint/runtime/.config/myhypr/settings/example") == original ]] || \
    fail 'the runtime backup did not preserve original content'
jq -e --arg digest "$(sha256sum "$checkpoint/manifest.tsv" | cut -d' ' -f1)" \
    '.manifest_sha256 == $digest' "$checkpoint/checkpoint.json" >/dev/null || \
    fail 'the checkpoint manifest digest does not match its artifact'
jq -e -R -s 'contains("RECOVERY_SERVICE_STATE") | not' \
    "$checkpoint/user-services.tsv" >/dev/null || \
    fail 'service evidence captured arbitrary environment data'
for unit in myhypr-session.target elephant.service walker.service; do
    rg -q "^${unit//./\\.}\\t(active|inactive)\\tpending$" \
        "$checkpoint/user-services.tsv" || fail "bounded service state missing for $unit"
done

printf 'generated\n' > "$TEST_HOME/.config/myhypr/settings/example"
printf 'generated new\n' > "$TEST_HOME/.config/myhypr/settings/new"
printf 'generated selector\n' > "$TEST_HOME/.config/hypr/local.lua"
printf '#!/usr/bin/env bash\nprintf "generated tool\\n"\n' \
    > "$TEST_HOME/.local/bin/recovery-tool"
chmod 0755 "$TEST_HOME/.local/bin/recovery-tool"
candidate_app_target="$FAKE_REPO/candidate-app-config"
printf 'candidate app\n' > "$candidate_app_target"
rm -- "$TEST_HOME/.config/app/config"
ln -s -- "$candidate_app_target" "$TEST_HOME/.config/app/config"
touch "$SERVICE_STATE/elephant.service.active"

recovery_capture_owned_state "$tx_dir" "$FAKE_REPO" "$TEST_HOME" || \
    fail 'post-apply ownership state could not be captured'
[[ -f $tx_dir/owned-after.tsv && $(stat -c %a "$tx_dir/owned-after.tsv") == 600 ]] || \
    fail 'post-apply ownership state is missing or non-private'
rg -Fq $'file\t.config/myhypr/settings/example\t' "$tx_dir/owned-after.tsv" || \
    fail 'post-apply generated content was not recorded'
rg -q '^elephant\.service\tinactive\tactive$' "$checkpoint/user-services.tsv" || \
    fail 'the transaction-owned service transition was not recorded'

cp -- "$tx_dir/owned-after.tsv" "$TEST_ROOT/owned-after.valid.tsv"
tampered_app_target="$FAKE_REPO/tampered-app-config"
printf 'tampered app\n' > "$tampered_app_target"
rm -- "$TEST_HOME/.config/app/config"
ln -s -- "$tampered_app_target" "$TEST_HOME/.config/app/config"
awk -F '\t' -v OFS='\t' -v target="$tampered_app_target" '
    $2 == ".config/app/config" { $3 = target }
    { print }
' "$tx_dir/owned-after.tsv" > "$tx_dir/.owned-after.tampered"
chmod 0600 "$tx_dir/.owned-after.tampered"
mv -- "$tx_dir/.owned-after.tampered" "$tx_dir/owned-after.tsv"
if recovery_checkpoint_restore "$tx_dir" "$FAKE_REPO" "$TEST_HOME"; then
    fail 'tampered post-apply ownership evidence was accepted'
fi
[[ -L $TEST_HOME/.config/app/config && \
    $(readlink -- "$TEST_HOME/.config/app/config") == "$tampered_app_target" ]] || \
    fail 'tampered ownership evidence caused a target mutation'
mv -- "$TEST_ROOT/owned-after.valid.tsv" "$tx_dir/owned-after.tsv"
rm -- "$TEST_HOME/.config/app/config"
ln -s -- "$candidate_app_target" "$TEST_HOME/.config/app/config"

runtime_app_backup="$TEST_ROOT/runtime-app-backup"
mv -- "$checkpoint/runtime/.config/app" "$runtime_app_backup"
ln -s -- "$runtime_app_backup" "$checkpoint/runtime/.config/app"
if recovery_checkpoint_restore "$tx_dir" "$FAKE_REPO" "$TEST_HOME"; then
    fail 'a symlink parent inside checkpoint runtime data was followed'
fi
[[ -L $TEST_HOME/.config/app/config && \
    $(readlink -- "$TEST_HOME/.config/app/config") == "$candidate_app_target" ]] || \
    fail 'a substituted checkpoint runtime parent caused a target mutation'
rm -- "$checkpoint/runtime/.config/app"
mv -- "$runtime_app_backup" "$checkpoint/runtime/.config/app"

recovery_checkpoint_restore "$tx_dir" "$FAKE_REPO" "$TEST_HOME" || \
    fail 'a collision-free checkpoint restore failed'
[[ $(<"$TEST_HOME/.config/myhypr/settings/example") == original ]] || \
    fail 'original runtime content was not restored'
[[ ! -e $TEST_HOME/.config/myhypr/settings/new ]] || \
    fail 'a transaction-created runtime file was not removed'
[[ $(<"$TEST_HOME/.config/hypr/local.lua") == 'private selector' ]] || \
    fail 'the private local selector was not restored'
rg -Fq 'original tool' "$TEST_HOME/.local/bin/recovery-tool" || \
    fail 'the original executable content was not restored'
[[ $(stat -c %a "$TEST_HOME/.local/bin/recovery-tool") == 755 ]] || \
    fail 'the original executable mode was not restored'
[[ -L $TEST_HOME/.config/app/config && \
    $(readlink -- "$TEST_HOME/.config/app/config") == "$original_app_target" ]] || \
    fail 'the original managed Stow link was not restored'
[[ -L $TEST_HOME/.config/folded && \
    $(readlink -- "$TEST_HOME/.config/folded") == "$original_folded" ]] || \
    fail 'the unexpected parent-conflict topology changed'
[[ $(<"$TEST_HOME/.config/myhypr/private") == keep ]] || \
    fail 'an unrelated private neighbor was modified'
[[ ! -e $SERVICE_STATE/elephant.service.active ]] || \
    fail 'the transaction-owned service state was not restored'
[[ -e $SERVICE_STATE/myhypr-session.target.active && \
    -e $SERVICE_STATE/walker.service.active && \
    -e $SERVICE_STATE/unrelated.service.active ]] || \
    fail 'an unrelated/prior service state was modified'
[[ $(<"$SERVICE_LOG") == 'stop elephant.service' ]] || \
    fail 'service recovery invoked an unexpected action'
jq -e '.recovery.configuration == "recovered"' "$tx_dir/journal.json" >/dev/null || \
    fail 'successful configuration recovery was not journaled'

recovery_checkpoint_restore "$tx_dir" "$FAKE_REPO" "$TEST_HOME" || \
    fail 'a second restore was not an idempotent success'
[[ $(<"$SERVICE_LOG") == 'stop elephant.service' ]] || \
    fail 'an idempotent restore repeated a service mutation'

printf 'user changed after apply\n' > "$TEST_HOME/.config/myhypr/settings/example"
set +e
recovery_checkpoint_restore "$tx_dir" "$FAKE_REPO" "$TEST_HOME"
collision_status=$?
set -e
[[ $collision_status -ne 0 ]] || fail 'a post-apply ownership collision was overwritten'
[[ $(<"$TEST_HOME/.config/myhypr/settings/example") == 'user changed after apply' ]] || \
    fail 'a post-apply user change was not preserved'
rg -Fxq $'.config/myhypr/settings/example\tcontent-changed' \
    "$tx_dir/needs-attention.txt" || fail 'the collision evidence is missing or unbounded'
if rg -Fq "$TEST_ROOT" "$tx_dir/needs-attention.txt"; then
    fail 'collision evidence disclosed an absolute target path'
fi
jq -e '.recovery.configuration == "needs-attention"' \
    "$tx_dir/journal.json" >/dev/null || fail 'the recovery collision was not journaled'

other_dir="$MAINTENANCE_TX_ROOT/txn.CROSS001"
mkdir -m 0700 -- "$other_dir"
jq --arg id txn.CROSS001 '.id = $id' "$tx_dir/journal.json" \
    > "$other_dir/journal.json"
chmod 0600 "$other_dir/journal.json"
cp -a -- "$checkpoint" "$other_dir/checkpoint"
cp -a -- "$tx_dir/owned-after.tsv" "$other_dir/owned-after.tsv"
jq --arg id txn.CROSS001 '.transaction_id = $id | .manifest_sha256 = ("0" * 64)' \
    "$other_dir/checkpoint/checkpoint.json" > "$other_dir/checkpoint/.checkpoint.json"
chmod 0600 "$other_dir/checkpoint/.checkpoint.json"
mv -- "$other_dir/checkpoint/.checkpoint.json" "$other_dir/checkpoint/checkpoint.json"
MYHYPR_TRANSACTION_DIR=$other_dir
export MYHYPR_TRANSACTION_DIR
cross_digest=$(sha256sum "$TEST_HOME/.config/myhypr/settings/example" | cut -d' ' -f1)
if recovery_checkpoint_restore "$other_dir" "$FAKE_REPO" "$TEST_HOME"; then
    fail 'a checkpoint with a different transaction/hash binding was accepted'
fi
[[ $(sha256sum "$TEST_HOME/.config/myhypr/settings/example" | cut -d' ' -f1) == \
    "$cross_digest" ]] || fail 'cross-transaction recovery modified target state'

printf 'Universal recovery is scoped, collision-safe, private, and idempotent.\n'
