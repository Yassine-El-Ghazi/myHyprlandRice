#!/usr/bin/env bash
# shellcheck disable=SC2016  # Match literal, portable $HOME path tokens.
_writeLog() {
    local message=$1
    printf ':: %s\n' "$message"
}

# Expand only the portable path forms accepted by tracked settings. Unlike
# eval, this never interprets command substitutions or shell operators.
myhypr_expand_path() {
    local raw_path=$1
    local tilde='~'

    case $raw_path in
        "$tilde") printf '%s' "$HOME" ;;
        "$tilde/"*) printf '%s/%s' "$HOME" "${raw_path#"$tilde/"}" ;;
        '$HOME') printf '%s' "$HOME" ;;
        '$HOME/'*) printf '%s/%s' "$HOME" "${raw_path#\$HOME/}" ;;
        /*) printf '%s' "$raw_path" ;;
        *) printf '%s/%s' "$HOME" "$raw_path" ;;
    esac
}

# New configurations use strftime placeholders directly. The legacy
# `$(date +FORMAT)` spelling remains readable during namespace migration, but
# is parsed as data and is never evaluated as shell code.
myhypr_render_filename() {
    local template=$1
    local rendered

    if [[ $template =~ ^(.*)\$\(date[[:space:]]+\+([^()]*)\)(.*)$ ]]; then
        rendered="${BASH_REMATCH[1]}$(date +"${BASH_REMATCH[2]}")${BASH_REMATCH[3]}"
    else
        rendered=$(date +"$template")
    fi

    [[ -n $rendered && $rendered != */* && $rendered != . && $rendered != .. ]] || {
        printf 'Invalid filename template: %s\n' "$template" >&2
        return 1
    }
    printf '%s' "$rendered"
}
