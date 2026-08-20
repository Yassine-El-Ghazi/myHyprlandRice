#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-zsh-loader.XXXXXXXX")

cleanup() {
    case $TEST_HOME in
        "${TMPDIR:-/tmp}"/myhypr-zsh-loader.*) rm -rf -- "$TEST_HOME" ;;
    esac
}
trap cleanup EXIT

mkdir -p -- "$TEST_HOME/.config/zshrc"
ln -s -- "$REPO_ROOT/dotfiles/.zshrc" "$TEST_HOME/.zshrc"

printf 'typeset -g MYHYPR_ZSH_TEST=loaded\n' > "$TEST_HOME/module-target"
ln -s -- "$TEST_HOME/module-target" "$TEST_HOME/.config/zshrc/00-test"

HOME="$TEST_HOME" zsh -dfc '
    source "$HOME/.zshrc"
    [[ $MYHYPR_ZSH_TEST == loaded ]]
'

printf 'Zsh loader follows Stow-managed module symlinks.\n'
