#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
while IFS= read -r git_variable; do
    unset "$git_variable"
done < <(git rev-parse --local-env-vars)
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
    all|staged-invalid|staged-valid|history) ;;
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
    rg -Fq 'history-private.txt' "$TEST_ROOT/history.log"
    rg -Fq 'history-unsafe.sh' "$TEST_ROOT/history.log"
fi
