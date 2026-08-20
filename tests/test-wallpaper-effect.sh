#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes write literal mock-script variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-effect-test.XXXXXXXX")
FAKE_BIN="$TEST_ROOT/bin"
export EFFECT_TEST_LOG="$TEST_ROOT/commands.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-effect-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

mkdir -p -- "$FAKE_BIN" "$TEST_ROOT/source images"
input="$TEST_ROOT/source images/wallpaper one.png"
output="$TEST_ROOT/generated images/effect one.png"
printf 'image\n' > "$input"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "magick" >> "$EFFECT_TEST_LOG"' \
    'printf " <%s>" "$@" >> "$EFFECT_TEST_LOG"' \
    'printf "\n" >> "$EFFECT_TEST_LOG"' \
    'destination=${!#}' \
    ': > "$destination"' > "$FAKE_BIN/magick"
chmod +x -- "$FAKE_BIN/magick"

helper="$REPO_ROOT/dotfiles/.config/hypr/scripts/wallpaper-effect.sh"
[[ $("$helper" --list | wc -l) -eq 14 ]]
PATH="$FAKE_BIN:/usr/bin:/bin" \
    "$helper" blackwhite-brightness40 "$input" "$output"
[[ -f $output ]]
rg -Fq "magick <$input> <-set> <colorspace> <Gray> <-separate> <-average> <$output>" \
    "$EFFECT_TEST_LOG"
rg -Fq "magick <$output> <-brightness-contrast> <-60%> <$output>" \
    "$EFFECT_TEST_LOG"

if PATH="$FAKE_BIN:/usr/bin:/bin" \
    "$helper" '../../command' "$input" "$output" >/dev/null 2>&1; then
    printf 'Unsupported wallpaper effect was accepted.\n' >&2
    exit 1
fi

printf 'Wallpaper effects are declarative and preserve spaced paths.\n'
