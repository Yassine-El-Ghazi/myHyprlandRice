#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-sidepad-runtime.XXXXXXXX")
FAKE_BIN="$TEST_ROOT/bin"
export SIDEPAD_TEST_LOG="$TEST_ROOT/hyprctl.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-sidepad-runtime.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

mkdir -p -- "$FAKE_BIN"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "$*" in' \
    '  "-j clients") printf "%s\n" '\''[{"class":"myhypr-sidepad-test","address":"0xabc","size":[700,880],"at":[10,100],"pid":1234}]'\'' ;;' \
    '  "-j monitors") printf "%s\n" '\''[{"focused":true,"height":1080}]'\'' ;;' \
    '  *)' \
    '    printf "hyprctl %s\n" "$*" >> "$SIDEPAD_TEST_LOG"' \
    '    if [[ ${SIDEPAD_FAIL_MOVE:-0} -eq 1 && $* == *"hl.dsp.window.move"* ]]; then exit 9; fi' \
    '    ;;' \
    'esac' \
    > "$FAKE_BIN/hyprctl"
chmod +x -- "$FAKE_BIN/hyprctl"

sidepad="$REPO_ROOT/dotfiles/.config/sidepad/sidepad"
PATH="$FAKE_BIN:/usr/bin:/bin" "$sidepad" --class myhypr-sidepad-test \
    > "$TEST_ROOT/success.out"
mapfile -t calls < "$SIDEPAD_TEST_LOG"
[[ ${calls[0]:-} == "hyprctl dispatch hl.dsp.window.resize({ x = 300, y = 0, relative = true, window = 'address:0xabc' })" ]]
[[ ${calls[1]:-} == "hyprctl dispatch hl.dsp.window.move({ x = 0, y = 0, relative = true, window = 'address:0xabc' })" ]]
[[ ${#calls[@]} -eq 2 ]]
rg -Fq 'Operation completed.' "$TEST_ROOT/success.out"

: > "$SIDEPAD_TEST_LOG"
if SIDEPAD_FAIL_MOVE=1 PATH="$FAKE_BIN:/usr/bin:/bin" \
    "$sidepad" --class myhypr-sidepad-test > "$TEST_ROOT/failure.out" 2>&1; then
    printf 'Sidepad accepted a failed move.\n' >&2
    exit 1
fi
if rg -Fq 'Operation completed.' "$TEST_ROOT/failure.out"; then
    printf 'Sidepad reported success after a failed move.\n' >&2
    exit 1
fi

printf 'Sidepad geometry uses ordered typed dispatchers.\n'
