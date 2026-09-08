#!/usr/bin/env bash
set -Eeuo pipefail

if (($# < 2)); then
    printf 'Usage: %s INTERPRETER FILE...\n' "${0##*/}" >&2
    exit 2
fi

interpreter=$1
shift

failures=0
for source_file in "$@"; do
    "$interpreter" -n "$source_file" || failures=$((failures + 1))
done

((failures == 0))
