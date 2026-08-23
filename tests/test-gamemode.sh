#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-gamemode-test.XXXXXXXX")
FAKE_BIN="$TEST_ROOT/bin"
TEST_HOME="$TEST_ROOT/home"
CONFIG_ROOT="$TEST_HOME/.config"
CACHE_ROOT="$TEST_HOME/.cache"
export GAMEMODE_TEST_LOG="$TEST_ROOT/hyprctl.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-gamemode-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

mkdir -p -- "$FAKE_BIN" "$CONFIG_ROOT/myhypr/settings" "$CACHE_ROOT"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ ${GAMEMODE_TEST_FAIL:-0} -eq 1 && ${1:-} == eval ]]; then exit 9; fi' \
    'printf "hyprctl %s\n" "$*" >> "$GAMEMODE_TEST_LOG"' \
    > "$FAKE_BIN/hyprctl"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$FAKE_BIN/notify-send"
chmod +x -- "$FAKE_BIN/hyprctl" "$FAKE_BIN/notify-send"

gamemode="$REPO_ROOT/dotfiles/.config/hypr/scripts/gamemode.sh"
loader="$REPO_ROOT/dotfiles/.config/hypr/scripts/load-gamemode.sh"
marker="$CONFIG_ROOT/myhypr/settings/gamemode-enabled"
activation='hyprctl eval hl.config({ animations = { enabled = false }, decoration = { shadow = { enabled = false }, blur = { enabled = false }, active_opacity = 1, inactive_opacity = 1, fullscreen_opacity = 1, rounding = 0 }, general = { gaps_in = 0, gaps_out = 0, border_size = 1 } })'
startup='hyprctl eval hl.config({ animations = { enabled = false }, decoration = { shadow = { enabled = false }, blur = { enabled = false }, rounding = 0 }, general = { gaps_in = 0, gaps_out = 0, border_size = 1 } })'

HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" XDG_CACHE_HOME="$CACHE_ROOT" \
    PATH="$FAKE_BIN:/usr/bin:/bin" "$gamemode"
rg -Fqx "$activation" "$GAMEMODE_TEST_LOG"
[[ -f $marker ]]

HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" XDG_CACHE_HOME="$CACHE_ROOT" \
    PATH="$FAKE_BIN:/usr/bin:/bin" "$gamemode"
rg -Fqx 'hyprctl reload' "$GAMEMODE_TEST_LOG"
[[ ! -e $marker ]]

: > "$marker"
: > "$GAMEMODE_TEST_LOG"
HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" XDG_CACHE_HOME="$CACHE_ROOT" \
    PATH="$FAKE_BIN:/usr/bin:/bin" "$loader"
rg -Fqx "$startup" "$GAMEMODE_TEST_LOG"

rm -f -- "$marker"
if HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" XDG_CACHE_HOME="$CACHE_ROOT" \
    PATH="$FAKE_BIN:/usr/bin:/bin" GAMEMODE_TEST_FAIL=1 "$gamemode"; then
    printf 'Gamemode persisted state after a rejected config update.\n' >&2
    exit 1
fi
[[ ! -e $marker ]]

printf 'Gamemode uses typed config and persists only accepted state.\n'
