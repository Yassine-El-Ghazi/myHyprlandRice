#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

DRY_RUN=0
TARGET=$HOME

while (($#)); do
    case $1 in
        --target)
            (($# >= 2)) || die '--target requires a directory'
            TARGET=$2
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            printf 'Usage: scripts/uninstall.sh [--target DIR] [--dry-run]\n'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ $TARGET != / ]] || die 'Refusing to use / as a Stow target.'
require_command stow

args=(--delete --no-folding --dir "$REPO_ROOT" --target "$TARGET" dotfiles)
[[ $DRY_RUN -eq 1 ]] && args=(--simulate "${args[@]}")
run stow "${args[@]}"
success 'Managed links removed. Local files and application state were preserved.'
