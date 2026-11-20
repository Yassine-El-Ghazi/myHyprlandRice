#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes write literal mock-script variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-dock-launch.XXXXXXXX")
TEST_HOME="$TEST_ROOT/home"
CONFIG_ROOT="$TEST_HOME/.config"
SETTINGS_ROOT="$CONFIG_ROOT/myhypr/settings"
FAKE_BIN="$TEST_ROOT/bin"
LAUNCHER="$REPO_ROOT/dotfiles/.config/nwg-dock-hyprland/launch.sh"
export DOCK_LAUNCH_TEST_ROOT="$TEST_ROOT"
export DOCK_LAUNCH_TEST_LOG="$TEST_ROOT/commands.log"
dock_pid=''
unrelated_pid=''

cleanup() {
    local pid
    for pid in "$dock_pid" "$unrelated_pid"; do
        [[ -n $pid ]] || continue
        kill -- "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
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
    "$SETTINGS_ROOT" \
    "$CONFIG_ROOT/nwg-dock-hyprland/themes/glass" \
    "$CONFIG_ROOT/hypr/scripts" "$FAKE_BIN" "$TEST_ROOT/runtime"
printf 'glass\n' > "$SETTINGS_ROOT/dock-theme"
printf 'window {}\n' > "$CONFIG_ROOT/nwg-dock-hyprland/themes/glass/style.css"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CONFIG_ROOT/hypr/scripts/launcher.sh"
ln -s -- "$LAUNCHER" "$CONFIG_ROOT/nwg-dock-hyprland/launch.sh"

cat > "$FAKE_BIN/pkill" <<'BASH'
#!/usr/bin/env bash
printf 'Unexpected group signal: pkill %s\n' "$*" >&2
exit 2
BASH
cat > "$FAKE_BIN/pgrep" <<'BASH'
#!/usr/bin/env bash
[[ $# -eq 2 && $1 == -u && $2 == "$EUID" ]] || exit 2
printf 'pgrep %s\n' "$*" >> "$DOCK_LAUNCH_TEST_LOG"
root=$DOCK_LAUNCH_TEST_ROOT
if [[ -e $root/pause-stop ]] && mkdir "$root/first-stop" 2>/dev/null; then
    for _attempt in {1..100}; do
        [[ ! -e $root/release-stop ]] || break
        sleep 0.02
    done
    [[ -e $root/release-stop ]] || exit 2
fi
[[ -f $root/processes ]] && cat -- "$root/processes"
BASH
cat > "$FAKE_BIN/flock" <<'BASH'
#!/usr/bin/env bash
printf 'lock\n' >> "$DOCK_LAUNCH_TEST_ROOT/lock-attempts"
exec /usr/bin/flock "$@"
BASH
cat > "$FAKE_BIN/nwg-dock-hyprland" <<'BASH'
#!/usr/bin/env bash
printf 'dock %s\n' "$*" >> "$DOCK_LAUNCH_TEST_LOG"
BASH
chmod +x -- "$FAKE_BIN"/* "$CONFIG_ROOT/hypr/scripts/launcher.sh"

run_in_fixture() {
    HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" XDG_RUNTIME_DIR="$TEST_ROOT/runtime" \
        PATH="$FAKE_BIN:$PATH" timeout 5s "$@"
}

run_in_fixture "$LAUNCHER"

rg -Fq \
    "dock -i 32 -w 5 -mb 10 -x -s themes/glass/style.css -c $CONFIG_ROOT/hypr/scripts/launcher.sh" \
    "$DOCK_LAUNCH_TEST_LOG" || \
    fail 'the selected relative theme and launcher were not passed to the dock'

: > "$DOCK_LAUNCH_TEST_LOG"
: > "$TEST_ROOT/lock-attempts"
: > "$TEST_ROOT/pause-stop"
run_in_fixture "$LAUNCHER" & first=$!
for _attempt in {1..100}; do
    [[ ! -d $TEST_ROOT/first-stop ]] || break
    sleep 0.02
done
[[ -d $TEST_ROOT/first-stop ]] || fail 'first launcher did not reach the stop step'
run_in_fixture "$LAUNCHER" & second=$!
for _attempt in {1..100}; do
    [[ $(wc -l < "$TEST_ROOT/lock-attempts") -lt 2 ]] || break
    sleep 0.02
done
[[ $(wc -l < "$TEST_ROOT/lock-attempts") -eq 2 ]] || fail 'second launcher did not attempt to acquire the lock'
[[ $(rg -c '^pgrep ' "$DOCK_LAUNCH_TEST_LOG") -eq 1 ]] || fail 'stop steps overlapped'
: > "$TEST_ROOT/release-stop"
wait "$first" || fail 'first dock launch did not complete'
wait "$second" || fail 'second dock launch did not complete'
[[ $(rg -c '^dock ' "$DOCK_LAUNCH_TEST_LOG") -eq 2 ]] || fail 'a queued launch was lost'

: > "$DOCK_LAUNCH_TEST_LOG"
cp -- "$(type -P sleep)" "$FAKE_BIN/nwg-dock-hyprland"
"$FAKE_BIN/nwg-dock-hyprland" 20 & dock_pid=$!
python3 -c 'import time; time.sleep(20)' "$FAKE_BIN/nwg-dock-hyprland" & unrelated_pid=$!
printf '%s\n' "$dock_pid" "$unrelated_pid" > "$TEST_ROOT/processes"
for _attempt in {1..100}; do
    [[ ! /proc/$dock_pid/exe -ef $FAKE_BIN/nwg-dock-hyprland ]] || break
    sleep 0.02
done
[[ /proc/$dock_pid/exe -ef $FAKE_BIN/nwg-dock-hyprland ]] || fail 'dock fixture did not start'
# Replacing the package leaves the running executable unlinked.
cp -- "$(type -P sleep)" "$TEST_ROOT/new-dock"
mv -- "$TEST_ROOT/new-dock" "$FAKE_BIN/nwg-dock-hyprland"
printf 'missing-theme\n' > "$SETTINGS_ROOT/dock-theme"
: > "$SETTINGS_ROOT/dock-disabled"
run_in_fixture "$REPO_ROOT/dotfiles/.config/myhypr/bin/desktopctl" set dock disabled || \
    fail 'disabling a running dock failed with a missing theme and an existing marker'
if kill -0 "$dock_pid" 2>/dev/null; then
    fail 'the running dock was not stopped'
fi
dock_pid=''
kill -0 "$unrelated_pid" 2>/dev/null || fail 'disable stopped an unrelated command carrying the dock path'

printf 'Dock replacements are serialized and disable targets only the dock executable.\n'
