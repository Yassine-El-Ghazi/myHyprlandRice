#!/usr/bin/env bash
# shellcheck disable=SC2034  # Flags are consumed by run()/confirm() from lib.sh.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

DRY_RUN=0
ASSUME_YES=0

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
            printf 'Usage: scripts/migrate-local.sh [--dry-run] [--yes]\n'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

version_from() {
    "$@" 2>/dev/null | rg -o '[0-9]+(\.[0-9]+){1,3}' | head -n 1
}

version_is_older() {
    local candidate=$1
    local current=$2
    local first
    first=$(printf '%s\n%s\n' "$candidate" "$current" | sort -V | head -n 1)
    [[ $candidate != "$current" && $first == "$candidate" ]]
}

declare -a stale_paths=()
declare -a stale_labels=()

check_shadow() {
    local name=$1
    local local_path=$2
    local system_path=$3
    local local_version system_version

    [[ -x $local_path && -x $system_path ]] || return 0
    case $name in
        matugen)
            local_version=$(version_from "$local_path" --version || true)
            system_version=$(version_from "$system_path" --version || true)
            ;;
        oh-my-posh)
            local_version=$(version_from "$local_path" version || true)
            system_version=$(version_from "$system_path" version || true)
            ;;
        *) return 0 ;;
    esac

    if [[ -n $local_version && -n $system_version ]] && \
        version_is_older "$local_version" "$system_version"; then
        stale_paths+=("$local_path")
        stale_labels+=("$name $local_version (packaged: $system_version)")
    fi
}

check_shadow matugen "$HOME/.local/bin/matugen" /usr/bin/matugen
check_shadow oh-my-posh "$HOME/.local/bin/oh-my-posh" /usr/bin/oh-my-posh

legacy_backups=(
    "$REPO_ROOT/dotfiles/.config/fish/conf.d/fish_frozen_theme.fish.bak"
    "$REPO_ROOT/dotfiles/.config/ohmyposh/zen.toml.bak"
)
for path in "${legacy_backups[@]}"; do
    if [[ -e $path || -L $path ]]; then
        stale_paths+=("$path")
        stale_labels+=("legacy backup ${path#"$REPO_ROOT/"}")
    fi
done

if ((${#stale_paths[@]} == 0)); then
    success 'No stale user-local shadows or legacy backups found.'
    exit 0
fi

warn 'The following stale files shadow packaged tools or clutter the checkout:'
printf '  %s\n' "${stale_labels[@]}" >&2
archive_root="${XDG_STATE_HOME:-$HOME/.local/state}/myhyprlandrice/migrations/$(timestamp)"
confirm "Archive them under $archive_root?"

for index in "${!stale_paths[@]}"; do
    source_path=${stale_paths[$index]}
    if [[ $source_path == "$REPO_ROOT/"* ]]; then
        relative_path="repository/${source_path#"$REPO_ROOT/"}"
    else
        relative_path="home/${source_path#"$HOME/"}"
    fi
    destination="$archive_root/$relative_path"
    run mkdir -p -- "$(dirname -- "$destination")"
    run mv -- "$source_path" "$destination"
done

success "Stale local files archived at $archive_root"
