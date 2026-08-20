#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

DRY_RUN=0
TARGET=$HOME

while (($#)); do
    case $1 in
        --target)
            (($# >= 2)) || die '--target requires a directory'
            TARGET=$(realpath -m -- "$2")
            shift 2
            ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            printf 'Usage: scripts/capture-runtime.sh [--target DIR] [--dry-run]\n'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ $TARGET != / ]] || die 'Refusing to capture from the filesystem root.'
changed=0
missing=0
while IFS= read -r -d '' default_path; do
    relative=${default_path#"$REPO_ROOT/defaults/"}
    runtime_path="$TARGET/$relative"
    if [[ ! -f $runtime_path || -L $runtime_path ]]; then
        warn "Not a normal runtime file; skipped: $relative"
        missing=$((missing + 1))
        continue
    fi
    cmp -s -- "$runtime_path" "$default_path" && continue

    if [[ $DRY_RUN -eq 1 ]]; then
        print_command cp -- "$runtime_path" "$default_path"
    else
        cp -- "$runtime_path" "$default_path"
    fi
    changed=$((changed + 1))
done < <(find "$REPO_ROOT/defaults" -type f -print0)

if [[ $DRY_RUN -eq 0 && $changed -gt 0 ]]; then
    info 'Auditing captured defaults before they can be committed'
    "$REPO_ROOT/scripts/audit.sh"
fi

success "Runtime capture complete: $changed changed, $missing unavailable."
