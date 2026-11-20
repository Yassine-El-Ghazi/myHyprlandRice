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
    local qt6 qt5 resolved
    # shellcheck source=scripts/lib.sh
    source "$REPO_ROOT/scripts/lib.sh"
    qt6="$TEST_ROOT/qt6/qmllint"
    qt5="$TEST_ROOT/qt5/qmllint"
    mkdir -p -- "${qt6%/*}" "${qt5%/*}"
    printf '#!/bin/bash\nprintf "qmllint 6.12.0\\n"\n' > "$qt6"
    printf '#!/bin/bash\nprintf "qmllint 1.0\\n"\n' > "$qt5"
    chmod +x -- "$qt6" "$qt5"
    resolved=$(PATH="${qt5%/*}" resolve_qt6_qmllint qmllint "$qt6") || \
        fail 'Qt 6 was not resolved after encountering Qt 5 on PATH'
    [[ $resolved == "$qt6" ]] || fail "unexpected resolver result: $resolved"
    resolved=$(PATH="${qt6%/*}" resolve_qt6_qmllint qmllint) || \
        fail 'Qt 6 was not resolved on PATH'
    [[ $resolved == "$qt6" ]] || fail "unexpected resolver result: $resolved"
    if PATH="${qt5%/*}" resolve_qt6_qmllint "$TEST_ROOT/missing" qmllint >/dev/null; then
        fail 'resolver accepted a non-Qt 6 executable'
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

test_per_file_syntax() {
    local valid="$TEST_ROOT/valid.sh"
    local invalid="$TEST_ROOT/invalid.sh"
    printf 'true\n' > "$valid"
    printf 'if\n' > "$invalid"

    "$REPO_ROOT/scripts/check-syntax-files.sh" bash "$valid" >/dev/null
    if "$REPO_ROOT/scripts/check-syntax-files.sh" bash "$valid" "$invalid" \
        >/dev/null 2>&1; then
        fail 'syntax validation ignored a malformed file after the first input'
    fi
}

case ${1:-all} in
    resolver) test_resolver ;;
    runtime) test_hyprland_runtime ;;
    syntax) test_per_file_syntax ;;
    all)
        test_resolver
        test_hyprland_runtime
        test_per_file_syntax
        ;;
    *) fail "unknown test case: $1" ;;
esac

printf 'Validation tools and Hyprland runtime isolation passed.\n'
