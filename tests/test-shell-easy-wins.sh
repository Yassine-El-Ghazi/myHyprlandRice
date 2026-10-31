#!/usr/bin/env bash
# shellcheck disable=SC2016  # Embedded Fish code expands in the child shell.
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-shell-easy.XXXXXXXX")
cleanup() { rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT
mkdir -p -- "$TEST_ROOT/bin" "$TEST_ROOT/fixture-home/.config/bashrc/custom"
export TEST_LOG="$TEST_ROOT/git.log"
cat > "$TEST_ROOT/bin/git" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$TEST_LOG"
[[ $1 != stash || ${FAIL_STASH:-0} != 1 ]]
MOCK
chmod +x "$TEST_ROOT/bin/git"

for shell_name in bash fish; do
    case $shell_name in
        bash) alias_file="$REPO_ROOT/dotfiles/.config/bashrc/10-aliases" ;;
        fish) alias_file="$REPO_ROOT/dotfiles/.config/fish/conf.d/10-aliases.fish" ;;
    esac
    for failure in 0 1; do
        : > "$TEST_LOG"
        if [[ $shell_name == bash ]]; then
            HOME="$TEST_ROOT/fixture-home" PATH="$TEST_ROOT/bin:/usr/bin:/bin" FAIL_STASH=$failure \
                bash --noprofile --norc -c 'shopt -s expand_aliases; source "$1"; eval gsp' _ "$alias_file" || status=$?
        else
            HOME="$TEST_ROOT/fixture-home" PATH="$TEST_ROOT/bin:/usr/bin:/bin" FAIL_STASH=$failure \
                fish --no-config -c 'source $argv[1]; gsp' "$alias_file" || status=$?
        fi
        if [[ $failure == 1 ]]; then
            [[ ${status:-0} != 0 && $(<"$TEST_LOG") == stash ]]
        else
            [[ ${status:-0} == 0 && $(<"$TEST_LOG") == $'stash\npull' ]]
        fi
        unset status
    done
done

fish_init="$REPO_ROOT/dotfiles/.config/fish/conf.d/00_init.fish"
check_editor() {
    local expected=$1
    shift
    local actual
    actual=$(env "$@" HOME="$TEST_ROOT/fixture-home" GOTELEMETRY=off fish --no-config -c \
        'source $argv[1]; printf "%s|%s\n" "$EDITOR" "$VISUAL"' "$fish_init")
    [[ $actual == "$expected" ]]
}
check_editor 'vi|emacs' EDITOR=vi VISUAL=emacs
check_editor 'nvim|nvim' -u EDITOR -u VISUAL
check_editor 'nvim|nvim' EDITOR= VISUAL=
check_editor 'vi|nvim' EDITOR=vi VISUAL=
check_editor 'nvim|emacs' EDITOR= VISUAL=emacs

printf 'LOADER_RESULT=normal\n' > "$TEST_ROOT/fixture-home/.config/bashrc/00 module"
printf 'LOADER_RESULT=override\n' > "$TEST_ROOT/fixture-home/.config/bashrc/custom/00 module"
HOME="$TEST_ROOT/fixture-home" bash --noprofile --norc -c \
    'source "$1"; [[ $LOADER_RESULT == override ]]' _ "$REPO_ROOT/dotfiles/.bashrc"
printf 'Shell aliases, Fish editor defaults, and Bash module overrides passed.\n'
