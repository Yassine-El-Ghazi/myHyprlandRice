#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${1:-} != --configured-folder ]] || shift
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if (($# == 0)); then
    exec "$script_dir/wallpaper.sh" --pick
fi
exec "$script_dir/wallpaper.sh" "$@"
