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

# Reserve a fresh private capture file. Existing files/links are never opened
# or truncated; repeated filenames get a unique suffix instead.
myhypr_reserve_screenshot() (
    local directory=$1 filename=$2 destination mode template suffix=''
    umask 077
    [[ -n $filename && $filename != */* && $filename != . && $filename != .. ]] || return 1
    [[ ! -L $directory ]] || {
        printf 'Screenshot directory may not be a symlink.\n' >&2
        return 1
    }
    mkdir -p -- "$directory" || return 1
    [[ -d $directory && $(stat -c %u -- "$directory") == "$EUID" ]] || return 1
    mode=$(stat -c %a -- "$directory") || return 1
    if [[ ! $mode =~ ^[0-7]{3,4}$ ]] || (( (8#$mode & 0022) != 0 )); then
        printf 'Screenshot directory must not be writable by other users.\n' >&2
        return 1
    fi
    destination="$directory/$filename"
    if [[ -e $destination || -L $destination ]]; then
        template="$directory/$filename.XXXXXXXX"
        if [[ $filename == ?*.* ]]; then
            suffix=".${filename##*.}"
            template="$directory/${filename%.*}.XXXXXXXX"
        fi
        destination=$(mktemp --suffix="$suffix" -- "$template") || return 1
    elif ! (set -o noclobber; : > "$destination") 2>/dev/null; then
        printf 'Could not reserve screenshot output.\n' >&2
        return 1
    fi
    if [[ $(stat -c '%u:%a' -- "$destination") != "$EUID:600" ]]; then
        rm -f -- "$destination"
        printf 'Could not establish private screenshot permissions.\n' >&2
        return 1
    fi
    printf '%s\n' "$destination"
)
