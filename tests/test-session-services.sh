#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes write literal mock-script variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-session-test.XXXXXXXX")
FAKE_BIN="$TEST_ROOT/bin"
TEST_LOG="$TEST_ROOT/commands.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-session-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

mkdir -p -- "$FAKE_BIN"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "systemctl" >> "$SESSION_TEST_LOG"' \
    'printf " <%s>" "$@" >> "$SESSION_TEST_LOG"' \
    'printf "\n" >> "$SESSION_TEST_LOG"' > "$FAKE_BIN/systemctl"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "dbus-update-activation-environment" >> "$SESSION_TEST_LOG"' \
    'printf " <%s>" "$@" >> "$SESSION_TEST_LOG"' \
    'printf "\n" >> "$SESSION_TEST_LOG"' \
    > "$FAKE_BIN/dbus-update-activation-environment"
chmod +x -- "$FAKE_BIN/systemctl" "$FAKE_BIN/dbus-update-activation-environment"

env -i \
    HOME="$TEST_ROOT/home" \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    SESSION_TEST_LOG="$TEST_LOG" \
    DISPLAY=:99 \
    WAYLAND_DISPLAY=wayland-test \
    HYPRLAND_INSTANCE_SIGNATURE=hypr-test \
    XDG_CURRENT_DESKTOP=Hyprland \
    XDG_SESSION_TYPE=wayland \
    PRIVATE_API_TOKEN=must-not-leak \
    "$REPO_ROOT/dotfiles/.config/myhypr/scripts/start-session-services.sh"

expected_environment='<DISPLAY> <WAYLAND_DISPLAY> <HYPRLAND_INSTANCE_SIGNATURE> <XDG_CURRENT_DESKTOP> <XDG_SESSION_TYPE>'
rg -q "^systemctl <--user> <import-environment> $expected_environment$" \
    "$TEST_LOG"
rg -q "^dbus-update-activation-environment <--systemd> $expected_environment$" \
    "$TEST_LOG"
rg -q '^systemctl <--user> <start> <myhypr-session\.target>$' "$TEST_LOG"
if rg -q '^systemctl <--user> <start> <elephant\.service>' "$TEST_LOG"; then
    printf 'Session services bypassed their owning target.\n' >&2
    exit 1
fi
if rg -q 'PRIVATE_API_TOKEN|must-not-leak|<PATH>|<HOME>' "$TEST_LOG"; then
    printf 'A private or unrelated variable leaked into the user manager.\n' >&2
    exit 1
fi

for unit in elephant.service walker.service; do
    unit_path="$REPO_ROOT/dotfiles/.config/systemd/user/$unit"
    rg -q '^PartOf=myhypr-session\.target$' "$unit_path"
    rg -q '^Restart=on-failure$' "$unit_path"
    if rg -q '^WantedBy=' "$unit_path"; then
        printf 'Static session dependency unexpectedly uses enablement links.\n' >&2
        exit 1
    fi
done
rg -q '^ExecStart=/usr/bin/elephant$' \
    "$REPO_ROOT/dotfiles/.config/systemd/user/elephant.service"
rg -q '^ExecStart=/usr/bin/walker --gapplication-service$' \
    "$REPO_ROOT/dotfiles/.config/systemd/user/walker.service"
rg -q '^Type=dbus$' \
    "$REPO_ROOT/dotfiles/.config/systemd/user/walker.service"
rg -q '^BusName=dev\.benz\.walker$' \
    "$REPO_ROOT/dotfiles/.config/systemd/user/walker.service"
rg -q '^Requires=elephant\.service$' \
    "$REPO_ROOT/dotfiles/.config/systemd/user/walker.service"
rg -q '^Requires=elephant\.service walker\.service$' \
    "$REPO_ROOT/dotfiles/.config/systemd/user/myhypr-session.target"

printf 'Graphical services receive only allow-listed session variables.\n'
