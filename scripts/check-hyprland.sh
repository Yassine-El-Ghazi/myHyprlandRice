#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_command Hyprland

audit_home=$(mktemp -d "${TMPDIR:-/tmp}/myhyprlandrice-hypr.XXXXXXXX")
runtime_dir="$audit_home/runtime"
mkdir -m 0700 -- "$runtime_dir"
cleanup() {
    case $audit_home in
        "${TMPDIR:-/tmp}"/myhyprlandrice-hypr.*) rm -rf -- "$audit_home" ;;
    esac
}
trap cleanup EXIT

mkdir -p -- "$audit_home/.config"
cp -a -- "$REPO_ROOT/dotfiles/.config/hypr" "$audit_home/.config/hypr"
"$SCRIPT_DIR/seed-runtime.sh" --target "$audit_home" >/dev/null

config="$audit_home/.config/hypr/hyprland.lua"
failures=0
tested=0
hyprland_root_args=()
if [[ $(command id -u) == 0 ]]; then
    hyprland_root_args+=(--i-am-really-stupid)
fi

verify() {
    local label=$1
    local output
    tested=$((tested + 1))
    output=$(HOME="$audit_home" XDG_CONFIG_HOME="$audit_home/.config" \
        XDG_RUNTIME_DIR="$runtime_dir" \
        Hyprland "${hyprland_root_args[@]}" --verify-config --config "$config" 2>&1) || true
    if ! grep -q '^config ok$' <<< "$output"; then
        printf 'FAIL: %s\n%s\n' "$label" "$output" >&2
        failures=$((failures + 1))
    fi
}

selector_for() {
    case $1 in
        animations) printf 'animation' ;;
        decorations) printf 'decoration' ;;
        environments) printf 'environment' ;;
        keybindings) printf 'keybinding' ;;
        layouts) printf 'layout' ;;
        monitors) printf 'monitor' ;;
        windows) printf 'window' ;;
        workspaces) printf 'workspace' ;;
        windowrules) printf 'windowrule' ;;
    esac
}

categories=(animations decorations environments keybindings layouts monitors windows workspaces windowrules)
for category in "${categories[@]}"; do
    selector=$(selector_for "$category")
    printf 'source = ~/.config/hypr/conf/%s/default.conf\n' "$category" \
        > "$audit_home/.config/hypr/conf/$selector.conf"
done

verify default

for category in "${categories[@]}"; do
    selector=$(selector_for "$category")

    for module in "$audit_home/.config/hypr/conf/$category"/*.lua; do
        name=$(basename -- "$module" .lua)
        printf 'source = ~/.config/hypr/conf/%s/%s.conf\n' "$category" "$name" \
            > "$audit_home/.config/hypr/conf/$selector.conf"
        verify "$category/$name"
    done
    printf 'source = ~/.config/hypr/conf/%s/default.conf\n' "$category" \
        > "$audit_home/.config/hypr/conf/$selector.conf"
done

if [[ $failures -gt 0 ]]; then
    die "$failures of $tested Hyprland configurations failed validation."
fi
success "Hyprland validation passed ($tested configurations)."
