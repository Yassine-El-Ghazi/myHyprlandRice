#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

DRY_RUN=0
FORCE=0
TARGET=$HOME
DEFAULT_ROOT="$REPO_ROOT/defaults"

while (($#)); do
    case $1 in
        --target)
            (($# >= 2)) || die '--target requires a directory'
            TARGET=$2
            shift 2
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            printf 'Usage: scripts/seed-runtime.sh [--target DIR] [--force] [--dry-run]\n'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

require_command readlink
require_command realpath
TARGET=$(realpath -m -- "$TARGET")
[[ -d $DEFAULT_ROOT ]] || die "Missing runtime defaults directory: $DEFAULT_ROOT"
[[ $TARGET != / ]] || die 'Refusing to seed runtime files into /.'

is_stale_managed_link() {
    local target_path=$1
    local link_target resolved_target

    [[ -L $target_path && ! -e $target_path ]] || return 1
    link_target=$(readlink -- "$target_path")
    if [[ $link_target != /* ]]; then
        link_target="$(dirname -- "$target_path")/$link_target"
    fi
    resolved_target=$(realpath -m -- "$link_target")
    [[ $resolved_target == "$REPO_ROOT/dotfiles/"* ]]
}

seeded=0
preserved=0
while IFS= read -r -d '' source_path; do
    relative=${source_path#"$DEFAULT_ROOT/"}
    target_path="$TARGET/$relative"
    removed_stale_link=0
    if is_stale_managed_link "$target_path"; then
        if [[ $DRY_RUN -eq 1 ]]; then
            print_command rm -- "$target_path"
        else
            rm -- "$target_path"
        fi
        removed_stale_link=1
    fi
    if [[ $FORCE -eq 0 && $removed_stale_link -eq 0 && \
        ( -e $target_path || -L $target_path ) ]]; then
        preserved=$((preserved + 1))
        continue
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        print_command mkdir -p "$(dirname -- "$target_path")"
        print_command cp -- "$source_path" "$target_path"
    else
        mkdir -p -- "$(dirname -- "$target_path")"
        cp -- "$source_path" "$target_path"
    fi
    seeded=$((seeded + 1))
done < <(find "$DEFAULT_ROOT" -type f -print0)

success "Runtime defaults seeded: $seeded created, $preserved preserved."
