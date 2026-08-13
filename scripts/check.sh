#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
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
    find dotfiles -type f -name '*.sh' -print0
    find . -maxdepth 2 -type f -name '*.sh' -print0
)
bash_files+=(tests/helpers/hyprctl)
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
    [[ $lua_failed -eq 0 ]] && pass 'Lua syntax' || {
        warn 'FAIL: Lua syntax'
        failures=$((failures + 1))
    }
else
    skip 'luac is unavailable'
fi

if command -v python >/dev/null 2>&1; then
    mapfile -d '' json_files < <(find dotfiles defaults -type f \( -name '*.json' -o -name '*.jsonc' \) -print0)
    run_check 'JSON/JSONC syntax' python "$SCRIPT_DIR/validate-jsonc.py" "${json_files[@]}"

    run_check 'Python syntax' python -c '
import pathlib
compile(pathlib.Path(__import__("sys").argv[1]).read_bytes(), __import__("sys").argv[1], "exec")
' "$SCRIPT_DIR/validate-jsonc.py"

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
    mapfile -d '' automation_files < <(
        find scripts tests -type f -name '*.sh' -print0 2>/dev/null
        find .githooks -type f -print0 2>/dev/null
    )
    automation_files+=(tests/helpers/hyprctl)
    automation_files+=(bootstrap.sh stow.sh)
    run_check 'ShellCheck (repository automation)' shellcheck -x -S warning "${automation_files[@]}"
else
    skip 'shellcheck is unavailable'
fi

run_check 'Git whitespace checks' git diff --check
run_check 'Dynamic monitor behavior' "$REPO_ROOT/tests/test-toggle-refresh.sh"

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
