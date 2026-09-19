#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes write literal mock-script variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-packages-test.XXXXXXXX")
FAKE_BIN="$TEST_ROOT/bin"
export PACKAGE_TEST_BIN="$FAKE_BIN"
export PACKAGE_TEST_LOG="$TEST_ROOT/commands.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-packages-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

desktop_manifest="$REPO_ROOT/packages/arch/desktop.txt"
core_manifest="$REPO_ROOT/packages/arch/core.txt"
validation_workflow="$REPO_ROOT/.github/workflows/validate.yml"
nvim_config="$REPO_ROOT/dotfiles/.config/nvim/init.lua"
doctor="$REPO_ROOT/scripts/doctor.sh"
hypr_environment="$REPO_ROOT/dotfiles/.config/hypr/conf/myhypr.lua"
hypr_environment_compat="$REPO_ROOT/dotfiles/.config/hypr/conf/myhypr.conf"
default_environment="$REPO_ROOT/dotfiles/.config/hypr/conf/environments/default.lua"
default_environment_compat="$REPO_ROOT/dotfiles/.config/hypr/conf/environments/default.conf"
kitty_config="$REPO_ROOT/dotfiles/.config/kitty/kitty.conf"
nvidia_environment="$REPO_ROOT/dotfiles/.config/hypr/conf/environments/nvidia.lua"
nvidia_environment_compat="$REPO_ROOT/dotfiles/.config/hypr/conf/environments/nvidia.conf"
rustup_fish="$REPO_ROOT/dotfiles/.config/fish/conf.d/rustup.fish"
for maintenance_package in bubblewrap util-linux; do
    rg -Fxq "$maintenance_package" "$core_manifest" || {
        printf 'Core profile is missing maintenance sandbox package: %s\n' \
            "$maintenance_package" >&2
        exit 1
    }
    rg -q "(^|[[:space:]])${maintenance_package}([[:space:]]|$)" \
        "$validation_workflow" || {
        printf 'CI is missing maintenance sandbox package: %s\n' \
            "$maintenance_package" >&2
        exit 1
    }
done
for editor_dependency in nodejs tree-sitter-cli; do
    rg -Fxq "$editor_dependency" "$core_manifest" || {
        printf 'Core profile is missing Neovim runtime dependency: %s\n' \
            "$editor_dependency" >&2
        exit 1
    }
done
rg -Fxq breeze-gtk "$desktop_manifest" || {
    printf 'Desktop profile is missing the configured GTK theme package.\n' >&2
    exit 1
}
rg -Fxq capitaine-cursors "$desktop_manifest" || {
    printf 'Desktop profile is missing the configured cursor package.\n' >&2
    exit 1
}
for cursor_config in "$default_environment" "$default_environment_compat"; do
    rg -q 'XCURSOR_THEME.*capitaine-cursors' "$cursor_config" || {
        printf 'Default cursor does not match the package manifest in %s.\n' \
            "$cursor_config" >&2
        exit 1
    }
    if rg -q 'Bibata|HYPRCURSOR_THEME' "$cursor_config"; then
        printf 'Default environment still selects an unavailable cursor in %s.\n' \
            "$cursor_config" >&2
        exit 1
    fi
done
rg -q '^globinclude \./custom\.conf$' "$kitty_config" || {
    printf 'Kitty local customization is not optional.\n' >&2
    exit 1
}
if rg -q '^include themes/' "$kitty_config"; then
    printf 'Kitty includes an untracked theme file.\n' >&2
    exit 1
