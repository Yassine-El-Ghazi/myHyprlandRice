#!/usr/bin/env bash

# Shared helpers for repository automation. This file is sourced, not executed.

if [[ -t 1 ]]; then
    _C_RESET=$'\033[0m'
    _C_BLUE=$'\033[34m'
    _C_GREEN=$'\033[32m'
    _C_YELLOW=$'\033[33m'
    _C_RED=$'\033[31m'
else
    _C_RESET=''
    _C_BLUE=''
    _C_GREEN=''
    _C_YELLOW=''
    _C_RED=''
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC2034  # Public to every script that sources this library.
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

info() {
    printf '%s==>%s %s\n' "$_C_BLUE" "$_C_RESET" "$*"
}

success() {
    printf '%s==>%s %s\n' "$_C_GREEN" "$_C_RESET" "$*"
}

warn() {
    printf '%swarning:%s %s\n' "$_C_YELLOW" "$_C_RESET" "$*" >&2
}

die() {
    printf '%serror:%s %s\n' "$_C_RED" "$_C_RESET" "$*" >&2
    exit 1
}

print_command() {
    printf '  +'
    printf ' %q' "$@"
    printf '\n'
}

run() {
    print_command "$@"
    if [[ ${DRY_RUN:-0} -eq 0 ]]; then
        "$@"
    fi
}

confirm() {
    local prompt=${1:-Continue?}
    local answer

    [[ ${DRY_RUN:-0} -eq 1 ]] && return 0
    [[ ${ASSUME_YES:-0} -eq 1 ]] && return 0
    [[ -t 0 ]] || die "$prompt Re-run with --yes in a non-interactive shell."
    read -r -p "$prompt [y/N] " answer
    [[ $answer == [yY] || $answer == [yY][eE][sS] ]]
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

resolve_executable() {
    local command_name=$1
    local candidate resolved
    shift

    if resolved=$(command -v -- "$command_name" 2>/dev/null); then
        printf '%s\n' "$resolved"
        return 0
    fi
    for candidate in "$@"; do
        if [[ -x $candidate ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

ensure_sudo_session() {
    if [[ ${MYHYPR_SUDO_SESSION_READY:-0} == 1 ]]; then
        return
    fi

    require_command sudo
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        print_command sudo -v
        return
    fi

    if [[ -t 0 ]]; then
        info 'Authenticating once for privileged changes'
        sudo -v
    elif ! sudo -n -v >/dev/null 2>&1; then
        die 'Administrator authentication is required. Re-run this command in a terminal.'
    fi

    export MYHYPR_SUDO_SESSION_READY=1
}

timestamp() {
    date -u +'%Y%m%dT%H%M%SZ'
}
