#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

QUICK=0
REQUIRE_TOOLS=0

while (($#)); do
    case $1 in
        --quick)
            QUICK=1
            shift
            ;;
        --require-tools)
            REQUIRE_TOOLS=1
            shift
            ;;
        -h|--help)
            printf 'Usage: scripts/check.sh [--quick] [--require-tools]\n'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

cd -- "$REPO_ROOT"
failures=0
skips=0

pass() {
    success "$1"
}

skip() {
    warn "SKIP: $1"
    skips=$((skips + 1))
    [[ $REQUIRE_TOOLS -eq 0 ]] || failures=$((failures + 1))
}

run_check() {
    local label=$1
    shift
    if "$@"; then
        pass "$label"
    else
        warn "FAIL: $label"
        failures=$((failures + 1))
    fi
}

mapfile -d '' bash_files < <(
    rg -l -0 --hidden --glob '!.git/**' '^#!.*/(env[[:space:]]+)?bash$' \
        dotfiles scripts tests .githooks bootstrap.sh stow.sh
)
bash_files+=(dotfiles/.bashrc)
while IFS= read -r -d '' file; do
    bash_files+=("$file")
done < <(find dotfiles/.config/bashrc -maxdepth 1 -type f -print0)
run_check 'Bash syntax' bash -n "${bash_files[@]}"

if command -v zsh >/dev/null 2>&1; then
    mapfile -d '' zsh_files < <(find dotfiles/.config/zshrc -maxdepth 1 -type f -print0)
    zsh_files+=(dotfiles/.zshrc)
    run_check 'Zsh syntax' zsh -n "${zsh_files[@]}"
else
    skip 'zsh is unavailable'
fi

if command -v fish >/dev/null 2>&1; then
    mapfile -d '' fish_files < <(find dotfiles/.config/fish -type f -name '*.fish' -print0)
    run_check 'Fish syntax' fish -n "${fish_files[@]}"
else
    skip 'fish is unavailable'
fi

if command -v luac >/dev/null 2>&1; then
    lua_failed=0
    while IFS= read -r -d '' file; do
        luac -p "$file" || lua_failed=1
    done < <(find dotfiles -type f -name '*.lua' ! -path '*/matugen/templates/*' -print0)
    if [[ $lua_failed -eq 0 ]]; then
        pass 'Lua syntax'
    else
        warn 'FAIL: Lua syntax'
        failures=$((failures + 1))
    fi
else
    skip 'luac is unavailable'
fi

if command -v python >/dev/null 2>&1; then
    mapfile -d '' json_files < <(find dotfiles defaults -type f \( -name '*.json' -o -name '*.jsonc' \) -print0)
    run_check 'JSON/JSONC syntax' python "$SCRIPT_DIR/validate-jsonc.py" "${json_files[@]}"

    mapfile -d '' python_files < <(find scripts tests -type f -name '*.py' -print0)
    python_files+=(dotfiles/.config/myhypr/bin/settingsctl)
    run_check 'Python syntax' python -c '
import pathlib
import sys
for name in sys.argv[1:]:
    compile(pathlib.Path(name).read_bytes(), name, "exec")
' "${python_files[@]}"

    mapfile -d '' toml_files < <(find dotfiles defaults -type f -name '*.toml' -print0)
    run_check 'TOML syntax' python -c '
import pathlib, sys, tomllib
for name in sys.argv[1:]:
    with pathlib.Path(name).open("rb") as stream:
        tomllib.load(stream)
' "${toml_files[@]}"
else
    skip 'python is unavailable'
fi

if command -v qmllint >/dev/null 2>&1; then
    run_check 'Quickshell entrypoint syntax' qmllint dotfiles/.config/quickshell/shell.qml
else
    skip 'qmllint is unavailable'
fi

if command -v shellcheck >/dev/null 2>&1; then
    run_check 'ShellCheck style (all Bash configuration)' \
        shellcheck -x -S style "${bash_files[@]}"
else
    skip 'shellcheck is unavailable'
fi

run_check 'Git whitespace checks' git diff --check
run_check 'Stateful all-float runtime action' lua "$REPO_ROOT/tests/test-runtime-actions.lua"
run_check 'Zsh module loader behavior' "$REPO_ROOT/tests/test-zsh-loader.sh"
run_check 'Dynamic monitor behavior' "$REPO_ROOT/tests/test-toggle-refresh.sh"
run_check 'Cursor zoom behavior' "$REPO_ROOT/tests/test-cursor-zoom.sh"
run_check 'Animation toggle behavior' "$REPO_ROOT/tests/test-toggle-animations.sh"
run_check 'Gamemode runtime configuration' "$REPO_ROOT/tests/test-gamemode.sh"
run_check 'Window focus behavior' "$REPO_ROOT/tests/test-window-focus.sh"
run_check 'Workspace movement behavior' "$REPO_ROOT/tests/test-workspace-move.sh"
run_check 'Sidepad typed geometry behavior' "$REPO_ROOT/tests/test-sidepad-runtime.sh"
run_check 'Hyprland typed runtime API guard' "$REPO_ROOT/tests/test-hyprland-runtime-api.sh"
run_check 'Keybinding inventory and command resolution' lua "$REPO_ROOT/tests/test-keybindings.lua"
run_check 'Namespace migration behavior' "$REPO_ROOT/tests/test-migrate-namespace.sh"
run_check 'Package bootstrap behavior' "$REPO_ROOT/tests/test-install-packages.sh"
run_check 'Arch maintenance helper safety' "$REPO_ROOT/tests/test-arch-helpers.sh"
run_check 'Stow and bootstrap behavior' "$REPO_ROOT/tests/test-link-dotfiles.sh"
run_check 'System integration behavior' "$REPO_ROOT/tests/test-configure-system.sh"
run_check 'Graphical session service isolation' "$REPO_ROOT/tests/test-session-services.sh"
run_check 'Managed desktop autostart behavior' "$REPO_ROOT/tests/test-autostart.sh"
run_check 'Dock replacement behavior' "$REPO_ROOT/tests/test-dock-launch.sh"
run_check 'Local settings editor behavior' python "$REPO_ROOT/tests/test-settingsctl.py"
run_check 'Standalone dependency guards' "$REPO_ROOT/tests/test-standalone.sh"
run_check 'Desktop control behavior' "$REPO_ROOT/tests/test-desktopctl.sh"
run_check 'Desktop theme application' "$REPO_ROOT/tests/test-desktop-themes.sh"
run_check 'Waybar theme behavior' "$REPO_ROOT/tests/test-waybar-themes.sh"
run_check 'Waybar desktop actions' "$REPO_ROOT/tests/test-waybar-actions.sh"
run_check 'Walker service behavior' "$REPO_ROOT/tests/test-walker-launch.sh"
run_check 'Wallpaper effect behavior' "$REPO_ROOT/tests/test-wallpaper-effect.sh"

if [[ $QUICK -eq 0 ]]; then
    if command -v Hyprland >/dev/null 2>&1; then
        if ! "$SCRIPT_DIR/check-hyprland.sh"; then
            failures=$((failures + 1))
        fi
    else
        skip 'Hyprland is unavailable'
    fi
fi

if [[ $failures -gt 0 ]]; then
    die "$failures validation group(s) failed; $skips skipped."
fi
success "All validation groups passed ($skips skipped)."
