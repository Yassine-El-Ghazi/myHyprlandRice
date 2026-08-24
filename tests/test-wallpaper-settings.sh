#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes write literal fake-script variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-wallpaper-settings.XXXXXXXX")
FAKE_BIN="$TEST_ROOT/bin"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-wallpaper-settings.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Wallpaper settings test failed: %s\n' "$*" >&2
    exit 1
}

mkdir -p -- "$FAKE_BIN"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'destination=${!#}' \
    ': > "$destination"' \
    > "$FAKE_BIN/magick"
for command_name in matugen notify-send pywalfox swaync-client waypaper; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/$command_name"
done
chmod +x -- "$FAKE_BIN"/*

setup_home() {
    local test_home=$1
    local config_root="$test_home/.config"

    mkdir -p -- \
        "$config_root/myhypr/settings" "$config_root/myhypr/wallpapers" \
        "$config_root/hypr/scripts" "$config_root/waybar" \
        "$config_root/nwg-dock-hyprland"
    ln -s -- "$REPO_ROOT/dotfiles/.config/myhypr/library.sh" \
        "$config_root/myhypr/library.sh"
    printf 'image\n' > "$config_root/myhypr/wallpapers/default.jpg"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$config_root/waybar/launch.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' \
        > "$config_root/nwg-dock-hyprland/launch.sh"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'if [[ ${1:-} == --list ]]; then' \
        '    printf "blackwhite\n"' \
        '    exit 0' \
        'fi' \
        'printf "effect %s\n" "$1" >> "$WALLPAPER_TEST_LOG"' \
        '/usr/bin/cp -- "$2" "$3"' \
        > "$config_root/hypr/scripts/wallpaper-effect.sh"
    chmod +x -- \
        "$config_root/waybar/launch.sh" \
        "$config_root/nwg-dock-hyprland/launch.sh" \
        "$config_root/hypr/scripts/wallpaper-effect.sh"
}

test_effect() {
    local test_home="$TEST_ROOT/effect/home"
    local config_root="$test_home/.config"
    local input="$test_home/wallpaper.png"
    local log="$TEST_ROOT/effect.log"

    setup_home "$test_home"
    printf 'image\n' > "$input"
    printf 'blackwhite' > "$config_root/myhypr/settings/wallpaper-effect.sh"
    printf '50x30\n' > "$config_root/myhypr/settings/blur.sh"

    HOME="$test_home" PATH="$FAKE_BIN:/usr/bin:/bin" WALLPAPER_TEST_LOG="$log" \
        "$REPO_ROOT/dotfiles/.config/hypr/scripts/wallpaper.sh" "$input" \
        >/dev/null || fail 'valid no-newline wallpaper effect was rejected'
    if [[ ! -f $log ]] || ! rg -Fq 'effect blackwhite' "$log"; then
        fail 'valid no-newline wallpaper effect was silently disabled'
    fi
}

test_blur() {
    local test_home="$TEST_ROOT/blur/home"
    local config_root="$test_home/.config"
    local input="$test_home/wallpaper.png"

    setup_home "$test_home"
    printf 'image\n' > "$input"
    printf 'off\n' > "$config_root/myhypr/settings/wallpaper-effect.sh"
    printf '50x30' > "$config_root/myhypr/settings/blur.sh"

    HOME="$test_home" PATH="$FAKE_BIN:/usr/bin:/bin" \
        WALLPAPER_TEST_LOG="$TEST_ROOT/blur.log" \
        "$REPO_ROOT/dotfiles/.config/hypr/scripts/wallpaper.sh" "$input" \
        >/dev/null || fail 'valid no-newline blur setting stopped wallpaper processing'
    [[ -f $test_home/.cache/myhypr/blurred_wallpaper.png ]] || \
        fail 'wallpaper blur output was not completed'
}

case ${1:-all} in
    effect) test_effect ;;
    blur) test_blur ;;
    all)
        test_effect
        test_blur
        ;;
    *) fail "unknown test case: $1" ;;
esac

printf 'Wallpaper effect and blur accept no-newline settings.\n'
