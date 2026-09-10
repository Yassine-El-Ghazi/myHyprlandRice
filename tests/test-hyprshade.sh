#!/usr/bin/env bash
# shellcheck disable=SC2016  # Mock scripts deliberately retain their variables.
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-hyprshade.XXXXXXXX")
cleanup() {
    case $TEST_ROOT in
    "${TMPDIR:-/tmp}"/myhypr-hyprshade.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/config/myhypr/settings"
export HYPRSHADE_TEST_LOG="$TEST_ROOT/log"

printf '%s\n' '#!/usr/bin/env bash' \
    'case ${1:-} in' \
    '  ls) printf "  blue-light-filter\\n  vibrance\\n" ;;' \
    '  current) exit 0 ;;' \
    '  *) printf "%s\\n" "$*" > "$HYPRSHADE_TEST_LOG" ;;' \
    'esac' >"$TEST_ROOT/bin/hyprshade"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$TEST_ROOT/bin/notify-send"
chmod +x "$TEST_ROOT/bin/hyprshade" "$TEST_ROOT/bin/notify-send"
printf '%s\n' blue-light-filter >"$TEST_ROOT/config/myhypr/settings/hyprshade.sh"

HOME="$TEST_ROOT" XDG_CONFIG_HOME="$TEST_ROOT/config" PATH="$TEST_ROOT/bin:/usr/bin:/bin" \
    "$REPO_ROOT/dotfiles/.config/hypr/scripts/hyprshade.sh"
[[ $(<"$HYPRSHADE_TEST_LOG") == 'on blue-light-filter' ]]

printf '%s\n' blue-light-filter-50 >"$TEST_ROOT/config/myhypr/settings/hyprshade.sh"
if HOME="$TEST_ROOT" XDG_CONFIG_HOME="$TEST_ROOT/config" PATH="$TEST_ROOT/bin:/usr/bin:/bin" \
    "$REPO_ROOT/dotfiles/.config/hypr/scripts/hyprshade.sh" 2>/dev/null; then
    printf 'Obsolete Hyprshade selection was accepted.\n' >&2
    exit 1
fi

printf 'Hyprshade uses an available filter and rejects obsolete selections.\n'
