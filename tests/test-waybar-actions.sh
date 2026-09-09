#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes write literal mock-script variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-waybar-actions.XXXXXXXX")
TEST_HOME="$TEST_ROOT/home"
CONFIG_ROOT="$TEST_HOME/.config"
ACTION_LOG="$TEST_ROOT/actions.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-waybar-actions.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Waybar action test failed: %s\n' "$*" >&2
    exit 1
}

mkdir -p -- "$CONFIG_ROOT/myhypr/bin" "$CONFIG_ROOT/myhypr/settings" "$TEST_ROOT/bin"
ln -s -- "$REPO_ROOT/dotfiles/.config/myhypr/settings/networkmanager.sh" \
    "$CONFIG_ROOT/myhypr/settings/networkmanager.sh"
ln -s -- "$REPO_ROOT/dotfiles/.config/myhypr/settings/system-monitor.sh" \
    "$CONFIG_ROOT/myhypr/settings/system-monitor.sh"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >> "$WAYBAR_ACTION_TEST_LOG"' \
    > "$CONFIG_ROOT/myhypr/bin/run-setting"
chmod +x -- "$CONFIG_ROOT/myhypr/bin/run-setting"

ln -s -- "$REPO_ROOT/dotfiles/.config/myhypr/bin/launch-app" \
    "$CONFIG_ROOT/myhypr/bin/launch-app"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    '[[ $1 == --user && $2 == show-environment ]]' \
    > "$TEST_ROOT/bin/systemctl"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >> "$WAYBAR_ACTION_TEST_LOG"' \
    > "$TEST_ROOT/bin/systemd-run"
chmod +x -- "$TEST_ROOT/bin/systemctl" "$TEST_ROOT/bin/systemd-run"

export WAYBAR_ACTION_TEST_LOG="$ACTION_LOG"
HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" \
    "$CONFIG_ROOT/myhypr/settings/networkmanager.sh"
HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" \
    "$CONFIG_ROOT/myhypr/settings/system-monitor.sh"

mapfile -t actions < "$ACTION_LOG"
expected_network="terminal --class dotfiles-floating -e $CONFIG_ROOT/myhypr/bin/run-setting networkmanager"
expected_monitor="terminal --class dotfiles-floating -e $CONFIG_ROOT/myhypr/bin/run-setting systemmonitor"
[[ ${actions[0]:-} == "$expected_network" ]] || \
    fail 'Wi-Fi does not launch the configured selector in a terminal'
[[ ${actions[1]:-} == "$expected_monitor" ]] || \
    fail 'resource usage does not launch the configured monitor in a terminal'

PATH="$TEST_ROOT/bin:$PATH" HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" \
    "$CONFIG_ROOT/myhypr/bin/launch-app" fake-gui 'argument with spaces'
mapfile -t actions < "$ACTION_LOG"
expected_scope='--user --scope --collect --quiet --expand-environment=no -- fake-gui argument with spaces'
[[ ${actions[2]:-} == "$expected_scope" ]] || \
    fail 'interactive application was not moved to an independent user scope'

modules="$REPO_ROOT/dotfiles/.config/waybar/modules.json"
rg -Fq "\"on-scroll-up\": \"hyprctl dispatch \\\"hl.dsp.focus({ workspace = 'r-1' })\\\"\"" "$modules" || \
    fail 'workspace scroll-up does not use typed focus'
rg -Fq "\"on-scroll-down\": \"hyprctl dispatch \\\"hl.dsp.focus({ workspace = 'r+1' })\\\"\"" "$modules" || \
    fail 'workspace scroll-down does not use typed focus'
system_module=$(sed -n '/"custom\/system": {/,/^  },/p' "$modules")
[[ $system_module == *'"on-click": "~/.config/myhypr/bin/launch-app ~/.config/myhypr/settings/system-monitor.sh"'* ]] || \
    fail 'the visible hardware module has no click action'
rg -Fq '"on-click": "~/.config/myhypr/bin/launch-app ~/.config/myhypr/settings/installupdates.sh"' \
    "$modules" || fail 'update terminal is still owned by Waybar'
rg -Fq '"on-click": "~/.config/myhypr/bin/launch-app pavucontrol"' \
    "$modules" || fail 'audio control is still owned by Waybar'
rg -Fq '"on-click": "~/.config/myhypr/bin/launch-app ~/.config/myhypr/settings/networkmanager.sh"' \
    "$modules" || fail 'network selector is still owned by Waybar'
if rg -n '"on-click[^" ]*": "(?:nwg-look|qalculate-gtk|pavucontrol|chromium|edge|firefox|thunderbird|~/.config/(?:waybar/themeswitcher|myhypr/settings/(?:installupdates|software))\.sh)' \
    "$modules" "$REPO_ROOT/defaults/.config/myhypr/settings/waybar-quicklinks.json" \
    "$REPO_ROOT"/dotfiles/.config/waybar/themes/*/config; then
    fail 'a directly launched interactive application remains in Waybar config'
fi
rg -Fq '"format": "󰍜"' "$modules" || fail 'neutral sidebar icon is missing'
rg -Fq '"~/.config/waybar/modules.json"' \
    "$REPO_ROOT/dotfiles/.config/waybar/themes/starter/config" || \
    fail 'starter theme does not use the shared module definitions'
if rg -Fq 'custom/starter' \
    "$REPO_ROOT/dotfiles/.config/waybar/themes/starter/config"; then
    fail 'starter theme references an undefined placeholder module'
fi
if rg -n 'myhypr-icon\.svg|' "$REPO_ROOT/dotfiles/.config/waybar"; then
    fail 'the old image logo remains in Waybar'
fi

printf 'Waybar Wi-Fi, resource monitor, and neutral menu actions passed.\n'
