#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes write literal mock-script variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-desktopctl-test.XXXXXXXX")
TEST_HOME="$TEST_ROOT/home"
CONFIG_ROOT="$TEST_HOME/.config"
FAKE_BIN="$TEST_ROOT/bin"
export DESKTOPCTL_TEST_LOG="$TEST_ROOT/commands.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-desktopctl-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'desktopctl test failed: %s\n' "$*" >&2
    exit 1
}

mkdir -p -- \
    "$CONFIG_ROOT/myhypr/settings" "$CONFIG_ROOT/waybar" \
    "$CONFIG_ROOT/nwg-dock-hyprland" "$CONFIG_ROOT/hypr/scripts" "$FAKE_BIN"

printf '#!/usr/bin/env bash\nprintf "waybar\\n" >> "$DESKTOPCTL_TEST_LOG"\n' \
    > "$CONFIG_ROOT/waybar/launch.sh"
printf '#!/usr/bin/env bash\nprintf "dock\\n" >> "$DESKTOPCTL_TEST_LOG"\n' \
    > "$CONFIG_ROOT/nwg-dock-hyprland/launch.sh"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'marker="${XDG_CONFIG_HOME}/myhypr/settings/gamemode-enabled"' \
    '[[ -f $marker ]] && rm -f -- "$marker" || : > "$marker"' \
    > "$CONFIG_ROOT/hypr/scripts/gamemode.sh"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ $1 == get-volume ]]; then printf "Volume: 0.42\\n"; else printf "wpctl %s\\n" "$*" >> "$DESKTOPCTL_TEST_LOG"; fi' \
    > "$FAKE_BIN/wpctl"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ $1 == -m ]]; then printf "device,class,0,73%%\\n"; else printf "brightness %s\\n" "$*" >> "$DESKTOPCTL_TEST_LOG"; fi' \
    > "$FAKE_BIN/brightnessctl"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ $* == "radio wifi" ]]; then printf "enabled\\n"; else printf "nmcli %s\\n" "$*" >> "$DESKTOPCTL_TEST_LOG"; fi' \
    > "$FAKE_BIN/nmcli"
chmod +x -- \
    "$CONFIG_ROOT/waybar/launch.sh" \
    "$CONFIG_ROOT/nwg-dock-hyprland/launch.sh" \
    "$CONFIG_ROOT/hypr/scripts/gamemode.sh" \
    "$FAKE_BIN/wpctl" "$FAKE_BIN/brightnessctl" "$FAKE_BIN/nmcli"

run_ctl() {
    HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" PATH="$FAKE_BIN:$PATH" \
        "$REPO_ROOT/dotfiles/.config/myhypr/bin/desktopctl" "$@"
}

[[ $(run_ctl status waybar) == enabled ]] || fail 'Waybar should start enabled'
run_ctl set waybar disabled
[[ $(run_ctl status waybar) == disabled ]] || fail 'Waybar disable marker was not applied'
run_ctl set waybar enabled
[[ $(run_ctl status waybar) == enabled ]] || fail 'Waybar was not re-enabled'

run_ctl set dock disabled
[[ $(run_ctl status dock) == disabled ]] || fail 'dock disable marker was not applied'
run_ctl set dock enabled
sleep 0.1
[[ $(run_ctl status dock) == enabled ]] || fail 'dock was not re-enabled'

run_ctl set gamemode enabled
[[ $(run_ctl status gamemode) == enabled ]] || fail 'gamemode was not enabled'
run_ctl set gamemode disabled
[[ $(run_ctl status gamemode) == disabled ]] || fail 'gamemode was not disabled'

[[ $(run_ctl audio get) == 42 ]] || fail 'audio percentage parsing failed'
run_ctl audio set 75
if run_ctl audio set 101 >/dev/null 2>&1; then
    fail 'invalid audio percentage was accepted'
fi
[[ $(run_ctl brightness get) == 73 ]] || fail 'brightness percentage parsing failed'
run_ctl brightness set 80
if run_ctl brightness set 9 >/dev/null 2>&1; then
    fail 'invalid brightness percentage was accepted'
fi
[[ $(run_ctl wifi get) == true ]] || fail 'Wi-Fi state parsing failed'
run_ctl wifi set disabled
SWAYNC_TOGGLE_STATE=true run_ctl wifi set
if run_ctl wifi set invalid >/dev/null 2>&1; then
    fail 'invalid Wi-Fi state was accepted'
fi

rg -q '^waybar$' "$DESKTOPCTL_TEST_LOG"
rg -q '^dock$' "$DESKTOPCTL_TEST_LOG"
rg -q '^wpctl set-volume @DEFAULT_AUDIO_SINK@ 75%$' "$DESKTOPCTL_TEST_LOG"
rg -q '^brightness set 80%$' "$DESKTOPCTL_TEST_LOG"
rg -q '^nmcli radio wifi off$' "$DESKTOPCTL_TEST_LOG"
rg -q '^nmcli radio wifi on$' "$DESKTOPCTL_TEST_LOG"

printf 'Desktop state, audio, brightness, and Wi-Fi controls passed.\n'
