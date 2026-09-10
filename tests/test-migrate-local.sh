#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-local-migration.XXXXXXXX")

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-local-migration.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Local migration test failed: %s\n' "$*" >&2
    exit 1
}

legacy_home="$TEST_ROOT/legacy-home"
legacy_selector="$legacy_home/.config/hypr/conf/keybinding.conf"
profile="$legacy_home/.config/myhypr/settings/keybinding-profile"
mkdir -p -- "${legacy_selector%/*}"
printf '%s\n' 'source = ~/.config/hypr/conf/keybindings/fr.conf' > "$legacy_selector"

HOME="$legacy_home" XDG_STATE_HOME="$legacy_home/.local/state" \
    "$REPO_ROOT/scripts/migrate-local.sh" --yes >/dev/null

[[ -f $profile && $(<"$profile") == fr ]] || \
    fail 'the legacy French selection was not preserved'
[[ ! -e $legacy_selector && ! -L $legacy_selector ]] || \
    fail 'the legacy selector remains active'
archive_count=$(find "$legacy_home/.local/state/myhyprlandrice/migrations" \
    -type f -name 'keybinding.conf' -print | wc -l)
[[ $archive_count -eq 1 ]] || fail 'the legacy selector was not archived exactly once'

HOME="$legacy_home" XDG_STATE_HOME="$legacy_home/.local/state" \
    "$REPO_ROOT/scripts/migrate-local.sh" --yes >/dev/null
[[ $(<"$profile") == fr ]] || fail 'an idempotent rerun changed the profile'

existing_home="$TEST_ROOT/existing-home"
existing_selector="$existing_home/.config/hypr/conf/keybinding.conf"
existing_profile="$existing_home/.config/myhypr/settings/keybinding-profile"
mkdir -p -- "${existing_selector%/*}" "${existing_profile%/*}"
printf '%s\n' 'source = ~/.config/hypr/conf/keybindings/fr.conf' > "$existing_selector"
printf '%s\n' default > "$existing_profile"
HOME="$existing_home" XDG_STATE_HOME="$existing_home/.local/state" \
    "$REPO_ROOT/scripts/migrate-local.sh" --yes >/dev/null
[[ $(<"$existing_profile") == default ]] || \
    fail 'migration overwrote an explicit Lua-native profile'
[[ ! -e $existing_selector ]] || fail 'an obsolete selector was not archived'

dry_home="$TEST_ROOT/dry-home"
dry_selector="$dry_home/.config/hypr/conf/keybinding.conf"
mkdir -p -- "${dry_selector%/*}"
printf '%s\n' 'source = ~/.config/hypr/conf/keybindings/fr.conf' > "$dry_selector"
HOME="$dry_home" XDG_STATE_HOME="$dry_home/.local/state" \
    "$REPO_ROOT/scripts/migrate-local.sh" --dry-run --yes >/dev/null
[[ -f $dry_selector ]] || fail 'dry-run removed the legacy selector'
[[ ! -e $dry_home/.config/myhypr/settings/keybinding-profile ]] || \
    fail 'dry-run created the Lua-native profile'

shader_home="$TEST_ROOT/shader-home"
shader_setting="$shader_home/.config/myhypr/settings/hyprshade.sh"
mkdir -p -- "${shader_setting%/*}"
printf '%s\n' blue-light-filter-50 > "$shader_setting"
HOME="$shader_home" XDG_STATE_HOME="$shader_home/.local/state" \
    "$REPO_ROOT/scripts/migrate-local.sh" --yes >/dev/null
[[ $(<"$shader_setting") == blue-light-filter ]] || \
    fail 'obsolete Hyprshade filter was not migrated'
printf '%s\n' vibrance > "$shader_setting"
HOME="$shader_home" XDG_STATE_HOME="$shader_home/.local/state" \
    "$REPO_ROOT/scripts/migrate-local.sh" --yes >/dev/null
[[ $(<"$shader_setting") == vibrance ]] || \
    fail 'migration overwrote an explicit Hyprshade filter'

printf 'Legacy local settings migrate safely and idempotently.\n'
