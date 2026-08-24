#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes write literal fake-Stow variables.
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

# Fresh installs must link the tracked user units before configuring them.
link_line=$(rg -n -m 1 'scripts/link-dotfiles\.sh' \
    "$REPO_ROOT/bootstrap.sh" | cut -d: -f1)
system_line=$(rg -n -m 1 'scripts/configure-system\.sh' \
    "$REPO_ROOT/bootstrap.sh" | cut -d: -f1)
((link_line < system_line))

FAILURE_ROOT="$TEST_HOME/failed-real-stow"
FAILURE_HOME="$FAILURE_ROOT/home"
FAILURE_BIN="$FAILURE_ROOT/bin"
mkdir -p -- "$FAILURE_HOME/.config/keep" "$FAILURE_BIN"
printf 'restore me\n' > "$FAILURE_HOME/.zshrc"
printf 'unrelated\n' > "$FAILURE_HOME/.config/keep/state"
ln -s -- "$REPO_ROOT/dotfiles/.bashrc" "$FAILURE_HOME/.bashrc"

export STOW_PARTIAL_SOURCE="$REPO_ROOT/dotfiles/.config/kitty/kitty.conf"
export STOW_PARTIAL_TARGET="$FAILURE_HOME/.config/kitty/kitty.conf"
export STOW_EXISTING_TARGET="$FAILURE_HOME/.bashrc"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'for argument in "$@"; do' \
    '    [[ $argument == --simulate ]] && exit 0' \
    'done' \
    'rm -f -- "$STOW_EXISTING_TARGET"' \
    'mkdir -p -- "$(dirname -- "$STOW_PARTIAL_TARGET")"' \
    'ln -s -- "$STOW_PARTIAL_SOURCE" "$STOW_PARTIAL_TARGET"' \
    'exit 42' > "$FAILURE_BIN/stow"
chmod +x -- "$FAILURE_BIN/stow"

set +e
HOME="$FAILURE_HOME" XDG_STATE_HOME="$FAILURE_HOME/.local/state" \
    PATH="$FAILURE_BIN:/usr/bin:/bin" \
    "$REPO_ROOT/scripts/link-dotfiles.sh" --target "$FAILURE_HOME" \
    --backup-conflicts --yes >/dev/null 2>&1
failure_status=$?
set -e
[[ $failure_status -eq 42 ]] || {
    printf 'Failed real Stow transaction returned %s instead of 42.\n' \
        "$failure_status" >&2
    exit 1
}
[[ -f $FAILURE_HOME/.zshrc && $(<"$FAILURE_HOME/.zshrc") == 'restore me' ]]
[[ ! -e $STOW_PARTIAL_TARGET && ! -L $STOW_PARTIAL_TARGET ]]
[[ -L $FAILURE_HOME/.bashrc ]]
[[ $FAILURE_HOME/.bashrc -ef $REPO_ROOT/dotfiles/.bashrc ]]
[[ $(<"$FAILURE_HOME/.config/keep/state") == 'unrelated' ]]

printf 'Stow linking, backups, runtime seeds, and bootstrap dry-run passed.\n'
