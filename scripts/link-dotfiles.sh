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
require_command readlink
require_command realpath
require_command stow
[[ -d $PACKAGE_ROOT ]] || die "Missing Stow package: $PACKAGE_ROOT"

TARGET=$(realpath -m -- "$TARGET")
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
declare -a tracked_relatives=()
declare -A preexisting_managed_links=()

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
            if same_target "$source_dir" "$target_dir"; then
                preexisting_managed_links["$partial"]=$(readlink -- "$target_dir")
            else
                conflicts+=("$partial")
            fi
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

    target_path="$TARGET/$relative"
    tracked_relatives+=("$relative")

    has_parent_conflict "$relative" && continue
    check_parent_dirs "$relative" || continue

    if [[ -L $target_path ]] && same_target "$source_path" "$target_path"; then
        preexisting_managed_links["$relative"]=$(readlink -- "$target_path")
    fi

    if [[ -e $target_path || -L $target_path ]]; then
        same_target "$source_path" "$target_path" || conflicts+=("$relative")
    fi
done < <(git -C "$REPO_ROOT" ls-files -z -- dotfiles)

is_stale_managed_link() {
    local link_path=$1
    local link_target resolved_target

    [[ -L $link_path && ! -e $link_path ]] || return 1
    link_target=$(readlink -- "$link_path")
    if [[ $link_target != /* ]]; then
        link_target="$(dirname -- "$link_path")/$link_target"
    fi
    resolved_target=$(realpath -m -- "$link_target")
    [[ $resolved_target == "$PACKAGE_ROOT/"* ]]
}

declare -a stale_managed_links=()
if [[ -d $TARGET/.config ]]; then
    while IFS= read -r -d '' link_path; do
        is_stale_managed_link "$link_path" || continue
        stale_managed_links+=("${link_path#"$TARGET/"}")
    done < <(find "$TARGET/.config" -type l -print0)
fi

backup_base=${XDG_STATE_HOME:-$TARGET/.local/state}/myhyprlandrice/backups
backup_dir="$backup_base/$(timestamp)"
declare -a moved_conflicts=()

restore_conflicts() {
    local index relative source_path target_path
    local restoration_failed=0

    for ((index = ${#moved_conflicts[@]} - 1; index >= 0; index--)); do
        relative=${moved_conflicts[$index]}
        source_path="$backup_dir/$relative"
        target_path="$TARGET/$relative"
        [[ -e $source_path || -L $source_path ]] || continue
        if [[ -e $target_path || -L $target_path ]]; then
            warn "Rollback target is occupied; recover $relative from $backup_dir"
            restoration_failed=1
            continue
        fi
        mkdir -p -- "$(dirname -- "$target_path")"
        if ! mv -- "$source_path" "$target_path"; then
            warn "Could not restore $relative; recover it from $backup_dir"
            restoration_failed=1
        fi
    done
    return "$restoration_failed"
}

is_link_into_package() {
    local link_path=$1
    local link_target resolved_target
    [[ -L $link_path ]] || return 1
    link_target=$(readlink -- "$link_path")
    if [[ $link_target != /* ]]; then
        link_target="$(dirname -- "$link_path")/$link_target"
    fi
    resolved_target=$(realpath -m -- "$link_target")
    [[ $resolved_target == "$PACKAGE_ROOT/"* ]]
}

remove_transaction_links() {
    local relative target_path parent_directory
    local cleanup_failed=0
    for relative in "${tracked_relatives[@]}"; do
        [[ -z ${preexisting_managed_links[$relative]+x} ]] || continue
        target_path="$TARGET/$relative"
        is_link_into_package "$target_path" || continue
        if ! rm -- "$target_path"; then
            warn "Could not remove transaction-created link: $relative"
            cleanup_failed=1
            continue
        fi
        parent_directory=$(dirname -- "$target_path")
        while [[ $parent_directory == "$TARGET/"* && $parent_directory != "$TARGET" ]]; do
            rmdir -- "$parent_directory" 2>/dev/null || break
            parent_directory=$(dirname -- "$parent_directory")
        done
    done
    return "$cleanup_failed"
}

restore_preexisting_links() {
    local relative target_path expected_target parent_directory
    local restoration_failed=0
    for relative in "${!preexisting_managed_links[@]}"; do
        target_path="$TARGET/$relative"
        expected_target=${preexisting_managed_links[$relative]}
        if [[ -L $target_path ]] && \
            same_target "$PACKAGE_ROOT/$relative" "$target_path"; then
            continue
        fi
        if [[ -d $PACKAGE_ROOT/$relative && -d $target_path && ! -L $target_path ]]; then
            rmdir -- "$target_path" 2>/dev/null || true
        fi
        if [[ -e $target_path || -L $target_path ]]; then
            warn "Pre-existing managed-link path is occupied during rollback: $relative"
            restoration_failed=1
            continue
        fi
        parent_directory=$(dirname -- "$target_path")
        mkdir -p -- "$parent_directory"
        if ! ln -s -- "$expected_target" "$target_path"; then
            warn "Could not restore pre-existing managed link: $relative"
            restoration_failed=1
        fi
    done
    return "$restoration_failed"
}

backup_paths=("${conflicts[@]}" "${stale_managed_links[@]}")
if ((${#backup_paths[@]})); then
    if ((${#conflicts[@]})); then
        warn "Found ${#conflicts[@]} target conflict(s):"
        printf '  %s\n' "${conflicts[@]}" >&2
    fi
    if ((${#stale_managed_links[@]})); then
        warn "Found ${#stale_managed_links[@]} retired managed link(s):"
        printf '  %s\n' "${stale_managed_links[@]}" >&2
    fi
    [[ $BACKUP_CONFLICTS -eq 1 ]] || \
        die 'Re-run with --backup-conflicts to preserve and replace them.'
    confirm "Back up these paths under $backup_dir?"

    for relative in "${backup_paths[@]}"; do
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

print_command stow "${stow_args[@]}"
set +e
stow "${stow_args[@]}"
stow_status=$?
set -e
if [[ $stow_status -ne 0 ]]; then
    rollback_failed=0
    remove_transaction_links || rollback_failed=1
    restore_preexisting_links || rollback_failed=1
    restore_conflicts || rollback_failed=1
    if [[ $rollback_failed -ne 0 ]]; then
        warn "Rollback was incomplete; recover remaining files from $backup_dir"
    else
        info 'Failed Stow transaction was rolled back.'
    fi
    warn "Stow transaction failed with status $stow_status."
    exit "$stow_status"
fi

# Retired links are archived above. Remove only their now-empty parent
# directories, stopping before the shared ~/.config directory.
for relative in "${stale_managed_links[@]}"; do
    parent_directory=$(dirname -- "$TARGET/$relative")
    while [[ $parent_directory == "$TARGET/.config/"* ]]; do
        rmdir -- "$parent_directory" 2>/dev/null || break
        parent_directory=$(dirname -- "$parent_directory")
    done
done

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
