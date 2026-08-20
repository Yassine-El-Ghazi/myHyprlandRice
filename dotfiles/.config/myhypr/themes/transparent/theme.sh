#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
exec "$SCRIPT_DIR/apply-theme" \
    Transparent '/myhypr-glass;/myhypr-transparent/default' \
    transparent rofi glass transparent.conf 1 glass transparent
