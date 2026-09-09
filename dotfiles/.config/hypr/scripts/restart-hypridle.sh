#!/usr/bin/env bash
set -Eeuo pipefail
exec "${XDG_CONFIG_HOME:-$HOME/.config}/hypr/scripts/hypridle.sh" restart
