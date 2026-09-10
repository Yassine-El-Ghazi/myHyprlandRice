#!/usr/bin/env bash
# shellcheck disable=SC2034  # Flags are consumed by run()/confirm() from lib.sh.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

DRY_RUN=0
ASSUME_YES=0
LEGACY_REMOTE=ml4w-repo
LEGACY_GTK_THEME=org.gtk.Gtk3theme.Breeze-Dark
SUPPORTED_GTK_THEME=org.gtk.Gtk3theme.Breeze

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

declare -A legacy_configured=([user]=0 [system]=0)
declare -A legacy_has_refs=([user]=0 [system]=0)
declare -A removed_scope=([user]=0 [system]=0)

for scope in user system; do
    scope_flag="--$scope"
    if remotes=$(flatpak "$scope_flag" remotes --columns=name 2>/dev/null); then
        :
    else
        die "Could not inspect $scope Flatpak remotes safely."
    fi
    grep -Fxq -- "$LEGACY_REMOTE" <<< "$remotes" || continue
    legacy_configured[$scope]=1
    if origins=$(flatpak "$scope_flag" list --columns=origin 2>/dev/null); then
        :
    else
        die "Could not inspect installed $scope Flatpak refs safely."
    fi
    if grep -Fxq -- "$LEGACY_REMOTE" <<< "$origins"; then
        legacy_has_refs[$scope]=1
        warn "$scope Flatpak remote '$LEGACY_REMOTE' still owns installed refs; retaining it."
    fi
done

if [[ ${legacy_has_refs[user]} -eq 1 || ${legacy_has_refs[system]} -eq 1 ]]; then
    die "Migrate refs from '$LEGACY_REMOTE' before removing the remote."
fi

for scope in user system; do
    [[ ${legacy_configured[$scope]} -eq 1 ]] || continue
    confirm "Remove unused $scope Flatpak remote '$LEGACY_REMOTE'?"
    if [[ $scope == user ]]; then
        run flatpak --user remote-delete "$LEGACY_REMOTE"
    else
        ensure_sudo_session
        run sudo flatpak --system remote-delete "$LEGACY_REMOTE"
    fi
    removed_scope[$scope]=1
done

if [[ ${removed_scope[user]} -eq 1 || ${removed_scope[system]} -eq 1 ]]; then
    info 'Refreshing metadata for the remaining Flatpak remotes'
    for scope in user system; do
        [[ ${removed_scope[$scope]} -eq 1 ]] || continue
        if remaining=$(flatpak "--$scope" remotes --columns=name 2>/dev/null); then
            :
        else
            die "Could not re-check $scope Flatpak remotes safely."
        fi
        if ! grep -Fvx -- "$LEGACY_REMOTE" <<< "$remaining" | \
            grep -q '[^[:space:]]'; then
            continue
        fi
        if [[ $scope == user ]]; then
            run flatpak --user update --appstream -y
        else
            ensure_sudo_session
            run sudo flatpak --system update --appstream -y
        fi
    done
    success "Removed the unused '$LEGACY_REMOTE' Flatpak remote."
else
    success "No stale '$LEGACY_REMOTE' Flatpak remote is configured."
fi

# Breeze now includes its dark stylesheet in the supported Breeze extension.
# The tracked GTK settings select Breeze with prefer-dark, so the retired
# separate Breeze-Dark extension can be removed once Breeze is available.
for scope in user system; do
    scope_flag="--$scope"
    flatpak "$scope_flag" info "$LEGACY_GTK_THEME" >/dev/null 2>&1 || continue
    if ! flatpak "$scope_flag" info "$SUPPORTED_GTK_THEME" >/dev/null 2>&1; then
        warn "Keeping retired $scope GTK theme because its replacement is unavailable."
        continue
    fi
    confirm "Remove retired $scope Flatpak GTK theme '$LEGACY_GTK_THEME'?"
    if [[ $scope == user ]]; then
        run flatpak --user uninstall --runtime -y "$LEGACY_GTK_THEME"
    else
        require_command pkexec
        run pkexec flatpak --system uninstall --runtime -y "$LEGACY_GTK_THEME"
    fi
done
