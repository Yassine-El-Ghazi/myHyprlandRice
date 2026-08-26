#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd -- "$REPO_ROOT"
expected=$(mktemp "${TMPDIR:-/tmp}/myhypr-assets-expected.XXXXXXXX")
documented=$(mktemp "${TMPDIR:-/tmp}/myhypr-assets-documented.XXXXXXXX")
trap 'rm -f -- "$expected" "$documented"' EXIT

git ls-files | rg -i '\.(png|jpe?g|webp|gif|svg)$' | sort > "$expected"
sed -n 's/^| `\([^`]*\)` |.*/\1/p' ASSETS.md | sort > "$documented"
diff -u "$expected" "$documented"
[[ $(wc -l < "$expected") -eq 11 ]]
if rg -n -i '\b(TBD|TODO|unknown|unverified)\b' ASSETS.md; then
    printf 'Asset manifest contains an unresolved entry.\n' >&2
    exit 1
fi
printf 'Asset manifest covers every tracked image.\n'
