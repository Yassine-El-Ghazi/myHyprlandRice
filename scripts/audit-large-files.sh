#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

MODE=worktree
if (($#)); then
    [[ $1 == --staged ]] || die 'Usage: scripts/audit-large-files.sh [--staged]'
    MODE=staged
    shift
fi
(($# == 0)) || die 'Usage: scripts/audit-large-files.sh [--staged]'
cd -- "$REPO_ROOT"

limit=$((10 * 1024 * 1024))
allowlist=.audit-large-files
failures=0
declare -A allowed_sha=() allowed_size=() seen=()

policy_exists() {
    if [[ $MODE == staged ]]; then
        git cat-file -e ":$allowlist" 2>/dev/null
    else
        [[ -f $allowlist ]]
    fi
}

policy_contents() {
    if [[ $MODE == staged ]]; then
        git show ":$allowlist"
    else
        command cat -- "$allowlist"
    fi
}

safe_policy_path() {
    local path=$1
    [[ -n $path && $path != /* && $path != . && $path != .. &&
        $path != ./* && $path != */./* && $path != */. &&
        $path != ../* && $path != */../* && $path != */.. &&
        $path != *//* && $path != */ && ! $path =~ [[:cntrl:]] ]]
}

quoted_path() {
    printf '%q' "${1:-missing-path}"
}

load_policy() {
    local contents line remainder digest bytes path reason extra
    policy_exists || return 0
    contents=$(policy_contents) || die 'Unable to read the large-file exception policy.'
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line ]] || continue
        [[ $line == \#* ]] && continue

        digest=''
        bytes=''
        path=''
        reason=''
        remainder=$line
        extra=1
        if [[ $line == *$'\t'* ]]; then
            digest=${line%%$'\t'*}
            remainder=${line#*$'\t'}
        fi
        if [[ $remainder == *$'\t'* ]]; then
            bytes=${remainder%%$'\t'*}
            remainder=${remainder#*$'\t'}
        fi
        if [[ $remainder == *$'\t'* ]]; then
            path=${remainder%%$'\t'*}
            reason=${remainder#*$'\t'}
            [[ $reason == *$'\t'* ]] || extra=''
        fi

        if [[ ! $digest =~ ^[0-9a-f]{64}$ || ! $bytes =~ ^[0-9]+$ ||
              -z $reason || -n $extra ]] || ! safe_policy_path "$path"; then
            warn "Malformed large-file exception for path: $(quoted_path "$path")"
            failures=$((failures + 1))
            continue
        fi
        if [[ -n ${allowed_sha[$path]+x} ]]; then
            warn "Duplicate large-file exception: $(quoted_path "$path")"
            failures=$((failures + 1))
            continue
        fi
        allowed_sha[$path]=$digest
        allowed_size[$path]=$bytes
    done <<< "$contents"
}

content_size() {
    local path=$1
    if [[ $MODE == staged ]]; then
        git cat-file -s ":$path"
    elif [[ -L $path ]]; then
        readlink -- "$path" | wc -c
    else
        stat -c %s -- "$path"
    fi
}

content_digest() {
    local path=$1
    if [[ $MODE == staged ]]; then
        git show ":$path" | sha256sum | cut -d' ' -f1
    elif [[ -L $path ]]; then
        readlink -- "$path" | sha256sum | cut -d' ' -f1
    else
        sha256sum -- "$path" | cut -d' ' -f1
    fi
}

load_policy

declare -a files=()
file_list=$(mktemp "${TMPDIR:-/tmp}/myhypr-large-files.XXXXXXXX") || \
    die 'Unable to create the large-file inventory.'
cleanup() {
    case $file_list in
        "${TMPDIR:-/tmp}"/myhypr-large-files.*) rm -f -- "$file_list" ;;
    esac
}
trap cleanup EXIT
if [[ $MODE == staged ]]; then
    git ls-files -z > "$file_list" || die 'Unable to enumerate the staged snapshot.'
else
    git ls-files -z --cached --others --exclude-standard > "$file_list" || \
        die 'Unable to enumerate the worktree snapshot.'
fi
mapfile -d '' files < "$file_list"

for path in "${files[@]}"; do
    if [[ $MODE != staged && ! -e $path && ! -L $path ]]; then
        continue
    fi
    size=$(content_size "$path")
    ((size > limit)) || continue
    digest=$(content_digest "$path")
    if [[ -z ${allowed_sha[$path]+x} ]]; then
        warn "File exceeds 10 MiB without an exception: $(quoted_path "$path")"
        failures=$((failures + 1))
        continue
    fi
    if [[ ${allowed_size[$path]} != "$size" || ${allowed_sha[$path]} != "$digest" ]]; then
        warn "Large-file exception does not match current content: $(quoted_path "$path")"
        failures=$((failures + 1))
        continue
    fi
    seen[$path]=1
done

for path in "${!allowed_sha[@]}"; do
    if [[ -z ${seen[$path]+x} ]]; then
        warn "Large-file exception is stale or unnecessary: $(quoted_path "$path")"
        failures=$((failures + 1))
    fi
done

if ((failures > 0)); then
    die "$failures large-file policy finding(s) must be resolved."
fi
success 'Large-file policy passed.'
