#!/usr/bin/env bash
set -Eeuo pipefail

exec hyprctl eval "require('conf.runtime_actions').toggle_all_float()"
