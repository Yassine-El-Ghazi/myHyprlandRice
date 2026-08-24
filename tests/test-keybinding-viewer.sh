#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes write literal fake-script variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-keybinding-viewer.XXXXXXXX")
TEST_HOME="$TEST_ROOT/home"
CONFIG_ROOT="$TEST_HOME/.config"
FAKE_BIN="$TEST_ROOT/bin"
export KEYBINDING_VIEWER_LOG="$TEST_ROOT/rofi.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-keybinding-viewer.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Keybinding viewer test failed: %s\n' "$*" >&2
    exit 1
}

mkdir -p -- \
    "$CONFIG_ROOT/myhypr/settings" "$CONFIG_ROOT/hypr/conf/keybindings" \
    "$CONFIG_ROOT/rofi" "$FAKE_BIN"
printf 'rofi' > "$CONFIG_ROOT/myhypr/settings/launcher"
printf '%s\n' 'source = ~/.config/hypr/conf/keybindings/default.conf' \
    > "$CONFIG_ROOT/hypr/conf/keybinding.conf"
printf '%s\n' 'bind = SUPER, RETURN, exec, kitty # Open terminal' \
    > "$CONFIG_ROOT/hypr/conf/keybindings/default.conf"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" > "$KEYBINDING_VIEWER_LOG"' \
    > "$FAKE_BIN/rofi"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/sleep"
chmod +x -- "$FAKE_BIN/rofi" "$FAKE_BIN/sleep"

HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" \
    "$REPO_ROOT/dotfiles/.config/hypr/scripts/keybindings.sh" >/dev/null || \
    fail 'a valid no-newline launcher setting stopped the keybinding viewer'

[[ -f $KEYBINDING_VIEWER_LOG ]] || fail 'Rofi keybinding viewer was not opened'
rg -Fq -- '-dmenu -i -markup -eh 2 -replace -p Keybinds' \
    "$KEYBINDING_VIEWER_LOG" || fail 'Rofi received unexpected viewer arguments'

printf 'Keybinding viewer accepts a no-newline launcher setting.\n'
