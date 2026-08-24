#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes write literal fake-script variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-welcome-test.XXXXXXXX")
TEST_HOME="$TEST_ROOT/home"
CONFIG_ROOT="$TEST_HOME/.config"
FAKE_BIN="$TEST_ROOT/bin"
export WELCOME_TEST_LOG="$TEST_ROOT/welcome.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-welcome-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Welcome setting test failed: %s\n' "$*" >&2
    exit 1
}

mkdir -p -- "$CONFIG_ROOT/myhypr/settings" "$CONFIG_ROOT/myhypr/bin" "$FAKE_BIN"
printf 'True' > "$CONFIG_ROOT/myhypr/settings/welcome-on-startup"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" > "$WELCOME_TEST_LOG"' \
    > "$CONFIG_ROOT/myhypr/bin/myhyprctl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/sleep"
chmod +x -- "$CONFIG_ROOT/myhypr/bin/myhyprctl" "$FAKE_BIN/sleep"

HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" PATH="$FAKE_BIN:/usr/bin:/bin" \
    "$REPO_ROOT/dotfiles/.config/myhypr/scripts/myhypr-autostart.sh"

[[ -f $WELCOME_TEST_LOG ]] || \
    fail 'a valid no-newline True setting did not open the welcome panel'
[[ $(<"$WELCOME_TEST_LOG") == welcome ]] || \
    fail 'a valid no-newline True setting did not open the welcome panel'

printf 'Welcome startup accepts a no-newline setting.\n'
