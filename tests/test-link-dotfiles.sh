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

should_run_case() {
    [[ ${LINK_DOTFILES_CASE:-all} == all || ${LINK_DOTFILES_CASE:-} == "$1" ]]
}

if should_run_case parent-conflict; then
    PARENT_ROOT="$TEST_HOME/parent-conflict"
    PARENT_HOME="$PARENT_ROOT/home"
    PARENT_BIN="$PARENT_ROOT/bin"
    PARENT_ORIGINAL="$PARENT_ROOT/original-kitty"
    mkdir -p -- "$PARENT_HOME/.config" "$PARENT_BIN" "$PARENT_ORIGINAL"
    printf 'original kitty directory\n' > "$PARENT_ORIGINAL/state"
    ln -s -- "$PARENT_ORIGINAL" "$PARENT_HOME/.config/kitty"

    export STOW_PARTIAL_SOURCE="$REPO_ROOT/dotfiles/.config/kitty/kitty.conf"
    export STOW_PARTIAL_TARGET="$PARENT_HOME/.config/kitty/kitty.conf"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'for argument in "$@"; do' \
        '    [[ $argument == --simulate ]] && exit 0' \
        'done' \
        'mkdir -p -- "$(dirname -- "$STOW_PARTIAL_TARGET")"' \
        'ln -s -- "$STOW_PARTIAL_SOURCE" "$STOW_PARTIAL_TARGET"' \
        'exit 43' > "$PARENT_BIN/stow"
    chmod +x -- "$PARENT_BIN/stow"

    set +e
    HOME="$PARENT_HOME" XDG_STATE_HOME="$PARENT_HOME/.local/state" \
        PATH="$PARENT_BIN:/usr/bin:/bin" \
        "$REPO_ROOT/scripts/link-dotfiles.sh" --target "$PARENT_HOME" \
        --backup-conflicts --yes >/dev/null 2>&1
    parent_status=$?
    set -e
    [[ $parent_status -eq 43 ]] || {
        printf 'Parent-conflict rollback returned %s instead of 43.\n' \
            "$parent_status" >&2
        exit 1
    }
    [[ -L $PARENT_HOME/.config/kitty && \
        $PARENT_HOME/.config/kitty -ef $PARENT_ORIGINAL ]] || {
        printf 'Parent conflict was not restored after failed Stow.\n' >&2
        exit 1
    }
    [[ $(<"$PARENT_HOME/.config/kitty/state") == 'original kitty directory' ]]
fi

if should_run_case folded-link; then
    FOLDED_ROOT="$TEST_HOME/folded-link"
    FOLDED_HOME="$FOLDED_ROOT/home"
    FOLDED_BIN="$FOLDED_ROOT/bin"
    mkdir -p -- "$FOLDED_HOME/.config" "$FOLDED_BIN"
    ln -s -- "$REPO_ROOT/dotfiles/.config/kitty" "$FOLDED_HOME/.config/kitty"

    export STOW_PARTIAL_SOURCE="$REPO_ROOT/dotfiles/.config/kitty/kitty.conf"
    export STOW_PARTIAL_TARGET="$FOLDED_HOME/.config/kitty/kitty.conf"
    export STOW_FOLDED_TARGET="$FOLDED_HOME/.config/kitty"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'for argument in "$@"; do' \
        '    [[ $argument == --simulate ]] && exit 0' \
        'done' \
        'rm -f -- "$STOW_FOLDED_TARGET"' \
        'mkdir -p -- "$(dirname -- "$STOW_PARTIAL_TARGET")"' \
        'ln -s -- "$STOW_PARTIAL_SOURCE" "$STOW_PARTIAL_TARGET"' \
        'exit 44' > "$FOLDED_BIN/stow"
    chmod +x -- "$FOLDED_BIN/stow"

    set +e
    HOME="$FOLDED_HOME" XDG_STATE_HOME="$FOLDED_HOME/.local/state" \
        PATH="$FOLDED_BIN:/usr/bin:/bin" \
        "$REPO_ROOT/scripts/link-dotfiles.sh" --target "$FOLDED_HOME" \
        --backup-conflicts --yes >/dev/null 2>&1
    folded_status=$?
    set -e
    [[ $folded_status -eq 44 ]] || {
        printf 'Folded-link rollback returned %s instead of 44.\n' \
            "$folded_status" >&2
        exit 1
    }
    [[ -L $FOLDED_HOME/.config/kitty && \
        $FOLDED_HOME/.config/kitty -ef "$REPO_ROOT/dotfiles/.config/kitty" ]] || {
        printf 'Folded managed directory link was not restored after failed Stow.\n' >&2
        exit 1
    }
