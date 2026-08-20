#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
exec "$SCRIPT_DIR/apply-theme" \
    'Modern + Walker' '/myhypr-modern;/myhypr-modern/default' \
    modern walker modern border-2.conf 2 modern modern
