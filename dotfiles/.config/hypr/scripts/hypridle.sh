#!/usr/bin/env bash
set -Eeuo pipefail
exec /usr/bin/python3 "${XDG_CONFIG_HOME:-$HOME/.config}/myhypr/bin/idle-control.py" "$@"
