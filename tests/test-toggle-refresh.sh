#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_HYPRCTL_LOG=$(mktemp "${TMPDIR:-/tmp}/myhypr-hyprctl-test.XXXXXXXX")
export TEST_HYPRCTL_LOG
cleanup() {
    case $TEST_HYPRCTL_LOG in
        "${TMPDIR:-/tmp}"/myhypr-hyprctl-test.*) rm -f -- "$TEST_HYPRCTL_LOG" ;;
    esac
}
trap cleanup EXIT

PATH="$REPO_ROOT/tests/helpers:$PATH" \
    "$REPO_ROOT/dotfiles/.config/hypr/scripts/toggle-refresh.sh" high
rg -q '^notify .*already at 144.00Hz$' "$TEST_HYPRCTL_LOG"
if rg -q '^keyword ' "$TEST_HYPRCTL_LOG"; then
    printf 'High-rate no-op unexpectedly changed the monitor.\n' >&2
    exit 1
fi

: > "$TEST_HYPRCTL_LOG"
PATH="$REPO_ROOT/tests/helpers:$PATH" \
    "$REPO_ROOT/dotfiles/.config/hypr/scripts/toggle-refresh.sh" low
rg -q '^keyword monitor eDP-test,1920x1080@60.00,0x0,1,transform,0$' "$TEST_HYPRCTL_LOG"
rg -q '^notify .*switched to 60.00Hz$' "$TEST_HYPRCTL_LOG"

printf 'Dynamic refresh-rate helper passed.\n'
