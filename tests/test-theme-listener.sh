#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes write literal mock-script variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-theme-listener.XXXXXXXX")
TEST_HOME="$TEST_ROOT/home"
FAKE_BIN="$TEST_ROOT/bin"
export THEME_LISTENER_LOG="$TEST_ROOT/matugen.log"
export THEME_LISTENER_COUNT="$TEST_ROOT/matugen.count"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-theme-listener.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Theme listener test failed: %s\n' "$*" >&2
    exit 1
}

mkdir -p -- "$FAKE_BIN" "$TEST_HOME/.config/gtk-3.0" \
    "$TEST_HOME/.config/nwg-dock-hyprland" "$TEST_HOME/.config/waybar" \
    "$TEST_HOME/.config/hypr/scripts" "$TEST_HOME/.cache/myhypr"
printf 'gtk-application-prefer-dark-theme=1\n' \
    > "$TEST_HOME/.config/gtk-3.0/settings.ini"
printf 'wallpaper\n' > "$TEST_HOME/wallpaper.png"
printf '%s\n' "$TEST_HOME/wallpaper.png" \
    > "$TEST_HOME/.cache/myhypr/current_wallpaper"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "/tmp/ CLOSE_WRITE settings.ini\n"' \
    'printf "/tmp/ CLOSE_WRITE settings.ini\n"' > "$FAKE_BIN/inotifywait"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'count=0' \
    '[[ ! -r $THEME_LISTENER_COUNT ]] || count=$(<"$THEME_LISTENER_COUNT")' \
    'count=$((count + 1))' \
    'printf "%s\n" "$count" > "$THEME_LISTENER_COUNT"' \
    'printf "matugen %s\n" "$*" >> "$THEME_LISTENER_LOG"' \
    '[[ $count -ne 1 ]]' > "$FAKE_BIN/matugen"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/swaync-client"
for script in \
    "$TEST_HOME/.config/nwg-dock-hyprland/launch.sh" \
    "$TEST_HOME/.config/waybar/launch.sh" \
    "$TEST_HOME/.config/hypr/scripts/gtk.sh"; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$script"
done
chmod +x -- "$FAKE_BIN/inotifywait" "$FAKE_BIN/matugen" \
    "$FAKE_BIN/swaync-client" \
    "$TEST_HOME/.config/nwg-dock-hyprland/launch.sh" \
    "$TEST_HOME/.config/waybar/launch.sh" \
    "$TEST_HOME/.config/hypr/scripts/gtk.sh"

HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" \
    "$REPO_ROOT/dotfiles/.config/myhypr/listeners/gtk-theme-switcher.sh" \
    >"$TEST_ROOT/stdout.log" 2>"$TEST_ROOT/stderr.log"

[[ $(<"$THEME_LISTENER_COUNT") -eq 2 ]] || \
    fail 'listener stopped after the first transient Matugen failure'
[[ $(rg -c '^matugen image ' "$THEME_LISTENER_LOG") -eq 2 ]] || \
    fail 'listener did not process both GTK events'
rg -Fq 'Theme update failed; continuing to monitor GTK settings.' \
    "$TEST_ROOT/stderr.log" || fail 'transient failure was not reported'

printf 'GTK theme listener survives transient update failures.\n'