fi

if should_run_case collision; then
    COLLISION_ROOT="$TEST_HOME/restoration-collision"
    COLLISION_HOME="$COLLISION_ROOT/home"
    COLLISION_BIN="$COLLISION_ROOT/bin"
    mkdir -p -- "$COLLISION_HOME" "$COLLISION_BIN"
    printf 'restore me\n' > "$COLLISION_HOME/.zshrc"

    export STOW_COLLISION_TARGET="$COLLISION_HOME/.zshrc"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'for argument in "$@"; do' \
        '    [[ $argument == --simulate ]] && exit 0' \
        'done' \
        'printf "unrelated collision\\n" > "$STOW_COLLISION_TARGET"' \
        'exit 45' > "$COLLISION_BIN/stow"
    chmod +x -- "$COLLISION_BIN/stow"

    set +e
    HOME="$COLLISION_HOME" XDG_STATE_HOME="$COLLISION_HOME/.local/state" \
        PATH="$COLLISION_BIN:/usr/bin:/bin" \
        "$REPO_ROOT/scripts/link-dotfiles.sh" --target "$COLLISION_HOME" \
        --backup-conflicts --yes >"$COLLISION_ROOT/output" 2>&1
    collision_status=$?
    set -e
    [[ $collision_status -eq 45 ]] || {
        printf 'Incomplete rollback returned %s instead of real status 45.\n' \
            "$collision_status" >&2
        exit 1
    }
    [[ $(<"$COLLISION_HOME/.zshrc") == 'unrelated collision' ]] || {
        printf 'Rollback overwrote unrelated occupied content.\n' >&2
        exit 1
    }
    mapfile -t collision_backups < <(
        find "$COLLISION_HOME/.local/state/myhyprlandrice/backups" \
            -type f -name .zshrc -print
    )
    [[ ${#collision_backups[@]} -eq 1 && \
        $(<"${collision_backups[0]}") == 'restore me' ]] || {
        printf 'Rollback did not preserve the original conflicting content.\n' >&2
        exit 1
    }
    rg -q 'Rollback target is occupied; recover .zshrc' "$COLLISION_ROOT/output"
    rg -q 'Stow transaction failed with status 45.' "$COLLISION_ROOT/output"
fi

if should_run_case reverse-order; then
    ORDER_ROOT="$TEST_HOME/reverse-order"
    ORDER_HOME="$ORDER_ROOT/home"
    ORDER_BIN="$ORDER_ROOT/bin"
    ORDER_LOG="$ORDER_ROOT/restores"
    mkdir -p -- "$ORDER_HOME" "$ORDER_BIN"
    printf 'bash restore\n' > "$ORDER_HOME/.bashrc"
    printf 'zsh restore\n' > "$ORDER_HOME/.zshrc"

    export STOW_RESTORE_LOG="$ORDER_LOG"
    export STOW_RESTORE_TARGET="$ORDER_HOME"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'source_path=$2' \
        'target_path=$3' \
        'if [[ $source_path == */myhyprlandrice/backups/* && $target_path == "$STOW_RESTORE_TARGET"/* ]]; then' \
        '    basename -- "$source_path" >> "$STOW_RESTORE_LOG"' \
        'fi' \
        'exec /usr/bin/mv "$@"' > "$ORDER_BIN/mv"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'for argument in "$@"; do' \
        '    [[ $argument == --simulate ]] && exit 0' \
        'done' \
        'exit 46' > "$ORDER_BIN/stow"
    chmod +x -- "$ORDER_BIN/mv" "$ORDER_BIN/stow"

    set +e
    HOME="$ORDER_HOME" XDG_STATE_HOME="$ORDER_HOME/.local/state" \
        PATH="$ORDER_BIN:/usr/bin:/bin" \
        "$REPO_ROOT/scripts/link-dotfiles.sh" --target "$ORDER_HOME" \
        --backup-conflicts --yes >/dev/null 2>&1
    order_status=$?
    set -e
    [[ $order_status -eq 46 ]] || {
        printf 'Reverse-order rollback returned %s instead of 46.\n' \
            "$order_status" >&2
        exit 1
    }
    [[ $(<"$ORDER_HOME/.bashrc") == 'bash restore' ]]
    [[ $(<"$ORDER_HOME/.zshrc") == 'zsh restore' ]]
    [[ $(<"$ORDER_LOG") == $'.zshrc\n.bashrc' ]] || {
        printf 'Conflicts were not restored in reverse move order.\n' >&2
        exit 1
    }
fi

printf 'Stow linking, backups, runtime seeds, and bootstrap dry-run passed.\n'
