#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes write literal mock-script variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-zoom-test.XXXXXXXX")
FAKE_BIN="$TEST_ROOT/bin"
export ZOOM_TEST_LOG="$TEST_ROOT/commands.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-zoom-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

mkdir -p -- "$FAKE_BIN"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ ${1:-} == -j ]]; then printf "{\"float\": 2.0}\n"; exit 0; fi' \
    'printf "hyprctl %s\n" "$*" >> "$ZOOM_TEST_LOG"' > "$FAKE_BIN/hyprctl"
chmod +x -- "$FAKE_BIN/hyprctl"

helper="$REPO_ROOT/dotfiles/.config/hypr/scripts/cursor-zoom.sh"
PATH="$FAKE_BIN:/usr/bin:/bin" "$helper" increase
PATH="$FAKE_BIN:/usr/bin:/bin" "$helper" decrease
PATH="$FAKE_BIN:/usr/bin:/bin" "$helper" reset

rg -Fqx 'hyprctl eval hl.config({ cursor = { zoom_factor = 2.5 } })' "$ZOOM_TEST_LOG"
rg -Fqx 'hyprctl eval hl.config({ cursor = { zoom_factor = 1.5 } })' "$ZOOM_TEST_LOG"
rg -Fqx 'hyprctl eval hl.config({ cursor = { zoom_factor = 1 } })' "$ZOOM_TEST_LOG"

if PATH="$FAKE_BIN:/usr/bin:/bin" "$helper" invalid >/dev/null 2>&1; then
    printf 'Invalid zoom action was accepted.\n' >&2
    exit 1
fi

printf 'Cursor zoom uses validated numeric Hyprland state.\n'
