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
    'destination=${!#}' \
    'mkdir -p -- "$destination"' \
    'printf "git %s\n" "$*" >> "$PACKAGE_TEST_LOG"' > "$FAKE_BIN/git"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "makepkg %s\n" "$*" >> "$PACKAGE_TEST_LOG"' \
    'printf "%s\n" "#!/usr/bin/env bash" "printf \"paru %s\\n\" \"\$*\" >> \"\$PACKAGE_TEST_LOG\"" > "$PACKAGE_TEST_BIN/paru"' \
    'chmod +x -- "$PACKAGE_TEST_BIN/paru"' > "$FAKE_BIN/makepkg"
chmod +x -- "$FAKE_BIN/pacman" "$FAKE_BIN/sudo" "$FAKE_BIN/git" \
    "$FAKE_BIN/makepkg"
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

"${runner[@]}" /usr/bin/env \
    PATH="$FAKE_BIN" \
    WAYLAND_DISPLAY=wayland-test DISPLAY=:1 \
    PACKAGE_TEST_BIN="$PACKAGE_TEST_BIN" PACKAGE_TEST_LOG="$PACKAGE_TEST_LOG" \
    "$REPO_ROOT/scripts/install-packages.sh" --profile core --yes </dev/null

rg -q '^git clone --depth 1 https://aur\.archlinux\.org/paru-bin\.git ' \
    "$PACKAGE_TEST_LOG"
rg -q '^makepkg -si --needed --noconfirm$' "$PACKAGE_TEST_LOG"
[[ $(rg -c '^sudo -n -v$' "$PACKAGE_TEST_LOG") -eq 1 ]]
rg -q '^paru --sudoloop --useask -S --needed --noconfirm oh-my-zsh-git oh-my-posh-bin$' \
    "$PACKAGE_TEST_LOG"
if rg -q 'pkexec|(^|[[:space:]])--sudo([[:space:]]|$)' "$PACKAGE_TEST_LOG"; then
    printf 'Unexpected per-transaction authorization command found.\n' >&2
    exit 1
fi

printf 'Package bootstrap preserves one sudo session and ABI-compatible plugins.\n'
