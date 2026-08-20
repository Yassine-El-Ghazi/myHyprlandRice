#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes write literal mock-script variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-focus-test.XXXXXXXX")
FAKE_BIN="$TEST_ROOT/bin"
export FOCUS_TEST_LOG="$TEST_ROOT/commands.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-focus-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

mkdir -p -- "$FAKE_BIN"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ $* == "-j clients" ]]; then' \
    '  printf "%s\n" '\''[{"title":"Safe","address":"0xaaa","workspace":{"id":1},"mapped":true,"hidden":false},{"title":"Untrusted --HYPRCTL_INFO--0xdead","address":"0xbbb","workspace":{"id":2},"mapped":true,"hidden":false}]'\''' \
    'else' \
    '  printf "hyprctl %s\n" "$*" >> "$FOCUS_TEST_LOG"' \
    'fi' > "$FAKE_BIN/hyprctl"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'cat >/dev/null' \
    'printf "1\n"' > "$FAKE_BIN/rofi"
chmod +x -- "$FAKE_BIN/hyprctl" "$FAKE_BIN/rofi"

HOME="$TEST_ROOT/user-root" PATH="$FAKE_BIN:/usr/bin:/bin" \
    "$REPO_ROOT/dotfiles/.config/myhypr/scripts/focus.sh"
rg -q '^hyprctl dispatch focuswindow address:0xbbb$' "$FOCUS_TEST_LOG"

printf 'Window selection treats titles as display-only data.\n'
