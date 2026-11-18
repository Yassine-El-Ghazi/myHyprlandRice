#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
SETTINGS_ROOT="$CONFIG_ROOT/myhypr/settings"
LOCK_ROOT="${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/myhypr}"
dock_command=$(type -P nwg-dock-hyprland || true)
dock_executable=''
if [[ -n $dock_command ]]; then
    dock_executable=$(readlink -f -- "$dock_command")
fi

mkdir -p -- "$LOCK_ROOT"
exec {LOCK_FD}>>"$LOCK_ROOT/myhypr-dock-launch.lock"
flock "$LOCK_FD"

dock_is_running() {
    local executable
    executable=$(readlink -- "/proc/$1/exe" 2>/dev/null) || return 1
    # An in-place package upgrade can leave the running binary unlinked.
    [[ $executable == "$dock_executable" || $executable == "$dock_executable (deleted)" ]]
}

stop_dock() {
    local pids pid stopped='' status=0

    [[ -n $dock_executable ]] || return 0
    pids=$(pgrep -u "$EUID") || status=$?
    ((status <= 1)) || return "$status"
    for pid in $pids; do
        dock_is_running "$pid" || continue
        if kill -- "$pid" 2>/dev/null; then
            stopped+=${stopped:+,}$pid
        elif dock_is_running "$pid"; then
            printf 'Unable to signal the running dock.\n' >&2
            return 1
        fi
    done
    [[ -n $stopped ]] || return 0

    # The old process can exit before pidwait finds it.
    status=0
    timeout 2s pidwait -u "$EUID" --pid "$stopped" || status=$?
    if ((status > 1)); then
        printf 'Unable to stop the running dock.\n' >&2
        return 1
    fi
}

if [[ -f $SETTINGS_ROOT/dock-disabled ]]; then
    stop_dock
    printf 'Dock is disabled by the runtime setting.\n'
    exit 0
fi

theme=modern
[[ -r $SETTINGS_ROOT/dock-theme ]] && theme=$(<"$SETTINGS_ROOT/dock-theme")
[[ $theme =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    printf 'Invalid dock theme: %s\n' "$theme" >&2
    exit 1
}
style_relative="themes/$theme/style.css"
style="$CONFIG_ROOT/nwg-dock-hyprland/$style_relative"
[[ -f $style ]] || {
    printf 'Dock theme is unavailable: %s\n' "$style" >&2
    exit 1
}

stop_dock

arguments=(
    -i 32 -w 5 -mb 10 -x
    -s "$style_relative"
    -c "$CONFIG_ROOT/hypr/scripts/launcher.sh"
)
[[ ! -f $SETTINGS_ROOT/dock-autohide ]] || arguments=(-d "${arguments[@]}")
nwg-dock-hyprland "${arguments[@]}" {LOCK_FD}>&- &
dock_pid=$!
trap 'kill "$dock_pid" 2>/dev/null || true; exit 143' TERM
trap 'kill "$dock_pid" 2>/dev/null || true; exit 130' INT

# Keep the lock until the new process can be found by stop_dock. A dock
# that exits during startup passes its status back to the caller.
for _attempt in {1..40}; do
    if ! kill -0 "$dock_pid" 2>/dev/null; then
        wait "$dock_pid"
        exit 0
    fi
    if dock_is_running "$dock_pid"; then
        exec {LOCK_FD}>&-
        dock_status=0
        wait "$dock_pid" || dock_status=$?
        # A queued restart or disable can stop this dock right after startup.
        [[ $dock_status -ne 143 ]] || exit 0
        exit "$dock_status"
    fi
    sleep 0.05
done

kill "$dock_pid" 2>/dev/null || true
printf 'Unable to confirm that the dock started.\n' >&2
exit 1
