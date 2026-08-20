#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes write literal mock-script variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-theme-test.XXXXXXXX")
TEST_HOME="$TEST_ROOT/home"
CONFIG_ROOT="$TEST_HOME/.config"
FAKE_BIN="$TEST_ROOT/bin"
export THEME_TEST_LOG="$TEST_ROOT/commands.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-theme-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Desktop theme test failed: %s\n' "$*" >&2
    exit 1
}

mkdir -p -- \
    "$CONFIG_ROOT/waybar" "$CONFIG_ROOT/hypr/conf" \
    "$CONFIG_ROOT/swaync" "$CONFIG_ROOT/wlogout" \
    "$CONFIG_ROOT/nwg-dock-hyprland" "$FAKE_BIN"
ln -s -- "$REPO_ROOT/dotfiles/.config/waybar/themes" "$CONFIG_ROOT/waybar/themes"
ln -s -- "$REPO_ROOT/dotfiles/.config/hypr/conf/windows" "$CONFIG_ROOT/hypr/conf/windows"
ln -s -- "$REPO_ROOT/dotfiles/.config/swaync/themes" "$CONFIG_ROOT/swaync/themes"
ln -s -- "$REPO_ROOT/dotfiles/.config/wlogout/themes" "$CONFIG_ROOT/wlogout/themes"

for script in waybar/launch.sh nwg-dock-hyprland/launch.sh; do
    printf '#!/usr/bin/env bash\nprintf "%s\\n" >> "$THEME_TEST_LOG"\n' "$script" \
        > "$CONFIG_ROOT/$script"
    chmod +x -- "$CONFIG_ROOT/$script"
done
for command_name in swaync-client hyprctl; do
    printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >> "$THEME_TEST_LOG"\n' \
        "$command_name" > "$FAKE_BIN/$command_name"
    chmod +x -- "$FAKE_BIN/$command_name"
done

HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" PATH="$FAKE_BIN:$PATH" \
    "$REPO_ROOT/dotfiles/.config/myhypr/themes/apply-theme" \
        Modern '/myhypr-modern;/myhypr-modern/default' \
        modern rofi modern border-2.conf 2 modern modern >/dev/null
sleep 0.1

assert_content() {
    local path=$1
    local expected=$2
    [[ -f $path && $(<"$path") == "$expected" ]] || \
        fail "unexpected content in $path"
}

assert_content "$CONFIG_ROOT/myhypr/settings/waybar-theme.sh" \
    '/myhypr-modern;/myhypr-modern/default'
assert_content "$CONFIG_ROOT/myhypr/settings/dock-theme" modern
assert_content "$CONFIG_ROOT/myhypr/settings/launcher" rofi
assert_content "$CONFIG_ROOT/myhypr/settings/walker-theme" modern
assert_content "$CONFIG_ROOT/myhypr/settings/rofi-border.rasi" '* { border-width: 2px; }'
assert_content "$CONFIG_ROOT/hypr/conf/window.conf" \
    'source = ~/.config/hypr/conf/windows/border-2.conf'
assert_content "$CONFIG_ROOT/swaync/style.css" '@import "themes/modern/style.css";'
assert_content "$CONFIG_ROOT/wlogout/style.css" '@import "themes/modern/style.css";'
rg -q '^waybar/launch\.sh$' "$THEME_TEST_LOG"
rg -q '^nwg-dock-hyprland/launch\.sh$' "$THEME_TEST_LOG"
rg -q '^swaync-client -rs$' "$THEME_TEST_LOG"
rg -q '^hyprctl reload$' "$THEME_TEST_LOG"

if HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" PATH="$FAKE_BIN:$PATH" \
    "$REPO_ROOT/dotfiles/.config/myhypr/themes/apply-theme" \
        Unsafe '/../../tmp;/../../tmp' modern rofi modern border-2.conf 2 modern modern \
        >/dev/null 2>&1; then
    fail 'path-traversing theme specification was accepted'
fi

printf 'Declarative desktop theme application passed.\n'
