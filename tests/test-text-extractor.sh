#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-ocr-test.XXXXXXXX")
FAKE_BIN="$TEST_ROOT/bin"
export OCR_COPY_LOG="$TEST_ROOT/wl-copy.log"
export OCR_COPY_DATA="$TEST_ROOT/wl-copy.data"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-ocr-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT
fail() { printf 'OCR test failed: %s\n' "$*" >&2; exit 1; }

mkdir -p -- "$FAKE_BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/hyprpicker"
printf '#!/usr/bin/env bash\nprintf "0,0 10x10\\n"\n' > "$FAKE_BIN/slurp"
printf '#!/usr/bin/env bash\nprintf "image bytes"\n' > "$FAKE_BIN/grim"
printf '#!/usr/bin/env bash\ncat\n' > "$FAKE_BIN/magick"
printf '%s\n' '#!/usr/bin/env bash' \
    '[[ ${OCR_TEST_FAIL:-0} -eq 0 ]] || exit 9' \
    'cat >/dev/null' \
    'printf "recognized text\n"' > "$FAKE_BIN/tesseract"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "called\n" >> "$OCR_COPY_LOG"' \
    'cat > "$OCR_COPY_DATA"' > "$FAKE_BIN/wl-copy"
printf '%s\n' '#!/usr/bin/env bash' \
    '[[ ${1:-} == -Qq ]] && printf "tesseract-data-eng\n"' \
    > "$FAKE_BIN/pacman"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/rofi"
chmod +x -- "$FAKE_BIN"/*

extractor="$REPO_ROOT/dotfiles/.config/hypr/scripts/text-extractor.sh"
PATH="$FAKE_BIN:/usr/bin:/bin" "$extractor"
[[ $(<"$OCR_COPY_DATA") == 'recognized text' ]] || \
    fail 'successful OCR output was not copied'

: > "$OCR_COPY_LOG"
if OCR_TEST_FAIL=1 PATH="$FAKE_BIN:/usr/bin:/bin" "$extractor" 2>/dev/null; then
    fail 'failed OCR returned success'
fi
[[ ! -s $OCR_COPY_LOG ]] || fail 'failed OCR invoked the clipboard writer'

printf 'OCR writes to the clipboard only after successful extraction.\n'
