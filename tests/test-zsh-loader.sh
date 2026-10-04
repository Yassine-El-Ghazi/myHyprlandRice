#!/usr/bin/env bash
# shellcheck disable=SC2016  # Fixture code expands variables in the test shell.
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

ln -s -- "$REPO_ROOT/dotfiles/.config/zshrc/00-init" "$TEST_HOME/.config/zshrc/00-init"
mkdir -p -- "$TEST_HOME/Android/Sdk/platform-tools" \
    "$TEST_HOME/Android/Sdk/cmdline-tools/latest/bin" "$TEST_HOME/untrusted-tools" \
    "$TEST_HOME/.config/go/telemetry"
# Avoid a Go telemetry writer racing the disposable home's cleanup.
printf 'off\n' > "$TEST_HOME/.config/go/telemetry/mode"
printf 'path=("$HOME/untrusted-tools" "${path[@]}")\n' > "$TEST_HOME/.zshrc_custom"

HOME="$TEST_HOME" zsh -dfc '
    source "$HOME/.zshrc"
    [[ ${path[1]} == /usr/local/sbin && ${path[2]} == /usr/local/bin &&
       ${path[3]} == /usr/bin && ${path[4]} == /bin && ${path[5]} == /usr/sbin ]]
    [[ ${path[(Ie)$HOME/Android/Sdk/platform-tools]} -gt 5 ]]
    [[ ${path[(Ie)$HOME/Android/Sdk/cmdline-tools/latest/bin]} -gt 5 ]]
    [[ ${path[(Ie)$HOME/Android/Sdk/emulator]} -eq 0 ]]
    [[ ${path[(Ie)$HOME/untrusted-tools]} -gt 5 ]]
    [[ $(whence -p id) == /usr/bin/id ]]
'

printf 'Zsh loader follows module symlinks and retains final system-first ordering.\n'
