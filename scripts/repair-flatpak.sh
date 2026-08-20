#!/usr/bin/env bash
# shellcheck disable=SC2034  # Flags are consumed by run()/confirm() from lib.sh.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

DRY_RUN=0
ASSUME_YES=0
LEGACY_REMOTE=ml4w-repo

while (($#)); do
    case $1 in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --yes)
            ASSUME_YES=1
            shift
            ;;
        -h|--help)
            printf 'Usage: scripts/repair-flatpak.sh [--dry-run] [--yes]\n'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

if ! command -v flatpak >/dev/null 2>&1; then
    success 'Flatpak is not installed; no remote repair is needed.'
    exit 0
fi

removed=0
blocked=0
for scope in user system; do
    scope_flag="--$scope"
    if ! flatpak remotes "$scope_flag" --columns=name 2>/dev/null | \
        grep -Fxq -- "$LEGACY_REMOTE"; then
        continue
    fi

    if flatpak list "$scope_flag" --columns=origin 2>/dev/null | \
        grep -Fxq -- "$LEGACY_REMOTE"; then
        warn "$scope Flatpak remote '$LEGACY_REMOTE' still owns installed refs; retaining it."
        blocked=1
        continue
    fi

    confirm "Remove unused $scope Flatpak remote '$LEGACY_REMOTE'?"
    run flatpak remote-delete "$scope_flag" "$LEGACY_REMOTE"
    removed=1
done

if [[ $blocked -eq 1 ]]; then
    die "Migrate refs from '$LEGACY_REMOTE' before removing the remote."
fi

if [[ $removed -eq 1 ]]; then
    info 'Refreshing metadata for the remaining Flatpak remotes'
    run flatpak update --appstream -y
    success "Removed the unused '$LEGACY_REMOTE' Flatpak remote."
else
    success "No stale '$LEGACY_REMOTE' Flatpak remote is configured."
fi
