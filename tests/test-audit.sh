#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
while IFS= read -r git_variable; do
    unset "$git_variable"
done < <(git rev-parse --local-env-vars)
REAL_GIT=$(command -v git)
REAL_MKTEMP=$(command -v mktemp)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-audit-test.XXXXXXXX")
cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-audit-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT
fail() {
    printf 'Audit behavior test failed: %s\n' "$*" >&2
    exit 1
}

setup_repo() {
    local target=$1
    mkdir -p -- "$target/scripts" "$target/bin"
    cp -- "$REPO_ROOT/scripts/audit.sh" "$REPO_ROOT/scripts/lib.sh" "$target/scripts/"
    if [[ -f $REPO_ROOT/scripts/audit-large-files.sh ]]; then
        cp -- "$REPO_ROOT/scripts/audit-large-files.sh" "$target/scripts/"
        chmod +x -- "$target/scripts/audit-large-files.sh"
    fi
    printf '%s\n' '#!/usr/bin/env bash' 'exit 2' > "$target/bin/gitleaks"
    chmod +x -- "$target/bin/gitleaks"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        'if rg -q '\''^BROKEN$'\'' fixture.txt; then' \
        '    printf '\''fixture is broken\n'\'' >&2' \
        '    exit 9' \
        'fi' > "$target/scripts/check.sh"
    chmod +x -- "$target/scripts/check.sh"
    printf 'SAFE\n' > "$target/fixture.txt"
    git -C "$target" init -q
    git -C "$target" add -A
    git -C "$target" -c user.name='Audit Fixture' \
        -c user.email='audit@example.invalid' commit -qm baseline
}

case_name=${1:-all}
case $case_name in
    all|staged-invalid|staged-valid|history|hook-environment|setup-mktemp|\
        setup-checkout|setup-cd|setup-init|setup-add) ;;
    *) fail "unknown case: $case_name" ;;
esac

if [[ $case_name == all || $case_name == staged-invalid ]]; then
    repo_a="$TEST_ROOT/staged-invalid"
    setup_repo "$repo_a"

    # Staged BROKEN, worktree SAFE => staged audit must fail.
    printf 'BROKEN\n' > "$repo_a/fixture.txt"
    git -C "$repo_a" add fixture.txt
    printf 'SAFE\n' > "$repo_a/fixture.txt"
    if PATH="$repo_a/bin:/usr/bin:/bin" "$repo_a/scripts/audit.sh" --staged; then
        fail 'invalid staged content was hidden by a valid worktree repair'
    fi
fi

if [[ $case_name == all || $case_name == staged-valid ]]; then
    repo_b="$TEST_ROOT/staged-valid"
    setup_repo "$repo_b"

    # Staged SAFE, worktree BROKEN => staged audit must pass.
    printf 'SAFE\n' > "$repo_b/fixture.txt"
    printf 'staged audit trigger\n' > "$repo_b/staged-marker.txt"
    git -C "$repo_b" add fixture.txt
    git -C "$repo_b" add staged-marker.txt
    printf 'BROKEN\n' > "$repo_b/fixture.txt"
    PATH="$repo_b/bin:/usr/bin:/bin" "$repo_b/scripts/audit.sh" --staged || \
        fail 'valid staged content was rejected because of an unstaged edit'
fi

if [[ $case_name == all || $case_name == history ]]; then
    repo_history="$TEST_ROOT/history"
    setup_repo "$repo_history"
    private_value='/home/'
    private_value+='history-fixture-user'
    unsafe_value='chmod 77'
    unsafe_value+='7 historical-file'
    printf '%s\n' "$private_value" > "$repo_history/history-private.txt"
    printf '%s\n' "$unsafe_value" > "$repo_history/history-unsafe.sh"
    git -C "$repo_history" add history-private.txt history-unsafe.sh
    git -C "$repo_history" -c user.name='Audit Fixture' \
        -c user.email='audit@example.invalid' commit -qm 'add historical findings'
    printf 'removed\n' > "$repo_history/history-private.txt"
    printf 'removed\n' > "$repo_history/history-unsafe.sh"
    git -C "$repo_history" add history-private.txt history-unsafe.sh
    git -C "$repo_history" -c user.name='Audit Fixture' \
        -c user.email='audit@example.invalid' commit -qm 'remove historical findings'
    if PATH="$repo_history/bin:/usr/bin:/bin" \
        "$repo_history/scripts/audit.sh" --history >"$TEST_ROOT/history.log" 2>&1; then
        fail 'history-only privacy findings were missed'
    fi
    rg -Fq 'Machine-specific absolute home path exists in Git history: history-private.txt' \
        "$TEST_ROOT/history.log" || fail 'history home-path category warning was missing'
    rg -Fq 'Unsafe dotfiles pattern exists in Git history: history-unsafe.sh' \
        "$TEST_ROOT/history.log" || fail 'history unsafe-pattern category warning was missing'
    if rg -Fq "$private_value" "$TEST_ROOT/history.log"; then
        fail 'history audit disclosed matched private content'
    fi
    if rg -Fq "$unsafe_value" "$TEST_ROOT/history.log"; then
        fail 'history audit disclosed matched unsafe content'
    fi
