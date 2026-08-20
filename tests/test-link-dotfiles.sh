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

mkdir -p -- "$TEST_HOME/.config/hypr/conf/retired"
ln -s -- "$REPO_ROOT/dotfiles/.config/hypr/conf/retired/legacy.conf" \
    "$TEST_HOME/.config/hypr/conf/retired/legacy.conf"
[[ -L $TEST_HOME/.config/hypr/conf/retired/legacy.conf && \
    ! -e $TEST_HOME/.config/hypr/conf/retired/legacy.conf ]]

printf 'private shell setup\n' > "$TEST_HOME/.zshrc"
HOME="$TEST_HOME" XDG_STATE_HOME="$TEST_HOME/.local/state" \
    "$REPO_ROOT/scripts/link-dotfiles.sh" \
    --target "$TEST_HOME" --backup-conflicts --yes >/dev/null

# Reproduce an upgrade from the old layout: this selector used to be a Stow
# link, but its tracked source moved into defaults in the standalone release.
runtime_selector="$TEST_HOME/.config/hypr/conf/monitor.conf"
ln -s -- "$REPO_ROOT/dotfiles/.config/hypr/conf/monitor.conf" "$runtime_selector"
[[ -L $runtime_selector && ! -e $runtime_selector ]]

HOME="$TEST_HOME" "$REPO_ROOT/scripts/seed-runtime.sh" \
    --target "$TEST_HOME" >/dev/null

[[ -L $TEST_HOME/.zshrc ]]
[[ $TEST_HOME/.zshrc -ef $REPO_ROOT/dotfiles/.zshrc ]]
[[ -L $TEST_HOME/.config/hypr/hyprland.lua ]]
[[ $TEST_HOME/.config/hypr/hyprland.lua -ef \
    $REPO_ROOT/dotfiles/.config/hypr/hyprland.lua ]]
[[ ! -e $TEST_HOME/.config/hypr/conf/retired ]]

[[ -f $runtime_selector && ! -L $runtime_selector ]]
cmp -s -- "$runtime_selector" \
    "$REPO_ROOT/defaults/.config/hypr/conf/monitor.conf"

mapfile -t backups < <(
    find "$TEST_HOME/.local/state/myhyprlandrice/backups" \
        -type f -name .zshrc -print
)
[[ ${#backups[@]} -eq 1 ]]
[[ $(<"${backups[0]}") == 'private shell setup' ]]
mapfile -t retired_links < <(
    find "$TEST_HOME/.local/state/myhyprlandrice/backups" \
        -type l -path '*/.config/hypr/conf/retired/legacy.conf' -print
)
[[ ${#retired_links[@]} -eq 1 ]]

# Restowing and seeding a second time must preserve mutable runtime state.
printf 'source = ~/.config/hypr/conf/monitors/nwg-displays.conf\n' \
    > "$runtime_selector"
HOME="$TEST_HOME" XDG_STATE_HOME="$TEST_HOME/.local/state" \
    "$REPO_ROOT/scripts/link-dotfiles.sh" \
    --target "$TEST_HOME" --backup-conflicts --yes >/dev/null
HOME="$TEST_HOME" "$REPO_ROOT/scripts/seed-runtime.sh" \
    --target "$TEST_HOME" >/dev/null
rg -q 'nwg-displays\.conf' "$runtime_selector"

# Canonicalization must reject aliases for the filesystem root.
if "$REPO_ROOT/scripts/seed-runtime.sh" \
    --target /tmp/.. --dry-run >/dev/null 2>&1; then
    printf 'Runtime seeder accepted a root-directory alias.\n' >&2
    exit 1
fi
if "$REPO_ROOT/scripts/link-dotfiles.sh" \
    --target /tmp/.. --dry-run >/dev/null 2>&1; then
    printf 'Dotfile linker accepted a root-directory alias.\n' >&2
    exit 1
fi

# Exercise the public orchestrator without mutating the disposable home.
HOME="$TEST_HOME" XDG_STATE_HOME="$TEST_HOME/.local/state" \
    "$REPO_ROOT/bootstrap.sh" --profile desktop --dry-run --yes \
    --no-packages --no-system >/dev/null

printf 'Stow linking, backups, runtime seeds, and bootstrap dry-run passed.\n'