fi
for nvidia_config in "$nvidia_environment" "$nvidia_environment_compat"; do
    rg -q '__GLX_VENDOR_LIBRARY_NAME.*nvidia' "$nvidia_config" || {
        printf 'NVIDIA profile lost its narrow XWayland compatibility hint.\n' >&2
        exit 1
    }
    rg -q 'no_hardware_cursors.*true' "$nvidia_config" || {
        printf 'NVIDIA profile lost its explicit cursor fallback.\n' >&2
        exit 1
    }
    if rg -q 'GBM_BACKEND|LIBVA_DRIVER_NAME|__NV_PRIME_RENDER_OFFLOAD|__VK_LAYER_NV_optimus|WLR_NO_HARDWARE_CURSORS|WLR_RENDERER_ALLOW_SOFTWARE|MOZ_DISABLE_RDD_SANDBOX|EGL_PLATFORM' \
        "$nvidia_config"; then
        printf 'NVIDIA profile still contains broad or obsolete global overrides.\n' >&2
        exit 1
    fi
done
rg -Fq "pattern = { 'sh'," "$nvim_config" || {
    printf 'Neovim Tree-sitter does not attach to normal shell filetypes.\n' >&2
    exit 1
}
rg -q 'node tree-sitter' "$doctor" || {
    printf 'Doctor does not validate Neovim runtime dependencies.\n' >&2
    exit 1
}
for environment_file in "$hypr_environment" "$hypr_environment_compat"; do
    [[ $(rg -c 'QT_QPA_PLATFORMTHEME' "$environment_file") -eq 1 ]] || {
        printf 'Qt platform-theme ownership is ambiguous in %s.\n' "$environment_file" >&2
        exit 1
    }
    rg -q 'QT_QPA_PLATFORMTHEME.*qt6ct' "$environment_file" || {
        printf 'Qt platform-theme does not match the package manifest in %s.\n' \
            "$environment_file" >&2
        exit 1
    }
done
mkdir -p -- "$TEST_ROOT/no-cargo-home"
HOME="$TEST_ROOT/no-cargo-home" fish -c "source '$rustup_fish'" || {
    printf 'Fish startup fails when optional Rust state is absent.\n' >&2
    exit 1
}
rg -q 'runuser --user myhypr-validator' "$validation_workflow" || {
    printf 'CI maintenance validation is not explicitly unprivileged.\n' >&2
    exit 1
}
rg -q 'chown --recursive --no-dereference' "$validation_workflow" || {
    printf 'CI ownership preparation may dereference repository symlinks.\n' >&2
    exit 1
}
[[ $(rg -c '^elephant-all$' "$desktop_manifest") -eq 1 ]]
if rg -q '^elephant$|^elephant-(calc|clipboard|desktopapplications|files|menus|providerlist|runner|symbols|todo|websearch)$' \
    "$desktop_manifest"; then
    printf 'Elephant core and providers must be declared as one ABI-compatible build.\n' >&2
    exit 1
fi

mkdir -p -- "$FAKE_BIN"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case ${1:-} in' \
    '  -T)' \
    '    case ${3:-} in oh-my-zsh-git|oh-my-posh-bin) exit 127 ;; *) exit 0 ;; esac' \
    '    ;;' \
    '  -Si)' \
    '    case ${3:-} in oh-my-zsh-git|oh-my-posh-bin) exit 1 ;; *) exit 0 ;; esac' \
    '    ;;' \
    '  -S) printf "pacman %s\n" "$*" >> "$PACKAGE_TEST_LOG" ;;' \
    '  *) exit 2 ;;' \
    'esac' > "$FAKE_BIN/pacman"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "sudo %s\n" "$*" >> "$PACKAGE_TEST_LOG"' \
    '[[ ${1:-} == -v || ${1:-} == -n ]] && exit 0' \
    'exec "$@"' > "$FAKE_BIN/sudo"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "paru %s\n" "$*" >> "$PACKAGE_TEST_LOG"' > "$FAKE_BIN/paru"
chmod +x -- "$FAKE_BIN/pacman" "$FAKE_BIN/sudo" "$FAKE_BIN/paru"
for command_name in bash chmod dirname mkdir mktemp rm; do
    ln -s -- "/usr/bin/$command_name" "$FAKE_BIN/$command_name"
done

