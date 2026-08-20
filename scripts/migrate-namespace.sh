#!/usr/bin/env bash
# shellcheck disable=SC2034  # Flags are consumed by run()/confirm() from lib.sh.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

DRY_RUN=0
ASSUME_YES=0
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
        --yes)
            ASSUME_YES=1
            shift
            ;;
        -h|--help)
            printf 'Usage: scripts/migrate-namespace.sh [--target DIR] [--dry-run] [--yes]\n'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

require_command realpath
TARGET=$(realpath -m -- "$TARGET")
[[ $TARGET != / ]] || die 'Refusing to migrate the root directory.'
legacy_root="$TARGET/.config/ml4w"
new_root="$TARGET/.config/myhypr"
new_settings="$new_root/settings"
default_settings="$REPO_ROOT/defaults/.config/myhypr/settings"

legacy_paths=(
    "$legacy_root"
    "$TARGET/.config/ml4w-dotfiles-installer"
    "$TARGET/.config/ml4w-dotfiles-settings"
    "$TARGET/.config/ml4w-dotfiles-settings.backup"
    "$TARGET/.config/com.ml4w.hyprlandsettings"
    "$TARGET/.local/share/ml4w-dotfiles-settings"
    "$TARGET/.local/share/ml4w-dotfiles-installer"
    "$TARGET/.local/bin/ml4w-dotfiles-settings"
    "$TARGET/.local/bin/ml4w-dotfiles-installer"
)

found_paths=()
for path in "${legacy_paths[@]}"; do
    [[ -e $path || -L $path ]] && found_paths+=("$path")
done

legacy_cache="$TARGET/.cache/ml4w/hyprland-dotfiles"
legacy_welcome_marker="$TARGET/.cache/ml4w-welcome-autostart"
if ((${#found_paths[@]} == 0)) && \
    [[ ! -e $legacy_cache && ! -e $legacy_welcome_marker ]]; then
    success 'No legacy ML4W runtime state found.'
    exit 0
fi

warn 'Legacy ML4W runtime state will be migrated and archived:'
printf '  %s\n' "${found_paths[@]}" >&2
[[ -e $legacy_cache ]] && printf '  %s\n' "$legacy_cache" >&2
[[ -e $legacy_welcome_marker ]] && printf '  %s\n' "$legacy_welcome_marker" >&2
confirm 'Continue with the standalone namespace migration?'

run mkdir -p -- "$new_settings"

copy_setting() {
    local new_name=$1
    local legacy_name=${2:-$1}
    local source_path="$legacy_root/settings/$legacy_name"
    local target_path="$new_settings/$new_name"

    [[ -r $source_path && ! -e $target_path && ! -L $target_path ]] || return 0
    run cp -L -- "$source_path" "$target_path"
}

if [[ -d $default_settings ]]; then
    while IFS= read -r -d '' default_path; do
        name=${default_path##*/}
        case $name in
            aur) copy_setting "$name" aur.sh ;;
            browser|email|editor|bluetooth|calculator|terminal)
                copy_setting "$name" "$name.sh"
                ;;
            filemanager) copy_setting "$name" filemanager.sh ;;
            networkmanager|software|welcome-on-startup) ;;
            wallpaper-folder)
                legacy_wallpaper=''
                [[ -r $legacy_root/settings/wallpaper-folder ]] && \
                    legacy_wallpaper=$(<"$legacy_root/settings/wallpaper-folder")
                if [[ -n $legacy_wallpaper && $legacy_wallpaper != *'.config/ml4w/wallpapers'* ]]; then
                    copy_setting "$name"
                fi
                ;;
            *) copy_setting "$name" ;;
        esac
    done < <(find "$default_settings" -maxdepth 1 -type f -print0)
fi

for color_name in primary secondary onsurface; do
    source_path="$legacy_root/colors/$color_name"
    target_path="$new_root/colors/$color_name"
    [[ -r $source_path && ! -e $target_path && ! -L $target_path ]] || continue
    run mkdir -p -- "$new_root/colors"
    run cp -L -- "$source_path" "$target_path"
done

sidepad_setting="$new_settings/sidepad-active"
if [[ $DRY_RUN -eq 0 && -f $sidepad_setting ]]; then
    current_sidepad=$(<"$sidepad_setting")
    if [[ $current_sidepad == ml4w-* ]]; then
        printf 'myhypr-%s\n' "${current_sidepad#ml4w-}" > "$sidepad_setting"
    fi
fi

waybar_theme_setting="$new_settings/waybar-theme.sh"
if [[ $DRY_RUN -eq 0 && -f $waybar_theme_setting ]]; then
    current_waybar_theme=$(<"$waybar_theme_setting")
    current_waybar_theme=${current_waybar_theme//\/ml4w/\/myhypr}
    printf '%s\n' "$current_waybar_theme" > "$waybar_theme_setting"
fi

walker_theme_setting="$new_settings/walker-theme"
if [[ $DRY_RUN -eq 0 && -f $walker_theme_setting ]] && \
    [[ $(<"$walker_theme_setting") == ml4w ]]; then
    printf 'myhypr\n' > "$walker_theme_setting"
fi

hyprshade_setting="$new_settings/hyprshade.sh"
if [[ $DRY_RUN -eq 0 && -f $hyprshade_setting ]]; then
    current_hyprshade=$(<"$hyprshade_setting")
    if [[ $current_hyprshade == 'hyprshade_filter="'*'"' ]]; then
        current_hyprshade=${current_hyprshade#'hyprshade_filter="'}
        current_hyprshade=${current_hyprshade%'"'}
        printf '%s\n' "$current_hyprshade" > "$hyprshade_setting"
    fi
fi

if [[ -e $legacy_welcome_marker && ! -e $new_settings/welcome-on-startup ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
        print_command printf 'False\n' '>' "$new_settings/welcome-on-startup"
    else
        printf 'False\n' > "$new_settings/welcome-on-startup"
    fi
fi

if [[ $TARGET == "$HOME" ]]; then
    state_root=${XDG_STATE_HOME:-$TARGET/.local/state}
else
    state_root="$TARGET/.local/state"
fi
archive_root="$state_root/myhyprlandrice/migrations/$(timestamp)/legacy-ml4w"

new_cache="$TARGET/.cache/myhypr"
if [[ -d $legacy_cache && ! -e $new_cache ]]; then
    run mkdir -p -- "$(dirname -- "$new_cache")"
    run mv -- "$legacy_cache" "$new_cache"
elif [[ -e $legacy_cache || -L $legacy_cache ]]; then
    destination="$archive_root/.cache/ml4w/hyprland-dotfiles"
    run mkdir -p -- "$(dirname -- "$destination")"
    run mv -- "$legacy_cache" "$destination"
fi

for source_path in "${found_paths[@]}"; do
    if [[ $source_path == "$TARGET/"* ]]; then
        relative_path=${source_path#"$TARGET/"}
    else
        relative_path=${source_path#/}
    fi
    destination="$archive_root/$relative_path"
    run mkdir -p -- "$(dirname -- "$destination")"
    run mv -- "$source_path" "$destination"
done

if [[ -e $legacy_welcome_marker ]]; then
    destination="$archive_root/.cache/ml4w-welcome-autostart"
    run mkdir -p -- "$(dirname -- "$destination")"
    run mv -- "$legacy_welcome_marker" "$destination"
fi

success "Standalone namespace migration complete; legacy files archived at $archive_root"
