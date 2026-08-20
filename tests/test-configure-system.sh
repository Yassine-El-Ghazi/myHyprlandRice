#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes write literal mock-script variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-system-test.XXXXXXXX")
FAKE_BIN="$TEST_ROOT/bin"
TEST_HOME="$TEST_ROOT/home"
export SYSTEM_TEST_STATE_DIR="$TEST_ROOT/state"
export SYSTEM_TEST_LOG="$TEST_ROOT/commands.log"
export SYSTEM_TEST_USER_UNIT_DIR="$TEST_HOME/.config/systemd/user"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-system-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

mkdir -p -- \
    "$FAKE_BIN" \
    "$SYSTEM_TEST_STATE_DIR" \
    "$SYSTEM_TEST_USER_UNIT_DIR/graphical-session.target.wants" \
    "$SYSTEM_TEST_USER_UNIT_DIR/myhypr-session.target.wants"
for unit in myhypr-session.target elephant.service walker.service; do
    ln -s -- "$REPO_ROOT/dotfiles/.config/systemd/user/$unit" \
        "$SYSTEM_TEST_USER_UNIT_DIR/$unit"
done
for wants_dir in graphical-session.target.wants myhypr-session.target.wants; do
    for unit in elephant.service walker.service; do
        ln -s -- "../$unit" "$SYSTEM_TEST_USER_UNIT_DIR/$wants_dir/$unit"
    done
done

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'log() { printf "systemctl" >> "$SYSTEM_TEST_LOG"; printf " <%s>" "$@" >> "$SYSTEM_TEST_LOG"; printf "\n" >> "$SYSTEM_TEST_LOG"; }' \
    'if [[ ${1:-} == --user ]]; then' \
    '  case ${2:-} in' \
    '    daemon-reload|import-environment) log "$@" ;;' \
    '    is-active) [[ -f $SYSTEM_TEST_STATE_DIR/${3}.active ]] ;;' \
    '    start)' \
    '      log "$@"' \
    '      for unit in "${@:3}"; do' \
    '        : > "$SYSTEM_TEST_STATE_DIR/${unit}.active"' \
    '        if [[ $unit == myhypr-session.target ]]; then' \
    '          : > "$SYSTEM_TEST_STATE_DIR/elephant.service.active"' \
    '          : > "$SYSTEM_TEST_STATE_DIR/walker.service.active"' \
    '        fi' \
    '      done' \
    '      ;;' \
    '    *) exit 2 ;;' \
    '  esac' \
    '  exit' \
    'fi' \
    'case ${1:-} in' \
    '  is-enabled|is-active) [[ -f $SYSTEM_TEST_STATE_DIR/system-services-ready ]] ;;' \
    '  enable) : > "$SYSTEM_TEST_STATE_DIR/system-services-ready"; log "$@" ;;' \
    '  *) exit 2 ;;' \
    'esac' > "$FAKE_BIN/systemctl"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    '[[ ${1:-} == -v || ${1:-} == -n ]] && exit 0' \
    'exec "$@"' > "$FAKE_BIN/sudo"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$FAKE_BIN/elephant"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$FAKE_BIN/walker"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "dbus-update-activation-environment" >> "$SYSTEM_TEST_LOG"' \
    'printf " <%s>" "$@" >> "$SYSTEM_TEST_LOG"' \
    'printf "\n" >> "$SYSTEM_TEST_LOG"' \
    > "$FAKE_BIN/dbus-update-activation-environment"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "xdg-user-dirs-update\n" >> "$SYSTEM_TEST_LOG"' \
    > "$FAKE_BIN/xdg-user-dirs-update"
chmod +x -- "$FAKE_BIN"/*

run_configure() {
    HOME="$TEST_HOME" \
    DISPLAY='' \
    WAYLAND_DISPLAY=wayland-test \
    HYPRLAND_INSTANCE_SIGNATURE=hypr-test \
    XDG_CURRENT_DESKTOP=Hyprland \
    XDG_SESSION_TYPE=wayland \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
        "$REPO_ROOT/scripts/configure-system.sh" --yes >/dev/null
}

run_configure
[[ -f $SYSTEM_TEST_STATE_DIR/system-services-ready ]]
[[ -f $SYSTEM_TEST_STATE_DIR/myhypr-session.target.active ]]
[[ -f $SYSTEM_TEST_STATE_DIR/elephant.service.active ]]
[[ -f $SYSTEM_TEST_STATE_DIR/walker.service.active ]]
rg -q '^systemctl <enable> <--now> <NetworkManager\.service> <bluetooth\.service>$' \
    "$SYSTEM_TEST_LOG"
rg -q '^systemctl <--user> <start> <myhypr-session\.target>$' \
    "$SYSTEM_TEST_LOG"
if rg -q '^systemctl <--user> <enable>' "$SYSTEM_TEST_LOG"; then
    printf 'Static MyHypr dependencies unexpectedly used systemctl enable.\n' >&2
    exit 1
fi
rg -q '^xdg-user-dirs-update$' "$SYSTEM_TEST_LOG"
for wants_dir in graphical-session.target.wants myhypr-session.target.wants; do
    [[ ! -e $SYSTEM_TEST_USER_UNIT_DIR/$wants_dir/elephant.service ]]
    [[ ! -e $SYSTEM_TEST_USER_UNIT_DIR/$wants_dir/walker.service ]]
done

system_enable_count=$(rg -c '^systemctl <enable> <--now>' "$SYSTEM_TEST_LOG")
run_configure
[[ $(rg -c '^systemctl <enable> <--now>' "$SYSTEM_TEST_LOG") -eq \
    $system_enable_count ]]
[[ $(rg -c '^xdg-user-dirs-update$' "$SYSTEM_TEST_LOG") -eq 2 ]]

printf 'Required system and graphical-session services are automatic and idempotent.\n'
