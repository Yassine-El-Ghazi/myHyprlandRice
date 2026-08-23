#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes write literal mock-script variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-dock-launch.XXXXXXXX")
TEST_HOME="$TEST_ROOT/home"
CONFIG_ROOT="$TEST_HOME/.config"
FAKE_BIN="$TEST_ROOT/bin"
export DOCK_LAUNCH_TEST_LOG="$TEST_ROOT/commands.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-dock-launch.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Dock launch test failed: %s\n' "$*" >&2
    exit 1
}

mkdir -p -- \
    "$CONFIG_ROOT/myhypr/settings" \
    "$CONFIG_ROOT/nwg-dock-hyprland/themes/glass" \
    "$CONFIG_ROOT/hypr/scripts" "$FAKE_BIN"
printf 'glass\n' > "$CONFIG_ROOT/myhypr/settings/dock-theme"
printf 'window {}\n' > "$CONFIG_ROOT/nwg-dock-hyprland/themes/glass/style.css"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CONFIG_ROOT/hypr/scripts/launcher.sh"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "pkill %s\n" "$*" >> "$DOCK_LAUNCH_TEST_LOG"' \
    > "$FAKE_BIN/pkill"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "dock %s\n" "$*" >> "$DOCK_LAUNCH_TEST_LOG"' \
    > "$FAKE_BIN/nwg-dock-hyprland"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/sleep"
chmod +x -- "$FAKE_BIN/pkill" "$FAKE_BIN/nwg-dock-hyprland" \
    "$FAKE_BIN/sleep" "$CONFIG_ROOT/hypr/scripts/launcher.sh"

HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" PATH="$FAKE_BIN:$PATH" \
    "$REPO_ROOT/dotfiles/.config/nwg-dock-hyprland/launch.sh"

rg -Fq \
    'pkill -f -- (^|/)nwg-dock-hyprland([[:space:]]|$)' \
    "$DOCK_LAUNCH_TEST_LOG" || \
    fail 'the existing dock is not matched by its full command line'
rg -Fq \
    "dock -i 32 -w 5 -mb 10 -x -s themes/glass/style.css -c $CONFIG_ROOT/hypr/scripts/launcher.sh" \
    "$DOCK_LAUNCH_TEST_LOG" || \
    fail 'the selected relative theme and launcher were not passed to the dock'

printf 'Dock replacement and configured launch behavior passed.\n'
