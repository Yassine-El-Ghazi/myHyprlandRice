#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ ${1:-} == reload ]]; then
    exec "$script_dir/wallpaper.sh"
fi
exec "$script_dir/wallpaper.sh" --pick-effect
