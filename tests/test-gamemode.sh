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
export GAMEMODE_TEST_MARKER="$CONFIG_ROOT/myhypr/settings/gamemode-enabled"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-gamemode-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

mkdir -p -- "$FAKE_BIN" "$CONFIG_ROOT/myhypr/settings" \
    "$CONFIG_ROOT/hypr/scripts" "$CONFIG_ROOT/hypr/conf/monitors" "$CACHE_ROOT"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ ${GAMEMODE_TEST_FAIL:-0} -eq 1 && ${1:-} == eval ]]; then exit 9; fi' \
    'if [[ ${1:-} == reload && -e $GAMEMODE_TEST_MARKER ]]; then exit 10; fi' \
    'printf "hyprctl %s\n" "$*" >> "$GAMEMODE_TEST_LOG"' \
    > "$FAKE_BIN/hyprctl"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$FAKE_BIN/notify-send"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "automation %s\n" "$*" >> "$GAMEMODE_TEST_LOG"' \
    'case ${1:-} in' \
    '  --status) [[ ${GAMEMODE_AUTOMATION_RUNNING:-0} -eq 1 ]] ;;' \
    '  --stop) [[ ${GAMEMODE_AUTOMATION_STOP_FAIL:-0} -eq 0 ]] ;;' \
    '  --start) exit 0 ;;' \
    '  *) exit 2 ;;' \
    'esac' > "$CONFIG_ROOT/hypr/scripts/wallpaper-automation.sh"
chmod +x -- "$FAKE_BIN/hyprctl" "$FAKE_BIN/notify-send"
chmod +x -- "$CONFIG_ROOT/hypr/scripts/wallpaper-automation.sh"

gamemode="$REPO_ROOT/dotfiles/.config/hypr/scripts/gamemode.sh"
marker="$CONFIG_ROOT/myhypr/settings/gamemode-enabled"
activation='hyprctl eval require("conf.gamemode_state").apply()'

HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" XDG_CACHE_HOME="$CACHE_ROOT" \
    PATH="$FAKE_BIN:/usr/bin:/bin" "$gamemode"
rg -Fqx "$activation" "$GAMEMODE_TEST_LOG"
[[ -f $marker ]]

HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" XDG_CACHE_HOME="$CACHE_ROOT" \
    PATH="$FAKE_BIN:/usr/bin:/bin" "$gamemode"
rg -Fqx 'hyprctl reload' "$GAMEMODE_TEST_LOG"
[[ ! -e $marker ]]

# A running wallpaper worker is paused for gamemode and resumed only after
# the persisted gamemode marker has been removed and normal config reloaded.
: > "$GAMEMODE_TEST_LOG"
HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" XDG_CACHE_HOME="$CACHE_ROOT" \
    PATH="$FAKE_BIN:/usr/bin:/bin" GAMEMODE_AUTOMATION_RUNNING=1 "$gamemode"
rg -Fqx 'automation --stop' "$GAMEMODE_TEST_LOG"
[[ -f $marker && -f $CACHE_ROOT/myhypr/restart-wpauto ]]
HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" XDG_CACHE_HOME="$CACHE_ROOT" \
    PATH="$FAKE_BIN:/usr/bin:/bin" "$gamemode"
rg -Fqx 'automation --start' "$GAMEMODE_TEST_LOG"
[[ ! -e $marker && ! -e $CACHE_ROOT/myhypr/restart-wpauto ]]

# A failed wallpaper stop must not persist gamemode or alter the monitor
# selector, otherwise a later compositor reload could apply a partial state.
printf 'source = normal-monitor\n' > "$CONFIG_ROOT/hypr/conf/monitor.conf"
printf 'source = gaming-monitor\n' > "$CONFIG_ROOT/hypr/conf/monitors/gamemode.conf"
if HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" XDG_CACHE_HOME="$CACHE_ROOT" \
    PATH="$FAKE_BIN:/usr/bin:/bin" GAMEMODE_AUTOMATION_RUNNING=1 \
    GAMEMODE_AUTOMATION_STOP_FAIL=1 "$gamemode" 2>/dev/null; then
    printf 'Gamemode continued after wallpaper automation failed to stop.\n' >&2
    exit 1
fi
[[ $(<"$CONFIG_ROOT/hypr/conf/monitor.conf") == 'source = normal-monitor' ]]
[[ ! -e $marker && ! -e $CACHE_ROOT/myhypr/restart-wpauto ]]

# The Lua configuration load must reapply enabled gamemode and do nothing when
# disabled. This catches missing startup wiring rather than testing a dead script.
gamemode_state="$REPO_ROOT/dotfiles/.config/hypr/conf/gamemode_state.lua"
lua_test="$TEST_ROOT/test-gamemode-state.lua"
printf '%s\n' \
    'local calls = 0' \
    'hl = { config = function(value)' \
    '  calls = calls + 1' \
    '  assert(value.animations.enabled == false)' \
    '  assert(value.decoration.active_opacity == 1)' \
    '  assert(value.general.gaps_out == 0)' \
    'end }' \
    'local state = dofile(os.getenv("GAMEMODE_STATE_MODULE"))' \
    'local expected = os.getenv("GAMEMODE_EXPECTED") == "1"' \
    'assert(state.apply_persisted() == expected)' \
    'assert(calls == (expected and 1 or 0))' > "$lua_test"
rm -f -- "$marker"
: > "$GAMEMODE_TEST_LOG"
HOME="$TEST_HOME" GAMEMODE_STATE_MODULE="$gamemode_state" GAMEMODE_EXPECTED=0 \
    lua "$lua_test"
: > "$marker"
HOME="$TEST_HOME" GAMEMODE_STATE_MODULE="$gamemode_state" GAMEMODE_EXPECTED=1 \
    lua "$lua_test"
rg -Fq 'require("conf.gamemode_state").apply_persisted()' \
    "$REPO_ROOT/dotfiles/.config/hypr/hyprland.lua"
[[ ! -e $REPO_ROOT/dotfiles/.config/hypr/scripts/load-gamemode.sh ]]

rm -f -- "$marker"
if HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" XDG_CACHE_HOME="$CACHE_ROOT" \
    PATH="$FAKE_BIN:/usr/bin:/bin" GAMEMODE_TEST_FAIL=1 \
    GAMEMODE_AUTOMATION_RUNNING=1 "$gamemode"; then
    printf 'Gamemode persisted state after a rejected config update.\n' >&2
    exit 1
fi
[[ ! -e $marker ]]
[[ ! -e $CACHE_ROOT/myhypr/restart-wpauto ]]
tail -n 4 "$GAMEMODE_TEST_LOG" | rg -Fq 'automation --stop'
tail -n 4 "$GAMEMODE_TEST_LOG" | rg -Fq 'automation --start'

printf 'Gamemode uses typed config and persists only accepted state.\n'
