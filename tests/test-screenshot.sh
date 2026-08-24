#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-screenshot-test.XXXXXXXX")
TEST_HOME="$TEST_ROOT/home"
FAKE_BIN="$TEST_ROOT/bin"
CONFIG_ROOT="$TEST_HOME/.config"
export SCREENSHOT_TEST_LOG="$TEST_ROOT/commands.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-screenshot-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Screenshot test failed: %s\n' "$*" >&2
    exit 1
}

mkdir -p -- "$FAKE_BIN" "$CONFIG_ROOT/myhypr/settings"
ln -s -- "$REPO_ROOT/dotfiles/.config/myhypr/library.sh" \
    "$CONFIG_ROOT/myhypr/library.sh"
printf '%s\n' '$HOME/Screenshots' > "$CONFIG_ROOT/myhypr/settings/screenshot-folder"
printf 'shot.png\n' > "$CONFIG_ROOT/myhypr/settings/screenshot-filename"
printf 'pinta\n' > "$CONFIG_ROOT/myhypr/settings/screenshot-editor"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'cat >/dev/null' \
    'printf "rofi %s\n" "$*" >> "$SCREENSHOT_TEST_LOG"' \
    'exit 0' > "$FAKE_BIN/rofi"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "grim" >> "$SCREENSHOT_TEST_LOG"' \
    'printf " <%s>" "$@" >> "$SCREENSHOT_TEST_LOG"' \
    'printf "\n" >> "$SCREENSHOT_TEST_LOG"' \
    'destination=${!#}' \
    ': > "$destination"' > "$FAKE_BIN/grim"
printf '%s\n' '#!/usr/bin/env bash' 'printf "0,0 10x10\n"' > "$FAKE_BIN/slurp"
printf '%s\n' '#!/usr/bin/env bash' 'while :; do sleep 1; done' > "$FAKE_BIN/hyprpicker"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$FAKE_BIN/notify-send"
chmod +x -- "$FAKE_BIN"/*

helper="$REPO_ROOT/dotfiles/.config/hypr/scripts/screenshot.sh"
test_env=(HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" PATH="$FAKE_BIN:/usr/bin:/bin")

env "${test_env[@]}" "$helper" || fail 'no-argument flow failed'
rg -Fq 'Take screenshot' "$SCREENSHOT_TEST_LOG" || fail 'interactive selector was not reached'
[[ ! -e $TEST_HOME/Screenshots/shot.png ]] || fail 'interactive probe captured the real screen path'

: > "$SCREENSHOT_TEST_LOG"
env "${test_env[@]}" "$helper" --unknown || fail 'unknown-argument flow failed'
rg -Fq 'Take screenshot' "$SCREENSHOT_TEST_LOG" || \
    fail 'unknown argument did not reach the interactive selector'
[[ ! -e $TEST_HOME/Screenshots/shot.png ]] || \
    fail 'unknown argument captured the real screen path'

env "${test_env[@]}" "$helper" --instant || fail 'instant full capture failed'
rg -Fq "grim <$TEST_HOME/Screenshots/shot.png>" "$SCREENSHOT_TEST_LOG" || \
    fail 'instant full capture used unexpected arguments'

env "${test_env[@]}" "$helper" --instant-area || fail 'instant area capture failed'
rg -Fq "grim <-g> <0,0 10x10> <$TEST_HOME/Screenshots/shot.png>" \
    "$SCREENSHOT_TEST_LOG" || fail 'instant area capture used unexpected arguments'

printf 'Screenshot optional modes are nounset-safe.\n'
