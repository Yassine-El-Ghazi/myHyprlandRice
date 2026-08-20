#!/usr/bin/env bash
# Script by https://github.com/anshifmonz

set -Eeuo pipefail

PICKER_PID=''
SLURP_TIMEOUT=10
DEPS=(grim slurp magick tesseract wl-copy timeout hyprpicker rofi)

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
safe_kill() { [[ -n "${1:-}" ]] && kill "$1" 2>/dev/null || true; }
cleanup() { safe_kill "$PICKER_PID"; }
trap cleanup EXIT INT TERM

# Check dependencies
check_deps() {
    local missing_dependencies=()
    local dep
    for dep in "${DEPS[@]}"; do
        command -v "$dep" >/dev/null 2>&1 || missing_dependencies+=("$dep")
    done
    ((${#missing_dependencies[@]} == 0)) || \
        die "Missing dependencies: ${missing_dependencies[*]}"
}

check_deps

if command -v pacman >/dev/null 2>&1; then
    mapfile -t ocr_languages < <(
        pacman -Qq | awk -F- '/^tesseract-(ocr|data|langpack)-/ {print $NF}' | sort -u
    )
elif command -v dnf >/dev/null 2>&1; then
    mapfile -t ocr_languages < <(
        dnf list --installed | awk -F- '/tesseract-(ocr|data|langpack)-/ {print $NF}' | sort -u
    )
elif command -v zypper >/dev/null 2>&1; then
    mapfile -t ocr_languages < <(
        zypper se -i | awk -F- '/tesseract-(ocr|data|langpack)-/ {print $NF}' | sort -u
    )
else
    ocr_languages=()
fi

rofi_cmd() {
    rofi -dmenu -replace -config "$HOME/.config/rofi/config-ocr-lang.rasi" \
        -i -no-show-icons -l 3 -width 30 -p 'Select the OCR language'
}

OCR_LANGUAGE=eng
if ((${#ocr_languages[@]} == 1)); then
    OCR_LANGUAGE=${ocr_languages[0]}
elif ((${#ocr_languages[@]} > 1)); then
    OCR_LANGUAGE=$(printf '%s\n' "${ocr_languages[@]}" | rofi_cmd) || exit 0
    [[ -n $OCR_LANGUAGE ]] || exit 0
    sleep 0.5
fi
[[ $OCR_LANGUAGE =~ ^[A-Za-z0-9_+.-]+$ ]] || die 'Invalid OCR language selected'

hyprpicker -r -z &
PICKER_PID=$!
sleep 0.1 || true

REGION=$(timeout "$SLURP_TIMEOUT" slurp -b '#00000080' -c '#888888ff' -w 1) || \
    die 'No region selected (timeout or cancelled)'
[[ -n $REGION ]] || die 'No region selected'
cleanup

grim -g "$REGION" - \
    | magick - -colorspace Gray -normalize -contrast-stretch 2% \
        -sharpen 0x1.0 -resize 200% png:- \
    | tesseract - stdout -l "$OCR_LANGUAGE" --psm 6 \
    | wl-copy \
    || die 'Failed to capture or process text'
