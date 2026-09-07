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

mkdir -p -- "$CONFIG_ROOT/myhypr/settings" "$CONFIG_ROOT/rofi" "$FAKE_BIN"
printf 'rofi' > "$CONFIG_ROOT/myhypr/settings/launcher"
payload='$(touch '"$TEST_ROOT"'/description-was-executed)'
jq -n --arg payload "$payload" '[
    {modmask: 64, key: "RETURN", keycode: 0, description: "Open terminal"},
    {modmask: 12, key: "T", keycode: 0, description: "Open theme selector"},
    {modmask: 68, key: "K", keycode: 0, description: "Show keybindings"},
    {modmask: 65, key: "X", keycode: 0, description: $payload},
    {modmask: 64, key: "H", keycode: 0, description: ""}
]' > "$TEST_ROOT/binds.json"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" > "$KEYBINDING_VIEWER_LOG"' \
    'cat > "${KEYBINDING_VIEWER_LOG}.input"' \
    > "$FAKE_BIN/rofi"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    '[[ $* == "-j binds" ]] || exit 64' \
    'cat "$KEYBINDING_VIEWER_JSON"' \
    > "$FAKE_BIN/hyprctl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/sleep"
chmod +x -- "$FAKE_BIN/rofi" "$FAKE_BIN/hyprctl" "$FAKE_BIN/sleep"

HOME="$TEST_HOME" KEYBINDING_VIEWER_JSON="$TEST_ROOT/binds.json" \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    "$REPO_ROOT/dotfiles/.config/hypr/scripts/keybindings.sh" >/dev/null || \
    fail 'valid live Lua bindings stopped the keybinding viewer'

[[ -f $KEYBINDING_VIEWER_LOG ]] || fail 'Rofi keybinding viewer was not opened'
rg -Fq -- '-dmenu -i -markup -eh 2 -replace -p Keybinds' \
    "$KEYBINDING_VIEWER_LOG" || fail 'Rofi received unexpected viewer arguments'
rg -Fq $'SUPER + RETURN\rOpen terminal' "${KEYBINDING_VIEWER_LOG}.input" || \
    fail 'the terminal shortcut was not rendered from live metadata'
rg -Fq $'CTRL + ALT + T\rOpen theme selector' "${KEYBINDING_VIEWER_LOG}.input" || \
    fail 'the modifier mask was not decoded'
rg -Fq $'SUPER + CTRL + K\rShow keybindings' "${KEYBINDING_VIEWER_LOG}.input" || \
    fail 'the primary modifier was not displayed first'
rg -Fq -- "$payload" "${KEYBINDING_VIEWER_LOG}.input" || \
    fail 'a literal description was not preserved'
[[ ! -e $TEST_ROOT/description-was-executed ]] || \
    fail 'a shortcut description was executed as shell code'
if rg -Fq 'SUPER + H' "${KEYBINDING_VIEWER_LOG}.input"; then
    fail 'an undescribed internal bind was shown'
fi

printf '{broken json\n' > "$TEST_ROOT/binds.json"
rm -f -- "$KEYBINDING_VIEWER_LOG" "${KEYBINDING_VIEWER_LOG}.input"
if HOME="$TEST_HOME" KEYBINDING_VIEWER_JSON="$TEST_ROOT/binds.json" \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    "$REPO_ROOT/dotfiles/.config/hypr/scripts/keybindings.sh" >/dev/null 2>&1; then
    fail 'invalid live binding JSON was accepted'
fi
[[ ! -e $KEYBINDING_VIEWER_LOG ]] || \
    fail 'the viewer opened after live binding validation failed'

printf 'Keybinding viewer renders described live Lua bindings as inert data.\n'
