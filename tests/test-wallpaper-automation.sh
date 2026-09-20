#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes write literal mock-script variables.
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
if [[ ${1:-} != --subreaper ]]; then
    exec python3 "$REPO_ROOT/tests/wallpaper-subreaper.py"
fi
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-wallpaper-auto.XXXXXXXX")
TEST_HOME="$TEST_ROOT/home"
FAKE_BIN="$TEST_ROOT/bin"
export WALLPAPER_CHILD_PID="$TEST_ROOT/waypaper.pid"

cleanup() {
    local pid=''
    if [[ -r $TEST_HOME/.cache/myhypr/wallpaper-automation.pid ]]; then
        IFS= read -r pid < "$TEST_HOME/.cache/myhypr/wallpaper-automation.pid" || true
        [[ ! $pid =~ ^[0-9]+$ ]] || kill -KILL "$pid" 2>/dev/null || true
    fi
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-wallpaper-auto.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT
fail() { printf 'Wallpaper automation test failed: %s\n' "$*" >&2; exit 1; }

mkdir -p -- "$FAKE_BIN" "$TEST_HOME/.config/myhypr/settings"
printf '10\n' > "$TEST_HOME/.config/myhypr/settings/wallpaper-automation.sh"
printf '%s\n' '#!/usr/bin/env bash' \
    '[[ " $* " == *" --no-post-command "* ]] || exit 64' \
    'printf "%s\n" "$$" > "$WALLPAPER_CHILD_PID"' \
    'exec sleep 30' > "$FAKE_BIN/waypaper"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/notify-send"
chmod +x -- "$FAKE_BIN"/*

automation="$REPO_ROOT/dotfiles/.config/hypr/scripts/wallpaper-automation.sh"
HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" "$automation" --start >/dev/null
HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" "$automation" --status >/dev/null || \
    fail 'started worker was not reported as running'
pid=$(<"$TEST_HOME/.cache/myhypr/wallpaper-automation.pid")
for ((attempt = 0; attempt < 40; attempt++)); do
    [[ ! -s $WALLPAPER_CHILD_PID ]] || break
    sleep 0.05
done
[[ -s $WALLPAPER_CHILD_PID ]] || fail 'wallpaper child did not start'
child_pid=$(<"$WALLPAPER_CHILD_PID")
HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" "$automation" --stop >/dev/null
# The harness deliberately retains the exited worker; kill -0 still succeeds.
[[ -r /proc/$pid/stat ]] || fail 'subreaper did not retain the worker'
worker_stat=$(<"/proc/$pid/stat")
worker_stat=${worker_stat##*) }
[[ ${worker_stat%% *} == Z ]] || fail 'stopped worker remained alive'
kill -0 "$child_pid" 2>/dev/null && fail 'stopped worker left its wallpaper child alive'
[[ ! -e $TEST_HOME/.cache/myhypr/wallpaper-automation.pid ]] || \
    fail 'stopped worker retained its PID file'
if HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" \
    "$automation" --status >/dev/null; then
    fail 'stopped worker was reported as running'
fi

# An unrelated live PID in a stale marker must never be terminated.
printf '%s\n' "$$" > "$TEST_HOME/.cache/myhypr/wallpaper-automation.pid"
HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" "$automation" --stop >/dev/null
[[ ! -e $TEST_HOME/.cache/myhypr/wallpaper-automation.pid ]] || \
    fail 'unrelated PID marker was not cleared'

printf 'Wallpaper automation starts, reports, and stops one owned worker.\n'
