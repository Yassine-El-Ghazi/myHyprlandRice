#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes write literal fake-script variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-cliphist-test.XXXXXXXX")
TEST_HOME="$TEST_ROOT/home"
SETTINGS_ROOT="$TEST_HOME/.config/myhypr/settings"
FAKE_BIN="$TEST_ROOT/bin"
export CLIPHIST_TEST_LOG="$TEST_ROOT/cliphist.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-cliphist-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Clipboard launcher test failed: %s\n' "$*" >&2
    exit 1
}

mkdir -p -- "$SETTINGS_ROOT" "$FAKE_BIN"
printf 'rofi' > "$SETTINGS_ROOT/launcher"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" > "$CLIPHIST_TEST_LOG"' \
    > "$FAKE_BIN/cliphist"
chmod +x -- "$FAKE_BIN/cliphist"

HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" \
    "$REPO_ROOT/dotfiles/.config/myhypr/scripts/cliphist.sh" w || \
    fail 'a valid no-newline launcher setting stopped clipboard handling'

[[ $(<"$CLIPHIST_TEST_LOG") == wipe ]] || \
    fail 'clipboard wipe action was not reached'

mkdir -p -- "$TEST_HOME/.config/walker"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\\n" "$*" > "$CLIPHIST_TEST_LOG"' \
    > "$TEST_HOME/.config/walker/launch.sh"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\\n" "$*" > "$CLIPHIST_TEST_LOG"' > "$FAKE_BIN/elephant"
chmod +x -- "$TEST_HOME/.config/walker/launch.sh" "$FAKE_BIN/elephant"
printf walker > "$SETTINGS_ROOT/launcher"
HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" \
    "$REPO_ROOT/dotfiles/.config/myhypr/scripts/cliphist.sh" w
[[ $(<"$CLIPHIST_TEST_LOG") == 'activate clipboard;;remove_all;;' ]] || \
    fail 'Walker clear did not address the active clipboard provider'
HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" \
    "$REPO_ROOT/dotfiles/.config/myhypr/scripts/cliphist.sh" d
[[ $(<"$CLIPHIST_TEST_LOG") == '-m clipboard -H -p Delete entry: Ctrl+D' ]] || \
    fail 'Walker delete mode does not expose its delete action'
printf 'Clipboard controls address the selected backend and accept no-newline settings.\n'
