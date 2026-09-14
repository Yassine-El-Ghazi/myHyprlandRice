#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-power-test.XXXXXXXX")
TEST_HOME="$TEST_ROOT/home with space"
FAKE_BIN="$TEST_ROOT/bin"
TEST_LOG="$TEST_ROOT/actions.log"
POWER_SCRIPT="$REPO_ROOT/dotfiles/.config/hypr/scripts/power.sh"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-power-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Power action test failed: %s\n' "$*" >&2
    exit 1
}

mkdir -p -- "$FAKE_BIN" "$TEST_HOME/.config/myhypr"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "hyprshutdown" >> "$POWER_TEST_LOG"' \
    'printf " <%s>" "$@" >> "$POWER_TEST_LOG"' \
    'printf "\n" >> "$POWER_TEST_LOG"' > "$FAKE_BIN/hyprshutdown"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "systemctl" >> "$POWER_TEST_LOG"' \
    'printf " <%s>" "$@" >> "$POWER_TEST_LOG"' \
    'printf "\n" >> "$POWER_TEST_LOG"' > "$FAKE_BIN/systemctl"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "listeners" >> "$POWER_TEST_LOG"' \
    'printf " <%s>" "$@" >> "$POWER_TEST_LOG"' \
    'printf "\n" >> "$POWER_TEST_LOG"' > "$TEST_HOME/.config/myhypr/listeners.sh"
chmod +x -- "$FAKE_BIN/hyprshutdown" "$FAKE_BIN/systemctl" \
    "$TEST_HOME/.config/myhypr/listeners.sh"

HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" POWER_TEST_LOG="$TEST_LOG" \
    "$POWER_SCRIPT" exit

printf -v exit_command '%q %q' "$TEST_HOME/.config/hypr/scripts/power.sh" finish-exit
rg -Fq "hyprshutdown <--top-label> <Logging out...> <--post-cmd> <$exit_command>" "$TEST_LOG" || \
    fail 'logout is not delegated to graceful shutdown'

: > "$TEST_LOG"
for action in finish-exit reboot shutdown; do
    HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" POWER_TEST_LOG="$TEST_LOG" \
        "$POWER_SCRIPT" "$action"
done
[[ $(rg -c '^listeners <--stopall>$' "$TEST_LOG") -eq 1 ]] || \
    fail 'session listeners were not stopped for completed logout'
[[ $(rg -c '^systemctl <--user> <stop> <myhypr-session\.target>$' "$TEST_LOG") -eq 1 ]] || \
    fail 'session services were not stopped for completed logout'
rg -q '^systemctl <reboot>$' "$TEST_LOG" || fail 'reboot was not requested directly'
rg -q '^systemctl <poweroff>$' "$TEST_LOG" || fail 'poweroff was not requested directly'
if rg -q 'hyprshutdown .*<(Restarting|Shutting down)\.\.\.>' "$TEST_LOG"; then
    fail 'system power actions still depend on a post-Hyprland callback'
fi

# A matching process elsewhere must not suppress a request for this display.
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$FAKE_BIN/pgrep"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "lock <%s>\n" "$WAYLAND_DISPLAY" >> "$POWER_TEST_LOG"' \
    'exit "${POWER_LOCK_STATUS:-0}"' > "$FAKE_BIN/hyprlock"
chmod +x -- "$FAKE_BIN/pgrep" "$FAKE_BIN/hyprlock"
for display in wayland-test-one wayland-test-two; do
    HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" POWER_TEST_LOG="$TEST_LOG" \
        WAYLAND_DISPLAY="$display" "$POWER_SCRIPT" lock
    rg -Fxq "lock <$display>" "$TEST_LOG" || fail 'current display was not locked'
done
if HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" POWER_TEST_LOG="$TEST_LOG" \
    WAYLAND_DISPLAY=wayland-test-one POWER_LOCK_STATUS=7 "$POWER_SCRIPT" lock; then
    fail 'locker failure was hidden'
else
    [[ $? -eq 7 ]] || fail 'locker failure status was not preserved'
fi
rg -Fq 'lock_cmd = ~/.config/hypr/scripts/power.sh lock' \
    "$REPO_ROOT/dotfiles/.config/hypr/hypridle.conf" || fail 'idle lock does not use shared helper'

printf 'Power actions use reliable system requests and graceful logout.\n'
