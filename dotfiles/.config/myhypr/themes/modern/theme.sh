#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
exec "$SCRIPT_DIR/apply-theme" \
    Modern '/myhypr-modern;/myhypr-modern/default' \
    modern rofi modern border-2.conf 2 modern modern