fi

if [[ $case_name == all || $case_name == hook-environment ]]; then
    repo_hook="$TEST_ROOT/hook-environment"
    setup_repo "$repo_hook"
    printf 'index snapshot\n' > "$repo_hook/staged-only.txt"
    git -C "$repo_hook" add staged-only.txt
    printf 'worktree edit\n' > "$repo_hook/staged-only.txt"

    outer_head=$(git -C "$repo_hook" rev-parse HEAD)
    outer_index=$(git -C "$repo_hook" write-tree)
    outer_blob=$(git -C "$repo_hook" rev-parse :staged-only.txt)
    PATH="$repo_hook/bin:/usr/bin:/bin" \
        GIT_DIR="$repo_hook/.git" GIT_WORK_TREE="$repo_hook" \
        GIT_INDEX_FILE="$repo_hook/.git/index" \
        "$repo_hook/scripts/audit.sh" --staged || \
        fail 'staged audit failed under hook-local Git variables'
    [[ $(git -C "$repo_hook" rev-parse HEAD) == "$outer_head" ]] || \
        fail 'staged audit changed the outer repository HEAD'
    [[ $(git -C "$repo_hook" write-tree) == "$outer_index" ]] || \
        fail 'staged audit changed the outer repository index'
    [[ $(git -C "$repo_hook" rev-parse :staged-only.txt) == "$outer_blob" ]] || \
        fail 'staged audit changed the outer repository staged blob'
fi

run_setup_failure_case() {
    local step=$1
    local repo="$TEST_ROOT/setup-$step"
    local setup_log="$TEST_ROOT/setup-$step.commands"
    local missing_snapshot="${TMPDIR:-/tmp}/myhypr-audit-index.missing-$step-$$"
    local injected_step=$step
    local status

    [[ $step != checkout ]] || injected_step=checkout-index

    setup_repo "$repo"
    printf 'staged audit trigger\n' > "$repo/staged-marker.txt"
    git -C "$repo" add staged-marker.txt
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        'step=' \
        'case " $* " in' \
        '    *" checkout-index "*) step=checkout-index ;;' \
        '    *" init "*) step=init ;;' \
        '    *" add "*) step=add ;;' \
        'esac' \
        'if [[ -n $step ]]; then' \
        '    printf '\''%s\n'\'' "$step" >> "$AUDIT_SETUP_LOG"' \
        'fi' \
        'if [[ $AUDIT_FAIL_STEP == "$step" ]]; then' \
        '    exit 42' \
        'fi' \
        'if [[ $AUDIT_FAIL_STEP == mktemp && $step == checkout-index ]]; then' \
        '    exit 43' \
        'fi' \
        'if [[ $AUDIT_FAIL_STEP == cd && $step == checkout-index ]]; then' \
        '    exit 0' \
        'fi' \
        'exec "$AUDIT_REAL_GIT" "$@"' > "$repo/bin/git"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        'case " $* " in' \
        '    *myhypr-audit-index*)' \
        '        case $AUDIT_FAIL_STEP in' \
        '            mktemp) exit 42 ;;' \
        '            cd) printf '\''%s\n'\'' "$AUDIT_MISSING_SNAPSHOT"; exit 0 ;;' \
        '        esac' \
        '        ;;' \
        'esac' \
        'exec "$AUDIT_REAL_MKTEMP" "$@"' > "$repo/bin/mktemp"
    chmod +x -- "$repo/bin/git" "$repo/bin/mktemp"

    set +e
    PATH="$repo/bin:/usr/bin:/bin" \
        AUDIT_FAIL_STEP="$injected_step" AUDIT_SETUP_LOG="$setup_log" \
        AUDIT_MISSING_SNAPSHOT="$missing_snapshot" \
        AUDIT_REAL_GIT="$REAL_GIT" AUDIT_REAL_MKTEMP="$REAL_MKTEMP" \
        "$repo/scripts/audit.sh" --staged >/dev/null 2>&1
    status=$?
    set -e
    [[ $status -ne 0 ]] || fail "$step setup failure was accepted"

    case $step in
        mktemp)
            [[ ! -s $setup_log ]] || fail 'snapshot export ran after mktemp failed'
            ;;
        checkout|cd)
            if rg -q '^(init|add)$' "$setup_log"; then
                fail "snapshot repository setup continued after $step failed"
            fi
            ;;
        init)
            if rg -q '^add$' "$setup_log"; then
                fail 'snapshot index setup continued after init failed'
            fi
            ;;
    esac
}

for setup_step in mktemp checkout cd init add; do
    if [[ $case_name == all || $case_name == setup-$setup_step ]]; then
        run_setup_failure_case "$setup_step"
    fi
done
