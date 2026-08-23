#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-animation-test.XXXXXXXX")
FAKE_BIN="$TEST_ROOT/bin"
TEST_HOME="$TEST_ROOT/home"
export ANIMATION_TEST_LOG="$TEST_ROOT/hyprctl.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-animation-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

mkdir -p -- "$FAKE_BIN" "$TEST_HOME/.config/hypr/conf"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    '[[ ${ANIMATION_TEST_FAIL:-0} -eq 0 ]] || exit 9' \
    'printf "hyprctl %s\n" "$*" >> "$ANIMATION_TEST_LOG"' \
    > "$FAKE_BIN/hyprctl"
chmod +x -- "$FAKE_BIN/hyprctl"
printf 'source = ~/.config/hypr/conf/animations/default.conf\n' \
    > "$TEST_HOME/.config/hypr/conf/animation.conf"

helper="$REPO_ROOT/dotfiles/.config/hypr/scripts/toggle-animations.sh"
HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" "$helper"
rg -Fqx 'hyprctl eval hl.config({ animations = { enabled = false } })' "$ANIMATION_TEST_LOG"
[[ -f $TEST_HOME/.cache/myhypr/animations-disabled ]]

HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" "$helper"
rg -Fqx 'hyprctl eval hl.config({ animations = { enabled = true } })' "$ANIMATION_TEST_LOG"
[[ ! -e $TEST_HOME/.cache/myhypr/animations-disabled ]]

if HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" ANIMATION_TEST_FAIL=1 "$helper"; then
    printf 'Animation helper accepted a failed Hyprland update.\n' >&2
    exit 1
fi
[[ ! -e $TEST_HOME/.cache/myhypr/animations-disabled ]]

printf 'Animation toggling commits state only after typed config succeeds.\n'
