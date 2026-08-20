#!/usr/bin/env bash
# shellcheck disable=SC2034  # ASSUME_YES is consumed by confirm() from lib.sh.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

DRY_RUN=0
ASSUME_YES=0
BACKUP_CONFLICTS=0
TARGET=$HOME
PACKAGE_ROOT="$REPO_ROOT/dotfiles"

usage() {
    cat <<'EOF'
Usage: scripts/link-dotfiles.sh [options]

Options:
  --target DIR          Stow target (default: $HOME)
  --backup-conflicts    Move conflicting targets into a timestamped backup
  --dry-run             Print planned backups and Stow operations
  --yes                 Accept the conflict backup prompt
  -h, --help            Show this help

The linker deliberately uses GNU Stow's --no-folding mode. Application state
therefore lives in normal ~/.config directories instead of being written into
the Git checkout through a directory symlink.
EOF
}

while (($#)); do
    case $1 in
        --target)
            (($# >= 2)) || die '--target requires a directory'
            TARGET=$2
            shift 2
            ;;
        --backup-conflicts)
            BACKUP_CONFLICTS=1
            shift
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

require_command git
require_command stow
[[ -d $PACKAGE_ROOT ]] || die "Missing Stow package: $PACKAGE_ROOT"

if [[ $TARGET != /* ]]; then
    TARGET="$(cd -- "$(dirname -- "$TARGET")" && pwd -P)/$(basename -- "$TARGET")"
fi
[[ $TARGET != / ]] || die 'Refusing to use / as a Stow target.'

if [[ ! -d $TARGET ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
        print_command mkdir -p "$TARGET"
    else
        mkdir -p -- "$TARGET"
    fi
fi

declare -a conflicts=()
declare -A checked_dirs=()

same_target() {
    local source=$1
    local target=$2
    [[ -e $target || -L $target ]] || return 1
    [[ -e $source || -L $source ]] || return 1
    [[ $target -ef $source ]]
}

has_parent_conflict() {
    local path=$1
    local conflict
    for conflict in "${conflicts[@]}"; do
        [[ $path == "$conflict" || $path == "$conflict/"* ]] && return 0
    done
    return 1
}

check_parent_dirs() {
    local relative=$1
    local partial=''
    local component source_dir target_dir
    local -a components

    IFS='/' read -r -a components <<< "$(dirname -- "$relative")"
    for component in "${components[@]}"; do
        [[ $component == . ]] && continue
        partial=${partial:+$partial/}$component
        [[ -n ${checked_dirs[$partial]+x} ]] && continue
        checked_dirs[$partial]=1
        source_dir="$PACKAGE_ROOT/$partial"
        target_dir="$TARGET/$partial"

        if [[ -L $target_dir ]]; then
            same_target "$source_dir" "$target_dir" || conflicts+=("$partial")
        elif [[ -e $target_dir && ! -d $target_dir ]]; then
            conflicts+=("$partial")
        fi
        has_parent_conflict "$partial" && return 1
    done
    return 0
}

while IFS= read -r -d '' tracked_path; do
    relative=${tracked_path#dotfiles/}
    [[ $relative == .stow-local-ignore ]] && continue
    source_path="$REPO_ROOT/$tracked_path"
    [[ -e $source_path || -L $source_path ]] || continue
    has_parent_conflict "$relative" && continue
    check_parent_dirs "$relative" || continue

    target_path="$TARGET/$relative"
    if [[ -e $target_path || -L $target_path ]]; then
        same_target "$source_path" "$target_path" || conflicts+=("$relative")
    fi
done < <(git -C "$REPO_ROOT" ls-files -z -- dotfiles)

backup_base=${XDG_STATE_HOME:-$TARGET/.local/state}/myhyprlandrice/backups
backup_dir="$backup_base/$(timestamp)"
declare -a moved_conflicts=()

restore_conflicts() {
    local relative source_path target_path
    for relative in "${moved_conflicts[@]}"; do
        source_path="$backup_dir/$relative"
        target_path="$TARGET/$relative"
        [[ -e $source_path || -L $source_path ]] || continue
        mkdir -p -- "$(dirname -- "$target_path")"
        mv -- "$source_path" "$target_path"
    done
}

if ((${#conflicts[@]})); then
    warn "Found ${#conflicts[@]} target conflict(s):"
    printf '  %s\n' "${conflicts[@]}" >&2
    [[ $BACKUP_CONFLICTS -eq 1 ]] || \
        die 'Re-run with --backup-conflicts to preserve and replace them.'
    confirm "Back up these paths under $backup_dir?"

    for relative in "${conflicts[@]}"; do
        source_path="$TARGET/$relative"
        destination="$backup_dir/$relative"
        if [[ $DRY_RUN -eq 1 ]]; then
            print_command mkdir -p "$(dirname -- "$destination")"
            print_command mv -- "$source_path" "$destination"
        else
            mkdir -p -- "$(dirname -- "$destination")"
            mv -- "$source_path" "$destination"
            moved_conflicts+=("$relative")
        fi
    done
fi

stow_args=(--restow --no-folding --dir "$REPO_ROOT" --target "$TARGET" dotfiles)

if [[ $DRY_RUN -eq 1 ]]; then
    print_command stow "${stow_args[@]}"
    success 'Link dry run complete.'
    exit 0
fi

info 'Checking the Stow transaction for conflicts'
if ! stow --simulate "${stow_args[@]}"; then
    restore_conflicts
    die 'Stow simulation failed; backed-up conflicts were restored.'
fi

run stow "${stow_args[@]}"

# These files can exist inside the package after migrating an older folded
# Stow layout. Move them into the now-normal target directories exactly once.
if [[ $TARGET == "$HOME" ]]; then
    runtime_paths=(
        .config/fish/config.local.fish
        .config/fish/fish_variables
        .config/hypr/local.lua
        .config/hypr/monitors.conf
        .config/hypr/monitors.lua
        .config/hypr/workspaces.conf
        .config/hypr/workspaces.lua
        .config/waypaper/config.ini
        .config/gtk-3.0/colors.css
        .config/gtk-4.0/colors.css
        .config/hypr/colors.conf
        .config/hypr/colors.lua
        .config/kitty/colors-matugen.conf
        .config/myhypr/colors/onsurface
        .config/myhypr/colors/primary
        .config/myhypr/colors/secondary
        .config/nwg-dock-hyprland/colors.css
        .config/rofi/colors.rasi
        .config/swaync/colors.css
        .config/walker/colors.css
        .config/waybar/colors.css
        .config/wlogout/colors.css
        .config/myhypr/settings/dock-disabled
        .config/myhypr/settings/gamemode-enabled
        .config/myhypr/settings/waybar-disabled
    )
    for relative in "${runtime_paths[@]}"; do
        source_path="$PACKAGE_ROOT/$relative"
        target_path="$TARGET/$relative"
        [[ -e $source_path || -L $source_path ]] || continue
        if [[ -e $target_path || -L $target_path ]]; then
            warn "Runtime migration skipped because the target exists: $relative"
            continue
        fi
        mkdir -p -- "$(dirname -- "$target_path")"
        mv -- "$source_path" "$target_path"
        info "Migrated local state: $relative"
    done
fi

if ((${#moved_conflicts[@]})); then
    success "Dotfiles linked; previous files are backed up at $backup_dir"
else
    success 'Dotfiles linked with GNU Stow.'
fi
