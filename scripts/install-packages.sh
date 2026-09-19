#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

PROFILE=desktop
DRY_RUN=0
ASSUME_YES=0
ALLOW_AUR=0

usage() {
    cat <<'EOF'
Usage: scripts/install-packages.sh [options]

Options:
  --profile core|desktop|full  Package profile (default: desktop)
  --dry-run                    Show package decisions without installing
  --yes                        Pass non-interactive confirmation flags
  --allow-aur                  Explicitly allow review/build of missing AUR packages
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
        --allow-aur)
            ALLOW_AUR=1
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
        # Manifests contain package names, never helper options or paths.
        # Validate the complete specification before any authorization/build.
        package_name_pattern='[a-zA-Z0-9@_+][a-zA-Z0-9@._+-]*'
        [[ $line =~ ^${package_name_pattern}(\|${package_name_pattern})*$ ]] || \
            die "Invalid package specification in $manifest"
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

if ((${#aur_packages[@]})) && [[ $ALLOW_AUR -ne 1 ]]; then
    warn 'The following packages require untrusted AUR build recipes:'
    printf '  %s\n' "${aur_packages[@]}" >&2
    die 'Re-run with --allow-aur only after reviewing those PKGBUILDs.'
fi

if ((${#repo_packages[@]} || ${#aur_packages[@]})); then
    ensure_sudo_session
fi

if ((${#repo_packages[@]})); then
    info "Installing ${#repo_packages[@]} repository package(s)"
    pacman_args=(sudo pacman -S --needed)
    [[ $ASSUME_YES -eq 1 ]] && pacman_args+=(--noconfirm)
    run "${pacman_args[@]}" -- "${repo_packages[@]}"
else
    success 'All repository packages are already installed.'
fi

if ((${#aur_packages[@]})); then
    aur_helper=''
    for candidate in paru yay; do
        if command -v "$candidate" >/dev/null 2>&1; then
            aur_helper=$candidate
            break
        fi
    done

    if [[ -z $aur_helper ]]; then
        die 'Install and review an AUR helper manually before using --allow-aur.'
    fi

    info "Installing ${#aur_packages[@]} AUR package(s) with $aur_helper"
    # AUR packages must be built as the regular user. The helper's sudo loop
    # keeps the single credential acquired above valid for package installs.
    aur_args=("$aur_helper" --sudoloop --useask -S --needed)
    run "${aur_args[@]}" -- "${aur_packages[@]}"
else
    success 'No AUR packages are missing.'
fi

success "Package profile '$PROFILE' is satisfied."
