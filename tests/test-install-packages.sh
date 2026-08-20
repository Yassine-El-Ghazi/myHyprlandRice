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
    "$REPO_ROOT/scripts/install-packages.sh" --profile core --yes

rg -q '^git clone --depth 1 https://aur\.archlinux\.org/paru-bin\.git ' \
    "$PACKAGE_TEST_LOG"
rg -q '^makepkg -si --needed --noconfirm$' "$PACKAGE_TEST_LOG"
[[ $(rg -c '^sudo -n -v$' "$PACKAGE_TEST_LOG") -eq 1 ]]
rg -q '^paru --sudoloop -S --needed --noconfirm oh-my-zsh-git oh-my-posh-bin$' \
    "$PACKAGE_TEST_LOG"
if rg -q 'pkexec|(^|[[:space:]])--sudo([[:space:]]|$)' "$PACKAGE_TEST_LOG"; then
    printf 'Unexpected per-transaction authorization command found.\n' >&2
    exit 1
fi

printf 'AUR helper bootstrap uses one sudo session without corrupting the command.\n'
