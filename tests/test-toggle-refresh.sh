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
if rg -q '^eval hl\.monitor' "$TEST_HYPRCTL_LOG"; then
    printf 'High-rate no-op unexpectedly changed the monitor.\n' >&2
    exit 1
fi

: > "$TEST_HYPRCTL_LOG"
PATH="$REPO_ROOT/tests/helpers:$PATH" \
    "$REPO_ROOT/dotfiles/.config/hypr/scripts/toggle-refresh.sh" low
rg -Fqx "eval hl.monitor({ output = 'eDP-test', mode = '1920x1080@60.00', position = '0x0', scale = 1, transform = 0 })" "$TEST_HYPRCTL_LOG"
rg -q '^notify .*switched to 60.00Hz$' "$TEST_HYPRCTL_LOG"

bad_fixture=''
cleanup_bad_fixture() {
    case $bad_fixture in
        "${TMPDIR:-/tmp}"/myhypr-bad-monitor.*) rm -f -- "$bad_fixture" ;;
    esac
}
trap 'cleanup; cleanup_bad_fixture' EXIT
bad_fixture=$(mktemp "${TMPDIR:-/tmp}/myhypr-bad-monitor.XXXXXXXX")
jq '.[0].name = "eDP-test\u0027); os.execute(\u0022touch /tmp/bad\u0022); --"' \
    "$REPO_ROOT/tests/fixtures/hypr-monitors.json" > "$bad_fixture"
: > "$TEST_HYPRCTL_LOG"
if TEST_HYPRCTL_FIXTURE="$bad_fixture" PATH="$REPO_ROOT/tests/helpers:$PATH" \
    "$REPO_ROOT/dotfiles/.config/hypr/scripts/toggle-refresh.sh" low; then
    printf 'Unsafe monitor name was accepted.\n' >&2
    exit 1
fi
if rg -q '^eval hl\.monitor' "$TEST_HYPRCTL_LOG"; then
    printf 'Unsafe monitor name emitted a monitor action.\n' >&2
    exit 1
fi
rm -f -- "$bad_fixture"

printf 'Dynamic refresh-rate helper passed.\n'
