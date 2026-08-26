#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-validation-env.XXXXXXXX")
FAKE_BIN="$TEST_ROOT/bin"
export HYPRLAND_ENV_LOG="$TEST_ROOT/hyprland.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-validation-env.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Validation environment test failed: %s\n' "$*" >&2
    exit 1
}

test_resolver() {
    local fallback resolved
    # shellcheck source=scripts/lib.sh
    source "$REPO_ROOT/scripts/lib.sh"
    fallback="$TEST_ROOT/qt6/qmllint"
    mkdir -p -- "$(dirname -- "$fallback")" "$TEST_ROOT/empty-path"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fallback"
    chmod +x -- "$fallback"
    resolved=$(PATH="$TEST_ROOT/empty-path" resolve_executable qmllint "$fallback") || \
        fail 'explicit Qt 6 fallback was not resolved'
    [[ $resolved == "$fallback" ]] || fail "unexpected resolver result: $resolved"
    if PATH="$TEST_ROOT/empty-path" resolve_executable missing-command \
        "$TEST_ROOT/missing" >/dev/null; then
        fail 'resolver accepted a missing executable'
    fi
}

test_hyprland_runtime() {
    mkdir -p -- "$FAKE_BIN"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        ': "${XDG_RUNTIME_DIR:?missing XDG_RUNTIME_DIR}"' \
        '[[ -d $XDG_RUNTIME_DIR ]] || exit 71' \
        '[[ $(stat -c %a "$XDG_RUNTIME_DIR") == 700 ]] || exit 72' \
        '[[ $XDG_RUNTIME_DIR == "$HOME/runtime" ]] || exit 73' \
        'case ${FAKE_EUID:-0} in' \
        '    0) [[ " $* " == *" --i-am-really-stupid "* ]] || exit 74 ;;' \
        '    *) [[ " $* " != *" --i-am-really-stupid "* ]] || exit 76 ;;' \
        'esac' \
        'printf "%s\n" "$XDG_RUNTIME_DIR" >> "$HYPRLAND_ENV_LOG"' \
        'printf "config ok\n"' \
        > "$FAKE_BIN/Hyprland"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        '[[ "$1" == -u ]] || exit 75' \
        'printf "%s\n" "${FAKE_EUID:-0}"' \
        > "$FAKE_BIN/id"
    chmod +x -- "$FAKE_BIN/Hyprland"
    chmod +x -- "$FAKE_BIN/id"
    FAKE_EUID=0 env -u XDG_RUNTIME_DIR PATH="$FAKE_BIN:/usr/bin:/bin" \
        "$REPO_ROOT/scripts/check-hyprland.sh" >/dev/null
    [[ $(wc -l < "$HYPRLAND_ENV_LOG") -eq 56 ]] || \
        fail 'not every root Hyprland variant received the private runtime directory'
    [[ $(sort -u "$HYPRLAND_ENV_LOG" | wc -l) -eq 1 ]] || \
        fail 'Hyprland variants used inconsistent runtime directories'
    : > "$HYPRLAND_ENV_LOG"
    FAKE_EUID=1000 env -u XDG_RUNTIME_DIR PATH="$FAKE_BIN:/usr/bin:/bin" \
        "$REPO_ROOT/scripts/check-hyprland.sh" >/dev/null
    [[ $(wc -l < "$HYPRLAND_ENV_LOG") -eq 56 ]] || \
        fail 'not every non-root Hyprland variant received the private runtime directory'
}

case ${1:-all} in
    resolver) test_resolver ;;
    runtime) test_hyprland_runtime ;;
    all)
        test_resolver
        test_hyprland_runtime
        ;;
    *) fail "unknown test case: $1" ;;
esac

printf 'Validation tools and Hyprland runtime isolation passed.\n'
