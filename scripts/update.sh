#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

PROFILE=desktop
ASSUME_YES=0

while (($#)); do
    case $1 in
        --profile)
            (($# >= 2)) || die '--profile requires a value'
            PROFILE=$2
            shift 2
            ;;
        --yes)
            ASSUME_YES=1
            shift
            ;;
        -h|--help)
            printf 'Usage: scripts/update.sh [--profile core|desktop|full] [--yes]\n'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

case $PROFILE in
    core|desktop|full) ;;
    *) die "Unknown profile '$PROFILE'" ;;
esac

require_command git
if [[ -n $(git -C "$REPO_ROOT" status --porcelain) ]]; then
    die 'The repository has uncommitted changes. Commit or stash them before updating.'
fi

info 'Fast-forwarding the dotfiles repository'
git -C "$REPO_ROOT" pull --ff-only

args=(--profile "$PROFILE")
[[ $ASSUME_YES -eq 1 ]] && args+=(--yes)
"$REPO_ROOT/scripts/install-packages.sh" "${args[@]}"

repair_args=()
[[ $ASSUME_YES -eq 1 ]] && repair_args+=(--yes)
if [[ $PROFILE == desktop || $PROFILE == full ]]; then
    "$REPO_ROOT/scripts/repair-flatpak.sh" "${repair_args[@]}"
fi

link_args=(--backup-conflicts)
[[ $ASSUME_YES -eq 1 ]] && link_args+=(--yes)
"$REPO_ROOT/scripts/link-dotfiles.sh" "${link_args[@]}"
"$REPO_ROOT/scripts/seed-runtime.sh"
"$REPO_ROOT/scripts/doctor.sh" --profile "$PROFILE"

success 'Dotfiles and declared dependencies are up to date.'
