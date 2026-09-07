#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-keybinding-selector.XXXXXXXX")

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-keybinding-selector.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Keybinding selector test failed: %s\n' "$*" >&2
    exit 1
}

run_case() {
    local name=$1 value=${2-__missing__}
    local case_home="$TEST_ROOT/$name/home"
    local output

    mkdir -p -- "$case_home/.config/myhypr/settings"
    if [[ $value != __missing__ ]]; then
        printf '%s\n' "$value" \
            > "$case_home/.config/myhypr/settings/keybinding-profile"
    fi

    output=$(HOME="$case_home" lua - "$REPO_ROOT/dotfiles/.config/hypr/conf/keybinding.lua" <<'LUA'
local source = assert(arg[1])
require = function(module)
    io.write(module)
    return true
end
assert(loadfile(source))()
LUA
)
    printf '%s\n' "$output"
}

[[ $(run_case missing) == conf.keybindings.default ]] || \
    fail 'a missing selector did not use default'
[[ $(run_case french fr) == conf.keybindings.fr ]] || \
    fail 'the French profile was not selected'
[[ $(run_case invalid '../private') == conf.keybindings.default ]] || \
    fail 'a traversal selector did not fail closed'
[[ $(run_case unknown custom) == conf.keybindings.default ]] || \
    fail 'an unknown selector did not fail closed'
[[ $(run_case multiline $'fr\ncustom') == conf.keybindings.default ]] || \
    fail 'a multiline selector did not fail closed'

jq -e '
    [.[] | .settings[] | select(.id == "variant_keybinding")] == [{
        "name": "Keybinding Variant",
        "id": "variant_keybinding",
        "instructions": "Choose your preferred keybinding variant:",
        "file": "~/.config/myhypr/settings/keybinding-profile",
        "type": "choose",
        "mode": "overwrite",
        "default": "default",
        "options": ["default", "fr"],
        "post_command": "hyprctl reload"
    }]
' "$REPO_ROOT/dotfiles/.config/myhypr/settings-schema.json" >/dev/null || \
    fail 'settings schema does not expose the Lua-native profile selector'

[[ $(<"$REPO_ROOT/defaults/.config/myhypr/settings/keybinding-profile") == default ]] || \
    fail 'the Lua-native runtime default is missing'
[[ ! -e $REPO_ROOT/defaults/.config/hypr/conf/keybinding.conf ]] || \
    fail 'the legacy mutable selector default remains'
if find "$REPO_ROOT/dotfiles/.config/hypr/conf/keybindings" \
    -maxdepth 1 -type f -name '*.conf' -print -quit | grep -q .; then
    fail 'legacy Hyprlang keybinding files remain'
fi
if rg -q 'keybindings/.*\.conf|conf/keybinding\.conf' \
    "$REPO_ROOT/dotfiles/.config/hypr/conf/keybinding.lua" \
    "$REPO_ROOT/dotfiles/.config/hypr/scripts/keybindings.sh" \
    "$REPO_ROOT/dotfiles/.config/hypr/conf/restorevariations.sh" \
    "$REPO_ROOT/dotfiles/.config/hypr/hyprland.lua" \
    "$REPO_ROOT/dotfiles/.config/hypr/hyprland.conf" \
    "$REPO_ROOT/dotfiles/.config/myhypr/settings-schema.json"; then
    fail 'an active shortcut path still references the legacy selector'
fi
for example in \
    "$REPO_ROOT/dotfiles/.config/hypr/conf/custom.lua" \
    "$REPO_ROOT/examples/hypr/local.lua"; do
    rg -Fq 'hl.bind(' "$example" || \
        fail "shortcut example is missing from ${example#"$REPO_ROOT/"}"
    rg -Fq 'description = ' "$example" || \
        fail "shortcut description is missing from ${example#"$REPO_ROOT/"}"
done

printf 'Lua-native keybinding profile selection is bounded and legacy-free.\n'
