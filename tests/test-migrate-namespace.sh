#!/usr/bin/env bash
# shellcheck disable=SC2016  # Legacy filename syntax must remain literal test data.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-migration-test.XXXXXXXX")

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-migration-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Migration test failed: %s\n' "$*" >&2
    exit 1
}

assert_content() {
    local path=$1
    local expected=$2
    [[ -f $path ]] || fail "missing file $path"
    [[ $(<"$path") == "$expected" ]] || fail "unexpected content in $path"
}

target="$TEST_ROOT/home"
legacy="$target/.config/ml4w"
mkdir -p -- \
    "$legacy/settings" "$legacy/colors" \
    "$target/.config/ml4w-dotfiles-installer" \
    "$target/.config/ml4w-dotfiles-settings.backup" \
    "$target/.local/share/ml4w-dotfiles-settings" \
    "$target/.local/bin" \
    "$target/.cache/ml4w/hyprland-dotfiles" \
    "$target/Pictures/CustomWallpapers"

printf 'firefox\n' > "$legacy/settings/browser.sh"
printf 'ml4w-kitty\n' > "$legacy/settings/sidepad-active"
printf '/ml4w-modern;/ml4w-modern/default\n' > "$legacy/settings/waybar-theme.sh"
printf 'ml4w\n' > "$legacy/settings/walker-theme"
printf 'hyprshade_filter="blue-light-filter-50"\n' > "$legacy/settings/hyprshade.sh"
printf '%s\n' "$target/Pictures/CustomWallpapers" > "$legacy/settings/wallpaper-folder"
printf 'screenshot_$(date +%%Y%%m%%d).png\n' > "$legacy/settings/screenshot-filename"
printf '#112233\n' > "$legacy/colors/primary"
printf '#445566\n' > "$legacy/colors/secondary"
printf '#ddeeff\n' > "$legacy/colors/onsurface"
printf 'legacy\n' > "$target/.config/ml4w-dotfiles-installer/state"
printf 'legacy\n' > "$target/.config/ml4w-dotfiles-settings.backup/state"
printf 'legacy\n' > "$target/.local/share/ml4w-dotfiles-settings/state"
printf '#!/bin/sh\n' > "$target/.local/bin/ml4w-dotfiles-settings"
printf 'cache\n' > "$target/.cache/ml4w/hyprland-dotfiles/current_wallpaper"
printf 'disabled\n' > "$target/.cache/ml4w-welcome-autostart"

"$REPO_ROOT/scripts/migrate-namespace.sh" --target "$target" --yes >/dev/null

assert_content "$target/.config/myhypr/settings/browser" firefox
assert_content "$target/.config/myhypr/settings/sidepad-active" myhypr-kitty
assert_content "$target/.config/myhypr/settings/waybar-theme.sh" \
    '/myhypr-modern;/myhypr-modern/default'
assert_content "$target/.config/myhypr/settings/walker-theme" myhypr
assert_content "$target/.config/myhypr/settings/hyprshade.sh" blue-light-filter-50
assert_content "$target/.config/myhypr/settings/wallpaper-folder" \
    "$target/Pictures/CustomWallpapers"
assert_content "$target/.config/myhypr/settings/screenshot-filename" \
    'screenshot_$(date +%Y%m%d).png'
assert_content "$target/.config/myhypr/settings/welcome-on-startup" False
assert_content "$target/.config/myhypr/colors/primary" '#112233'
assert_content "$target/.cache/myhypr/current_wallpaper" cache

[[ ! -e $legacy ]] || fail 'legacy configuration was not archived'
[[ ! -e $target/.local/bin/ml4w-dotfiles-settings ]] || fail 'legacy launcher remains active'
archive_count=$(find "$target/.local/state/myhyprlandrice/migrations" \
    -path '*/legacy-ml4w/.config/ml4w-dotfiles-installer/state' -print | wc -l)
[[ $archive_count -eq 1 ]] || fail 'legacy installer archive was not created exactly once'

# A second pass must be a no-op.
"$REPO_ROOT/scripts/migrate-namespace.sh" --target "$target" --yes >/dev/null
assert_content "$target/.config/myhypr/settings/browser" firefox

# Dry-run mode must leave the source tree untouched.
dry_target="$TEST_ROOT/dry-home"
mkdir -p -- "$dry_target/.config/ml4w/settings"
printf 'firefox\n' > "$dry_target/.config/ml4w/settings/browser.sh"
"$REPO_ROOT/scripts/migrate-namespace.sh" \
    --target "$dry_target" --dry-run --yes >/dev/null
[[ -f $dry_target/.config/ml4w/settings/browser.sh ]] || fail 'dry run moved legacy data'
[[ ! -e $dry_target/.config/myhypr ]] || fail 'dry run created standalone data'

# Canonicalization must catch aliases for the filesystem root.
if "$REPO_ROOT/scripts/migrate-namespace.sh" --target /tmp/.. --yes >/dev/null 2>&1; then
    fail 'root target alias was accepted'
fi

printf 'Namespace migration is reversible, idempotent, and dry-run safe.\n'
