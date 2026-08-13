#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

PROFILE=desktop
RUN_VALIDATION=1

while (($#)); do
    case $1 in
        --profile)
            (($# >= 2)) || die '--profile requires a value'
            PROFILE=$2
            shift 2
            ;;
        --quick)
            RUN_VALIDATION=0
            shift
            ;;
        -h|--help)
            printf 'Usage: scripts/doctor.sh [--profile core|desktop|full] [--quick]\n'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

case $PROFILE in
    core|desktop|full) ;;
    *) die "Unknown profile '$PROFILE'" ;;
esac

errors=0
warnings=0
checks=0

ok() {
    checks=$((checks + 1))
    printf '%sOK%s    %s\n' "$_C_GREEN" "$_C_RESET" "$1"
}

problem() {
    checks=$((checks + 1))
    errors=$((errors + 1))
    printf '%sFAIL%s  %s\n' "$_C_RED" "$_C_RESET" "$1" >&2
}

notice() {
    warnings=$((warnings + 1))
    printf '%sWARN%s  %s\n' "$_C_YELLOW" "$_C_RESET" "$1" >&2
}

check_commands() {
    local group=$1
    shift
    local missing=()
    local spec alternative found
    local -a alternatives

    for spec in "$@"; do
        found=0
        IFS='|' read -r -a alternatives <<< "$spec"
        for alternative in "${alternatives[@]}"; do
            if command -v "$alternative" >/dev/null 2>&1; then
                found=1
                break
            fi
        done
        [[ $found -eq 1 ]] || missing+=("$spec")
    done

    if ((${#missing[@]})); then
        problem "$group commands missing: ${missing[*]}"
    else
        ok "$group commands are available"
    fi
}

core_commands=(
    git stow rsync jq bash zsh fish nvim kitty rg fd fzf eza bat fastfetch btop
    oh-my-posh lua luac shellcheck shfmt gitleaks python
)
desktop_commands=(
    Hyprland hyprctl hypridle hyprlock hyprpicker waybar 'qs|quickshell' rofi
    walker swaync-client nwg-dock-hyprland awww waypaper matugen grim slurp
    hyprshot satty wl-copy cliphist tesseract brightnessctl playerctl nm-applet
    blueman-manager pavucontrol wpctl pactl notify-send nautilus yazi
    gnome-calculator gnome-text-editor qalculate-gtk rofimoji pinta gum checkupdates
)
full_commands=(evolution firefox thunderbird vlc loupe hyprshade tty-clock)

check_commands Core "${core_commands[@]}"
if [[ $PROFILE == desktop || $PROFILE == full ]]; then
    check_commands Desktop "${desktop_commands[@]}"
fi
if [[ $PROFILE == full ]]; then
    check_commands Full "${full_commands[@]}"
fi

managed=0
unmanaged=0
while IFS= read -r -d '' tracked_path; do
    relative=${tracked_path#dotfiles/}
    [[ $relative == .stow-local-ignore ]] && continue
    source_path="$REPO_ROOT/$tracked_path"
    target_path="$HOME/$relative"
    if [[ -e $target_path || -L $target_path ]] && [[ $target_path -ef $source_path ]]; then
        managed=$((managed + 1))
    else
        unmanaged=$((unmanaged + 1))
    fi
done < <(git -C "$REPO_ROOT" ls-files -z -- dotfiles)

if [[ $unmanaged -eq 0 ]]; then
    ok "$managed tracked dotfiles resolve to this checkout"
else
    problem "$unmanaged tracked dotfiles are not linked (managed: $managed)"
fi

folded=()
for directory in hypr waybar fish nvim kitty; do
    [[ -L $HOME/.config/$directory ]] && folded+=("$directory")
done
if ((${#folded[@]})); then
    problem "Folded config-directory links remain (${folded[*]}); run scripts/link-dotfiles.sh"
else
    ok 'Stow uses individual links; runtime state is isolated from Git'
fi

runtime_links=()
runtime_paths=(
    .config/fish/fish_variables
    .config/waypaper/config.ini
    .config/hypr/local.lua
    .config/gtk-3.0/colors.css
    .config/gtk-4.0/colors.css
    .config/hypr/colors.conf
    .config/hypr/colors.lua
    .config/kitty/colors-matugen.conf
    .config/ml4w/colors/onsurface
    .config/ml4w/colors/primary
    .config/ml4w/colors/secondary
    .config/nwg-dock-hyprland/colors.css
    .config/rofi/colors.rasi
    .config/swaync/colors.css
    .config/walker/colors.css
    .config/waybar/colors.css
    .config/wlogout/colors.css
)
for relative in "${runtime_paths[@]}"; do
    [[ -L $HOME/$relative ]] && runtime_links+=("$relative")
done
if ((${#runtime_links[@]})); then
    problem "Runtime files are symlinked into Git: ${runtime_links[*]}"
else
    ok 'Runtime and machine-local files are not symlinked into Git'
fi

missing_runtime=()
while IFS= read -r -d '' default_path; do
    relative=${default_path#"$REPO_ROOT/defaults/"}
    [[ -e $HOME/$relative ]] || missing_runtime+=("$relative")
done < <(find "$REPO_ROOT/defaults" -type f -print0)
if ((${#missing_runtime[@]})); then
    problem "Runtime defaults are missing: ${missing_runtime[*]}"
else
    ok 'All required generated/runtime defaults are present'
fi

shadowed=()
for command_name in matugen oh-my-posh; do
    command_path=$(command -v "$command_name" 2>/dev/null || true)
    [[ $command_path == "$HOME/.local/bin/"* && -x /usr/bin/$command_name ]] && \
        shadowed+=("$command_name ($command_path)")
done
if ((${#shadowed[@]})); then
    problem "User-local binaries shadow packaged tools: ${shadowed[*]}"
else
    ok 'No known stale user-local binary shadows'
fi

hooks_path=$(git -C "$REPO_ROOT" config --get core.hooksPath || true)
if [[ $hooks_path == .githooks ]]; then
    ok 'Repository privacy/security pre-commit hook is enabled'
else
    problem 'Git hooks are not enabled (run: git config core.hooksPath .githooks)'
fi

if [[ -f $HOME/.config/hypr/hyprland.lua ]]; then
    ok 'Hyprland uses the current Lua configuration entrypoint'
else
    problem 'Hyprland Lua entrypoint is missing'
fi

if command -v flatpak >/dev/null 2>&1 && \
    flatpak remotes --columns=name 2>/dev/null | grep -Fxq ml4w-repo; then
    problem "Obsolete Flatpak remote 'ml4w-repo' remains (run scripts/repair-flatpak.sh)"
else
    ok 'No obsolete ML4W Flatpak remote is configured'
fi

if command -v systemctl >/dev/null 2>&1; then
    for service in NetworkManager.service bluetooth.service; do
        systemctl is-enabled "$service" >/dev/null 2>&1 || \
            notice "$service is not enabled"
        systemctl is-active "$service" >/dev/null 2>&1 || \
            notice "$service is not active"
    done
fi

if [[ -n $(git -C "$REPO_ROOT" status --porcelain) ]]; then
    notice 'Repository has uncommitted changes'
else
    ok 'Repository working tree is clean'
fi

if [[ $RUN_VALIDATION -eq 1 ]]; then
    if "$SCRIPT_DIR/check.sh"; then
        ok 'Configuration validation suite passes'
    else
        problem 'Configuration validation suite failed'
    fi
fi

printf '\nDoctor summary: %d checks, %d error(s), %d warning(s)\n' "$checks" "$errors" "$warnings"
[[ $errors -eq 0 ]]
