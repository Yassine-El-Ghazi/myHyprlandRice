#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes write literal fake-script variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-launcher-test.XXXXXXXX")
TEST_HOME="$TEST_ROOT/home"
SETTINGS_ROOT="$TEST_HOME/.config/myhypr/settings"
FAKE_BIN="$TEST_ROOT/bin"
export LAUNCHER_TEST_LOG="$TEST_ROOT/launcher.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-launcher-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Launcher test failed: %s\n' "$*" >&2
    exit 1
}

mkdir -p -- "$SETTINGS_ROOT" "$FAKE_BIN"
printf 'rofi' > "$SETTINGS_ROOT/launcher"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" > "$LAUNCHER_TEST_LOG"' \
    > "$FAKE_BIN/rofi"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKE_BIN/pgrep"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/pkill"
chmod +x -- "$FAKE_BIN/rofi" "$FAKE_BIN/pgrep" "$FAKE_BIN/pkill"

HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" \
    "$REPO_ROOT/dotfiles/.config/hypr/scripts/launcher.sh" || \
    fail 'a valid setting without a trailing newline was rejected'

[[ -f $LAUNCHER_TEST_LOG ]] || fail 'Rofi was not launched'
[[ $(<"$LAUNCHER_TEST_LOG") == '-show drun -replace -i' ]] || \
    fail "unexpected Rofi arguments: $(<"$LAUNCHER_TEST_LOG")"

printf 'Launcher accepts a valid setting without a trailing newline.\n'
