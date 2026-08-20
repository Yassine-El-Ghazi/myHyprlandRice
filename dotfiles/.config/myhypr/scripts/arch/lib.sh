#!/usr/bin/env bash

myhypr_arch_die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

myhypr_arch_require() {
    local command_name

    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 || \
            myhypr_arch_die "Required command is missing: $command_name"
    done
}

myhypr_arch_require_user() {
    [[ $EUID -ne 0 ]] || myhypr_arch_die 'Run this helper as your regular user, not root.'
}

myhypr_arch_banner() {
    if command -v figlet >/dev/null 2>&1; then
        figlet -f smslant "$1"
    else
        printf '\n%s\n\n' "$1"
    fi
}

myhypr_arch_confirm() {
    local prompt=$1
    local answer

    [[ ${MYHYPR_ASSUME_YES:-0} == 1 ]] && return 0
    if command -v gum >/dev/null 2>&1; then
        gum confirm "$prompt"
        return
    fi
    [[ -t 0 ]] || return 1
    read -r -p "$prompt [y/N] " answer
    [[ $answer == [Yy] || $answer == [Yy][Ee][Ss] ]]
}
