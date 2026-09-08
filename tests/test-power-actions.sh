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

for action in exit reboot shutdown; do
    HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" POWER_TEST_LOG="$TEST_LOG" \
        "$POWER_SCRIPT" "$action"
done

printf -v exit_command '%q %q' "$TEST_HOME/.config/hypr/scripts/power.sh" finish-exit
printf -v reboot_command '%q %q' "$TEST_HOME/.config/hypr/scripts/power.sh" finish-reboot
printf -v poweroff_command '%q %q' "$TEST_HOME/.config/hypr/scripts/power.sh" finish-poweroff
rg -Fq "hyprshutdown <--top-label> <Logging out...> <--post-cmd> <$exit_command>" "$TEST_LOG" || \
    fail 'logout is not delegated to graceful shutdown'
rg -Fq "hyprshutdown <--top-label> <Restarting...> <--post-cmd> <$reboot_command>" "$TEST_LOG" || \
    fail 'reboot is not deferred until applications close'
rg -Fq "hyprshutdown <--top-label> <Shutting down...> <--post-cmd> <$poweroff_command>" "$TEST_LOG" || \
    fail 'poweroff is not deferred until applications close'

: > "$TEST_LOG"
for action in finish-exit finish-reboot finish-poweroff; do
    HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" POWER_TEST_LOG="$TEST_LOG" \
        "$POWER_SCRIPT" "$action"
done
[[ $(rg -c '^listeners <--stopall>$' "$TEST_LOG") -eq 3 ]] || \
    fail 'session listeners were not stopped for every completed exit'
[[ $(rg -c '^systemctl <--user> <stop> <myhypr-session\.target>$' "$TEST_LOG") -eq 3 ]] || \
    fail 'session services were not stopped for every completed exit'
rg -q '^systemctl <reboot>$' "$TEST_LOG" || fail 'completed reboot was not requested'
rg -q '^systemctl <poweroff>$' "$TEST_LOG" || fail 'completed poweroff was not requested'

printf 'Power actions close applications before ending the session.\n'
