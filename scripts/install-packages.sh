#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

PROFILE=desktop
DRY_RUN=0
ASSUME_YES=0

usage() {
    cat <<'EOF'
Usage: scripts/install-packages.sh [options]

Options:
  --profile core|desktop|full  Package profile (default: desktop)
  --dry-run                    Show package decisions without installing
  --yes                        Pass non-interactive confirmation flags
  -h, --help                   Show this help

Manifest entries may contain alternatives separated by `|`. An already
installed alternative wins; otherwise a repository package is preferred over
an AUR package.
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
        -h|--help)
            usage
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

case $PROFILE in
    core|desktop|full) ;;
    *) die "Unknown profile '$PROFILE'; expected core, desktop, or full" ;;
esac

[[ $EUID -ne 0 ]] || die 'Run this installer as your regular user, not root.'
require_command pacman

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    distro_family="${ID:-} ${ID_LIKE:-}"
    [[ $distro_family == *arch* || $distro_family == *cachyos* ]] || \
        die 'Package automation currently supports Arch-based distributions only.'
fi

manifest_files=("$REPO_ROOT/packages/arch/core.txt")
if [[ $PROFILE == desktop || $PROFILE == full ]]; then
    manifest_files+=("$REPO_ROOT/packages/arch/desktop.txt")
fi
if [[ $PROFILE == full ]]; then
    manifest_files+=("$REPO_ROOT/packages/arch/full.txt")
fi

declare -a specs=()
declare -A seen_specs=()
for manifest in "${manifest_files[@]}"; do
    [[ -r $manifest ]] || die "Missing package manifest: $manifest"
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%%#*}
        line=${line//[[:space:]]/}
        [[ -n $line ]] || continue
        if [[ -z ${seen_specs[$line]+x} ]]; then
            specs+=("$line")
            seen_specs[$line]=1
        fi
    done < "$manifest"
done

declare -a repo_packages=()
declare -a aur_packages=()

for spec in "${specs[@]}"; do
    IFS='|' read -r -a alternatives <<< "$spec"
    selected=''

    for package in "${alternatives[@]}"; do
        # Dependency checks honor virtual provisions such as elephant-all,
        # whereas `pacman -Q` only accepts the installed package's exact name.
        if pacman -T -- "$package" >/dev/null 2>&1; then
            selected=$package
            break
        fi
    done
    [[ -n $selected ]] && continue

    for package in "${alternatives[@]}"; do
        if pacman -Si -- "$package" >/dev/null 2>&1; then
            selected=$package
            repo_packages+=("$package")
            break
        fi
    done

    if [[ -z $selected ]]; then
        aur_packages+=("${alternatives[0]}")
    fi
done

if ((${#repo_packages[@]} || ${#aur_packages[@]})); then
    ensure_sudo_session
fi

if ((${#repo_packages[@]})); then
    info "Installing ${#repo_packages[@]} repository package(s)"
    pacman_args=(sudo pacman -S --needed)
    [[ $ASSUME_YES -eq 1 ]] && pacman_args+=(--noconfirm)
    run "${pacman_args[@]}" "${repo_packages[@]}"
else
    success 'All repository packages are already installed.'
fi

cleanup_aur_build() {
    local build_root=$1

    case $build_root in
        "${TMPDIR:-/tmp}"/myhyprlandrice-aur.*) rm -rf -- "$build_root" ;;
        *) die "Refusing to remove unexpected AUR build directory: $build_root" ;;
    esac
}

bootstrap_aur_helper() {
    local build_root
    local -a makepkg_args=(-si --needed)

    [[ $ASSUME_YES -eq 1 ]] && makepkg_args+=(--noconfirm)
    if [[ $DRY_RUN -eq 1 ]]; then
        info 'Would bootstrap paru-bin from the Arch User Repository.'
        aur_helper=paru
        return
    fi

    require_command git
    require_command makepkg
    build_root=$(mktemp -d "${TMPDIR:-/tmp}/myhyprlandrice-aur.XXXXXXXX")
    if ! git clone --depth 1 https://aur.archlinux.org/paru-bin.git \
        "$build_root/paru-bin"; then
        cleanup_aur_build "$build_root"
        die 'Unable to clone paru-bin from the Arch User Repository.'
    fi
    if ! (
        cd -- "$build_root/paru-bin"
        makepkg "${makepkg_args[@]}"
    ); then
        cleanup_aur_build "$build_root"
        die 'Unable to build paru-bin.'
    fi
    cleanup_aur_build "$build_root"
    aur_helper=paru
}

if ((${#aur_packages[@]})); then
    aur_helper=''
    for candidate in paru yay; do
        if command -v "$candidate" >/dev/null 2>&1; then
            aur_helper=$candidate
            break
        fi
    done

    if [[ -z $aur_helper ]]; then
        info 'An AUR helper is required for remaining packages.'
        confirm 'Build paru-bin from the AUR?'
        bootstrap_aur_helper
    fi

    info "Installing ${#aur_packages[@]} AUR package(s) with $aur_helper"
    # AUR packages must be built as the regular user. The helper's sudo loop
    # keeps the single credential acquired above valid for package installs.
    aur_args=("$aur_helper" --sudoloop -S --needed)
    [[ $ASSUME_YES -eq 1 ]] && aur_args+=(--noconfirm)
    run "${aur_args[@]}" "${aur_packages[@]}"
else
    success 'No AUR packages are missing.'
fi

success "Package profile '$PROFILE' is satisfied."
