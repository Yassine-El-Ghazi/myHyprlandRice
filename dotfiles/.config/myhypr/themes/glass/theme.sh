#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
exec "$SCRIPT_DIR/apply-theme" \
    Glass '/myhypr-glass;/myhypr-glass/default' \
    glass rofi glass default.conf 1 glass glass
