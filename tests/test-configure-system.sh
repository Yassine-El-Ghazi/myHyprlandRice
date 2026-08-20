#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes write literal mock-script variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-system-test.XXXXXXXX")
FAKE_BIN="$TEST_ROOT/bin"
export SYSTEM_TEST_STATE="$TEST_ROOT/services-enabled"
export SYSTEM_TEST_ELEPHANT_ENABLED="$TEST_ROOT/elephant-enabled"
export SYSTEM_TEST_ELEPHANT_ACTIVE="$TEST_ROOT/elephant-active"
export SYSTEM_TEST_LOG="$TEST_ROOT/commands.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-system-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

mkdir -p -- "$FAKE_BIN"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ ${1:-} == --user ]]; then' \
    '  case ${2:-} in' \
    '    is-enabled) [[ -f $SYSTEM_TEST_ELEPHANT_ENABLED ]] ;;' \
    '    is-active) [[ -f $SYSTEM_TEST_ELEPHANT_ACTIVE ]] ;;' \
    '    start) : > "$SYSTEM_TEST_ELEPHANT_ACTIVE"; printf "systemctl %s\\n" "$*" >> "$SYSTEM_TEST_LOG" ;;' \
    '    *) exit 2 ;;' \
    '  esac' \
    '  exit' \
    'fi' \
    'case $1 in' \
    '  is-enabled|is-active) [[ -f $SYSTEM_TEST_STATE ]] ;;' \
    '  enable) : > "$SYSTEM_TEST_STATE"; printf "systemctl %s\\n" "$*" >> "$SYSTEM_TEST_LOG" ;;' \
    '  *) exit 2 ;;' \
    'esac' > "$FAKE_BIN/systemctl"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    '[[ ${1:-} == -v || ${1:-} == -n ]] && exit 0' \
    'exec "$@"' > "$FAKE_BIN/sudo"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    '[[ ${1:-} == service && ${2:-} == enable ]] || exit 2' \
    ': > "$SYSTEM_TEST_ELEPHANT_ENABLED"' \
    'printf "elephant %s\\n" "$*" >> "$SYSTEM_TEST_LOG"' \
    > "$FAKE_BIN/elephant"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "xdg-user-dirs-update\\n" >> "$SYSTEM_TEST_LOG"' \
    > "$FAKE_BIN/xdg-user-dirs-update"
chmod +x -- "$FAKE_BIN/systemctl" "$FAKE_BIN/sudo" "$FAKE_BIN/elephant" \
    "$FAKE_BIN/xdg-user-dirs-update"

WAYLAND_DISPLAY='' DISPLAY='' PATH="$FAKE_BIN:$PATH" \
    "$REPO_ROOT/scripts/configure-system.sh" --yes >/dev/null
[[ -f $SYSTEM_TEST_STATE ]]
rg -q '^systemctl enable --now NetworkManager\.service bluetooth\.service$' "$SYSTEM_TEST_LOG"
rg -q '^elephant service enable$' "$SYSTEM_TEST_LOG"
rg -q '^systemctl --user start elephant\.service$' "$SYSTEM_TEST_LOG"
rg -q '^xdg-user-dirs-update$' "$SYSTEM_TEST_LOG"

before=$(wc -l < "$SYSTEM_TEST_LOG")
WAYLAND_DISPLAY='' DISPLAY='' PATH="$FAKE_BIN:$PATH" \
    "$REPO_ROOT/scripts/configure-system.sh" --yes >/dev/null
after=$(wc -l < "$SYSTEM_TEST_LOG")
((after == before + 1)) # Only the idempotent user-directory refresh reruns.

printf 'Required service configuration is automatic and idempotent.\n'
