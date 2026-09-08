#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes write literal mock-script variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-waybar-test.XXXXXXXX")
TEST_HOME="$TEST_ROOT/home"
CONFIG_ROOT="$TEST_HOME/.config"
FAKE_BIN="$TEST_ROOT/bin"
export WAYBAR_TEST_LOG="$TEST_ROOT/waybar.log"
export WAYBAR_TEST_PIDS="$TEST_ROOT/waybar.pids"

cleanup() {
    if [[ -r $WAYBAR_TEST_PIDS ]]; then
        while IFS= read -r process_id; do
            [[ $process_id =~ ^[0-9]+$ ]] && kill "$process_id" 2>/dev/null || true
        done < "$WAYBAR_TEST_PIDS"
    fi
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-waybar-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Waybar test failed: %s\n' "$*" >&2
    exit 1
}

mkdir -p -- \
    "$CONFIG_ROOT/waybar" "$CONFIG_ROOT/myhypr/settings" \
    "$FAKE_BIN" "$TEST_ROOT/runtime"
ln -s -- "$REPO_ROOT/dotfiles/.config/waybar/themes" "$CONFIG_ROOT/waybar/themes"
ln -s -- "$REPO_ROOT/dotfiles/.config/waybar/launch.sh" "$CONFIG_ROOT/waybar/launch.sh"
ln -s -- "$REPO_ROOT/dotfiles/.config/waybar/themeswitcher.sh" \
    "$CONFIG_ROOT/waybar/themeswitcher.sh"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%q " "$@" >> "$WAYBAR_TEST_LOG"' \
    'printf "\n" >> "$WAYBAR_TEST_LOG"' \
    'if [[ -n ${WAYBAR_TEST_HOLD:-} ]]; then' \
    '    printf "%s\n" "$$" >> "$WAYBAR_TEST_PIDS"' \
    '    exec sleep 30' \
    'fi' > "$FAKE_BIN/waybar"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/pkill"
printf '#!/usr/bin/env bash\nprintf '\''[{"instance":"test-instance"}]\\n'\''\n' \
    > "$FAKE_BIN/hyprctl"
printf '#!/usr/bin/env bash\nawk '\''/MyHypr Modern Default/{print NR - 1; found=1; exit} END {if (!found) exit 1}'\''\n' \
    > "$FAKE_BIN/rofi"
chmod +x -- "$FAKE_BIN/waybar" "$FAKE_BIN/pkill" "$FAKE_BIN/hyprctl" "$FAKE_BIN/rofi"

printf '%s\n' '/myhypr-modern;/myhypr-modern/default' \
    > "$CONFIG_ROOT/myhypr/settings/waybar-theme.sh"
HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" XDG_RUNTIME_DIR="$TEST_ROOT/runtime" \
    PATH="$FAKE_BIN:$PATH" "$CONFIG_ROOT/waybar/launch.sh" >/dev/null

sleep 0.1
rg -q -- '--config .*/themes/myhypr-modern/config' "$WAYBAR_TEST_LOG" || \
    fail 'expected theme config was not launched'
rg -q -- '--style .*/themes/myhypr-modern/default/style\.css' "$WAYBAR_TEST_LOG" || \
    fail 'expected theme style was not launched'

# Invalid runtime state must be replaced with the known-good local default.
: > "$WAYBAR_TEST_LOG"
printf '%s\n' '/../../tmp;/../../tmp' > "$CONFIG_ROOT/myhypr/settings/waybar-theme.sh"
HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" XDG_RUNTIME_DIR="$TEST_ROOT/runtime" \
    PATH="$FAKE_BIN:$PATH" "$CONFIG_ROOT/waybar/launch.sh" >/dev/null 2>&1
[[ $(<"$CONFIG_ROOT/myhypr/settings/waybar-theme.sh") == \
    '/myhypr-modern;/myhypr-modern/default' ]] || fail 'invalid theme was not repaired'

# The selector must emit a valid MyHypr-only theme specification.
printf 'rofi\n' > "$CONFIG_ROOT/myhypr/settings/launcher"
HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" XDG_RUNTIME_DIR="$TEST_ROOT/runtime" \
    PATH="$FAKE_BIN:$PATH" "$CONFIG_ROOT/waybar/themeswitcher.sh" >/dev/null
sleep 0.1
selected=$(<"$CONFIG_ROOT/myhypr/settings/waybar-theme.sh")
[[ $selected == '/myhypr-modern;/myhypr-modern/default' ]] || \
    fail "unexpected selector result: $selected"

# A long-running Waybar must not inherit the launcher's flock. Otherwise the
# second invocation exits without performing the requested restart.
: > "$WAYBAR_TEST_LOG"
WAYBAR_TEST_HOLD=1 HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" \
    XDG_RUNTIME_DIR="$TEST_ROOT/runtime" PATH="$FAKE_BIN:$PATH" \
    "$CONFIG_ROOT/waybar/launch.sh" >/dev/null
sleep 0.1
WAYBAR_TEST_HOLD=1 HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" \
    XDG_RUNTIME_DIR="$TEST_ROOT/runtime" PATH="$FAKE_BIN:$PATH" \
    "$CONFIG_ROOT/waybar/launch.sh" >/dev/null
sleep 0.1
[[ $(wc -l < "$WAYBAR_TEST_LOG") -eq 2 ]] || \
    fail 'a running Waybar retained the launcher lock and blocked reload'

printf 'Waybar theme resolution, fallback, and selection passed.\n'