runner=()
if [[ $EUID -eq 0 ]]; then
    command -v runuser >/dev/null 2>&1 || {
        printf 'runuser is required to exercise the non-root installer.\n' >&2
        exit 1
    }
    chown -R nobody "$TEST_ROOT"
    runner=(/usr/bin/runuser -u nobody --)
fi

if "${runner[@]}" /usr/bin/env \
    PATH="$FAKE_BIN" \
    WAYLAND_DISPLAY=wayland-test DISPLAY=:1 \
    PACKAGE_TEST_BIN="$PACKAGE_TEST_BIN" PACKAGE_TEST_LOG="$PACKAGE_TEST_LOG" \
    "$REPO_ROOT/scripts/install-packages.sh" --profile core --yes </dev/null \
    > "$TEST_ROOT/aur-blocked.log" 2>&1; then
    printf 'AUR packages were accepted without explicit authorization.\n' >&2
    exit 1
fi
rg -q 'Re-run with --allow-aur' "$TEST_ROOT/aur-blocked.log"
[[ ! -s $PACKAGE_TEST_LOG ]]

"${runner[@]}" /usr/bin/env \
    PATH="$FAKE_BIN" \
    WAYLAND_DISPLAY=wayland-test DISPLAY=:1 \
    PACKAGE_TEST_BIN="$PACKAGE_TEST_BIN" PACKAGE_TEST_LOG="$PACKAGE_TEST_LOG" \
    "$REPO_ROOT/scripts/install-packages.sh" --profile core --yes --allow-aur </dev/null

[[ $(rg -c '^sudo -n -v$' "$PACKAGE_TEST_LOG") -eq 1 ]]
rg -q '^paru --sudoloop --useask -S --needed -- oh-my-zsh-git oh-my-posh-bin$' \
    "$PACKAGE_TEST_LOG"
if rg -q -- '--noconfirm' "$PACKAGE_TEST_LOG"; then
    printf 'AUR installation bypassed interactive package review.\n' >&2
    exit 1
fi
if rg -q 'pkexec|(^|[[:space:]])--sudo([[:space:]]|$)' "$PACKAGE_TEST_LOG"; then
    printf 'Unexpected per-transaction authorization command found.\n' >&2
    exit 1
fi

# Exercise manifest validation in a disposable repository, with all package
# and authorization commands mocked. Invalid input must fail before any call.
fixture="$TEST_ROOT/fixture"
mkdir -p -- "$fixture/scripts" "$fixture/packages/arch"
cp -- "$REPO_ROOT/scripts/install-packages.sh" "$REPO_ROOT/scripts/lib.sh" "$fixture/scripts/"
if [[ $EUID -eq 0 ]]; then
    chown -R nobody "$fixture"
fi
for invalid in '--invalid-option' 'name|' '|name' 'name||other' '../name' '.name' 'name;other'; do
    printf '%s\n' "$invalid" > "$fixture/packages/arch/core.txt"
    : > "$PACKAGE_TEST_LOG"
    if "${runner[@]}" /usr/bin/env PATH="$FAKE_BIN" \
        PACKAGE_TEST_LOG="$PACKAGE_TEST_LOG" \
        "$fixture/scripts/install-packages.sh" --profile core --yes \
        > "$TEST_ROOT/invalid.log" 2>&1; then
        printf 'Invalid manifest was accepted.\n' >&2
        exit 1
    fi
    rg -q 'Invalid package specification' "$TEST_ROOT/invalid.log"
    [[ ! -s $PACKAGE_TEST_LOG ]]
done

printf '%s\n' 'valid-name|other.name' 'libc++' '@valid' > "$fixture/packages/arch/core.txt"
"${runner[@]}" /usr/bin/env PATH="$FAKE_BIN" \
    PACKAGE_TEST_LOG="$PACKAGE_TEST_LOG" \
    "$fixture/scripts/install-packages.sh" --profile core --yes >/dev/null
[[ ! -s $PACKAGE_TEST_LOG ]]

printf 'Package bootstrap validates manifests, gates AUR builds, and preserves one sudo session.\n'
