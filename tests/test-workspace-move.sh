#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-workspace-move.XXXXXXXX")
FAKE_BIN="$TEST_ROOT/bin"
export WORKSPACE_MOVE_LOG="$TEST_ROOT/hyprctl.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-workspace-move.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

mkdir -p -- "$FAKE_BIN"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "$*" in' \
    '  "-j activeworkspace") printf "%s\\n" '\''{"id":2}'\'' ;;' \
    '  "-j clients")' \
    '    case ${WORKSPACE_MOVE_SCENARIO:-multi} in' \
    '      multi) printf "%s\\n" '\''[{"address":"0xaaa","workspace":{"id":2}},{"address":"0xbbb","workspace":{"id":2}},{"address":"0xccc","workspace":{"id":4}}]'\'' ;;' \
    '      empty) printf "%s\\n" '\''[{"address":"0xccc","workspace":{"id":4}}]'\'' ;;' \
    '      failed) exit 42 ;;' \
    '      invalid-json) printf "%s\\n" '\''[{"address":"0xaaa"'\'' ;;' \
    '      malformed) printf "%s\\n" '\''[{"address":"0xaaa","workspace":{"id":2}},{"address":"0xnothex","workspace":{"id":2}}]'\'' ;;' \
    '    esac' \
    '    ;;' \
    '  *) printf "hyprctl %s\\n" "$*" >> "$WORKSPACE_MOVE_LOG" ;;' \
    'esac' \
    > "$FAKE_BIN/hyprctl"
chmod +x -- "$FAKE_BIN/hyprctl"

helper="$REPO_ROOT/dotfiles/.config/hypr/scripts/moveTo.sh"

PATH="$FAKE_BIN:/usr/bin:/bin" "$helper" 7
mapfile -t calls < "$WORKSPACE_MOVE_LOG"
[[ ${calls[0]:-} == "hyprctl dispatch hl.dsp.window.move({ workspace = 7, follow = false, window = 'address:0xaaa' })" ]]
[[ ${calls[1]:-} == "hyprctl dispatch hl.dsp.window.move({ workspace = 7, follow = false, window = 'address:0xbbb' })" ]]
[[ ${calls[2]:-} == 'hyprctl dispatch hl.dsp.focus({ workspace = 7 })' ]]
[[ ${#calls[@]} -eq 3 ]]

: > "$WORKSPACE_MOVE_LOG"
WORKSPACE_MOVE_SCENARIO=empty PATH="$FAKE_BIN:/usr/bin:/bin" "$helper" 7
mapfile -t calls < "$WORKSPACE_MOVE_LOG"
[[ ${calls[0]:-} == 'hyprctl dispatch hl.dsp.focus({ workspace = 7 })' ]]
[[ ${#calls[@]} -eq 1 ]]

: > "$WORKSPACE_MOVE_LOG"
if WORKSPACE_MOVE_SCENARIO=failed PATH="$FAKE_BIN:/usr/bin:/bin" "$helper" 7; then
    printf 'Workspace helper accepted a failed client query.\n' >&2
    exit 1
fi
[[ ! -s $WORKSPACE_MOVE_LOG ]]

: > "$WORKSPACE_MOVE_LOG"
if WORKSPACE_MOVE_SCENARIO=invalid-json PATH="$FAKE_BIN:/usr/bin:/bin" "$helper" 7; then
    printf 'Workspace helper accepted malformed client JSON.\n' >&2
    exit 1
fi
[[ ! -s $WORKSPACE_MOVE_LOG ]]

: > "$WORKSPACE_MOVE_LOG"
if WORKSPACE_MOVE_SCENARIO=malformed PATH="$FAKE_BIN:/usr/bin:/bin" "$helper" 7; then
    printf 'Workspace helper accepted a malformed later address.\n' >&2
    exit 1
fi
[[ ! -s $WORKSPACE_MOVE_LOG ]]

before=$(wc -l < "$WORKSPACE_MOVE_LOG")
if PATH="$FAKE_BIN:/usr/bin:/bin" "$helper" '7); os.execute("touch /tmp/bad")'; then
    printf 'Workspace helper accepted an unsafe destination.\n' >&2
    exit 1
fi
after=$(wc -l < "$WORKSPACE_MOVE_LOG")
[[ $before -eq $after ]]

printf 'Workspace movement validates input and uses typed dispatchers.\n'
