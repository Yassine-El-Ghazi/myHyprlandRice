#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/scripts/lib.sh"

PROFILE=desktop
DRY_RUN=0
ASSUME_YES=0
INSTALL_PACKAGES=1
CONFIGURE_SYSTEM=1
LINK_DOTFILES=1
INSTALL_HOOKS=1

usage() {
    cat <<'EOF'
Usage: ./bootstrap.sh [options]

Reproduce this dotfiles setup on an Arch-based system.

Options:
  --profile core|desktop|full  Package profile (default: desktop)
  --dry-run                    Print every mutation without applying it
  --yes                        Accept package and conflict-backup prompts
  --no-packages                Skip package installation
  --no-system                  Skip service and user-directory configuration
  --no-link                    Skip Stow linking
  --no-hooks                   Do not enable repository Git hooks
  -h, --help                   Show this help
EOF
}

while (($#)); do
    case $1 in
        --profile)
            (($# >= 2)) || die '--profile requires a value'
            PROFILE=$2
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --yes)
            ASSUME_YES=1
            shift
            ;;
        --no-packages)
            INSTALL_PACKAGES=0
            shift
            ;;
        --no-system)
            CONFIGURE_SYSTEM=0
            shift
            ;;
        --no-link)
            LINK_DOTFILES=0
            shift
            ;;
        --no-hooks)
            INSTALL_HOOKS=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

case $PROFILE in
    core|desktop|full) ;;
    *) die "Unknown profile '$PROFILE'; expected core, desktop, or full" ;;
esac

common_args=()
[[ $DRY_RUN -eq 1 ]] && common_args+=(--dry-run)
[[ $ASSUME_YES -eq 1 ]] && common_args+=(--yes)

info "Bootstrap profile: $PROFILE"
[[ $DRY_RUN -eq 1 ]] && warn 'Dry-run mode: no changes will be made.'

if [[ $INSTALL_PACKAGES -eq 1 ]]; then
    "$REPO_ROOT/scripts/install-packages.sh" --profile "$PROFILE" "${common_args[@]}"
fi

"$REPO_ROOT/scripts/migrate-namespace.sh" "${common_args[@]}"
"$REPO_ROOT/scripts/migrate-local.sh" "${common_args[@]}"

if [[ $PROFILE == desktop || $PROFILE == full ]]; then
    "$REPO_ROOT/scripts/repair-flatpak.sh" "${common_args[@]}"
fi

if [[ $LINK_DOTFILES -eq 1 ]]; then
    "$REPO_ROOT/scripts/link-dotfiles.sh" --backup-conflicts "${common_args[@]}"
    seed_args=()
    [[ $DRY_RUN -eq 1 ]] && seed_args+=(--dry-run)
    "$REPO_ROOT/scripts/seed-runtime.sh" "${seed_args[@]}"
fi

if [[ $CONFIGURE_SYSTEM -eq 1 && ( $PROFILE == desktop || $PROFILE == full ) ]]; then
    "$REPO_ROOT/scripts/configure-system.sh" "${common_args[@]}"
fi

if [[ $INSTALL_HOOKS -eq 1 ]]; then
    info 'Enabling repository-local Git hooks'
    if [[ $DRY_RUN -eq 1 ]]; then
        print_command git -C "$REPO_ROOT" config core.hooksPath .githooks
    else
        git -C "$REPO_ROOT" config core.hooksPath .githooks
    fi
fi

if [[ $DRY_RUN -eq 0 ]]; then
    "$REPO_ROOT/scripts/doctor.sh" --profile "$PROFILE"
    success 'Bootstrap complete. Log out and back in before starting Hyprland.'
else
    success 'Dry run complete.'
fi
