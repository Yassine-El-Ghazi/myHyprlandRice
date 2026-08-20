#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-link-test.XXXXXXXX")

cleanup() {
    case $TEST_HOME in
        "${TMPDIR:-/tmp}"/myhypr-link-test.*) rm -rf -- "$TEST_HOME" ;;
    esac
}
trap cleanup EXIT

printf 'private shell setup\n' > "$TEST_HOME/.zshrc"
HOME="$TEST_HOME" XDG_STATE_HOME="$TEST_HOME/.local/state" \
    "$REPO_ROOT/scripts/link-dotfiles.sh" \
    --target "$TEST_HOME" --backup-conflicts --yes >/dev/null
HOME="$TEST_HOME" "$REPO_ROOT/scripts/seed-runtime.sh" \
    --target "$TEST_HOME" >/dev/null

[[ -L $TEST_HOME/.zshrc ]]
[[ $TEST_HOME/.zshrc -ef $REPO_ROOT/dotfiles/.zshrc ]]
[[ -L $TEST_HOME/.config/hypr/hyprland.lua ]]
[[ $TEST_HOME/.config/hypr/hyprland.lua -ef \
    $REPO_ROOT/dotfiles/.config/hypr/hyprland.lua ]]

runtime_selector="$TEST_HOME/.config/hypr/conf/monitor.conf"
[[ -f $runtime_selector && ! -L $runtime_selector ]]
cmp -s -- "$runtime_selector" \
    "$REPO_ROOT/defaults/.config/hypr/conf/monitor.conf"

mapfile -t backups < <(
    find "$TEST_HOME/.local/state/myhyprlandrice/backups" \
        -type f -name .zshrc -print
)
[[ ${#backups[@]} -eq 1 ]]
[[ $(<"${backups[0]}") == 'private shell setup' ]]

# Restowing and seeding a second time must preserve mutable runtime state.
printf 'source = ~/.config/hypr/conf/monitors/nwg-displays.conf\n' \
    > "$runtime_selector"
HOME="$TEST_HOME" XDG_STATE_HOME="$TEST_HOME/.local/state" \
    "$REPO_ROOT/scripts/link-dotfiles.sh" \
    --target "$TEST_HOME" --backup-conflicts --yes >/dev/null
HOME="$TEST_HOME" "$REPO_ROOT/scripts/seed-runtime.sh" \
    --target "$TEST_HOME" >/dev/null
rg -q 'nwg-displays\.conf' "$runtime_selector"

# Exercise the public orchestrator without mutating the disposable home.
HOME="$TEST_HOME" XDG_STATE_HOME="$TEST_HOME/.local/state" \
    "$REPO_ROOT/bootstrap.sh" --profile desktop --dry-run --yes \
    --no-packages --no-system >/dev/null

printf 'Stow linking, backups, runtime seeds, and bootstrap dry-run passed.\n'
