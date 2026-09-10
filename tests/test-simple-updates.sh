#!/usr/bin/env bash
# shellcheck disable=SC2016  # Variables belong to the mock commands.
set -Eeuo pipefail
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-simple-updates.XXXXXXXX")
cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-simple-updates.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT
mkdir -p "$TEST_ROOT/bin"
ln -s /usr/bin/bash "$TEST_ROOT/bin/bash"
export UPDATE_TEST_LOG="$TEST_ROOT/log"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TEST_ROOT/bin/pacman"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "pkexec <%s>\\n" "$*" >> "$UPDATE_TEST_LOG"' \
    'exit "${UPDATE_TEST_FAIL:-0}"' > "$TEST_ROOT/bin/pkexec"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "helper" >> "$UPDATE_TEST_LOG"' \
    'printf " <%s>" "$@" >> "$UPDATE_TEST_LOG"' \
    'printf "\\n" >> "$UPDATE_TEST_LOG"' \
    'exit "${UPDATE_TEST_FAIL:-0}"' > "$TEST_ROOT/bin/paru"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "flatpak <%s>\\n" "$*" >> "$UPDATE_TEST_LOG"' \
    'if [[ $2 == remotes ]]; then printf "flathub\\n"; fi' \
    > "$TEST_ROOT/bin/flatpak"
chmod +x "$TEST_ROOT/bin/"{pacman,pkexec,paru,flatpak}

PATH="$TEST_ROOT/bin" "$REPO_ROOT/scripts/update-system.sh"
rg -Fxq 'helper <--sudo> <pkexec> <--sudoflags> <> <--nosudoloop> <-Syu>' "$UPDATE_TEST_LOG"
rg -Fxq 'flatpak <--user update>' "$UPDATE_TEST_LOG"
rg -Fxq 'flatpak <--system update>' "$UPDATE_TEST_LOG"

: > "$UPDATE_TEST_LOG"
if PATH="$TEST_ROOT/bin" UPDATE_TEST_FAIL=42 "$REPO_ROOT/scripts/update-system.sh"; then
    printf 'Package-manager failure was hidden.\n' >&2; exit 1
else
    [[ $? -eq 42 ]]
fi
if rg -q flatpak "$UPDATE_TEST_LOG"; then
    printf 'Flatpak ran after the Arch upgrade failed.\n' >&2; exit 1
fi

mv "$TEST_ROOT/bin/paru" "$TEST_ROOT/bin/yay"
PATH="$TEST_ROOT/bin" "$REPO_ROOT/scripts/update-system.sh"
rm -- "$TEST_ROOT/bin/yay"
PATH="$TEST_ROOT/bin" "$REPO_ROOT/scripts/update-system.sh"
rg -Fxq 'pkexec <pacman -Syu>' "$UPDATE_TEST_LOG"

fixture_root="$TEST_ROOT/repo"
runtime_root="$TEST_ROOT/runtime"
mkdir -p "$fixture_root/dotfiles/.config/myhypr/scripts" \
    "$fixture_root/scripts" "$runtime_root"
cp -- "$REPO_ROOT/dotfiles/.config/myhypr/scripts/installupdates.sh" \
    "$fixture_root/dotfiles/.config/myhypr/scripts/installupdates.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit "${UPDATE_TEST_FAIL:-0}"' \
    > "$fixture_root/scripts/update-system.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TEST_ROOT/bin/gum"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "signal <%s>\\n" "$*" >> "$UPDATE_TEST_LOG"' \
    > "$TEST_ROOT/bin/pkill"
chmod +x "$fixture_root/dotfiles/.config/myhypr/scripts/installupdates.sh" \
    "$fixture_root/scripts/update-system.sh" "$TEST_ROOT/bin/gum" "$TEST_ROOT/bin/pkill"

PATH="$TEST_ROOT/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$runtime_root" \
    "$fixture_root/dotfiles/.config/myhypr/scripts/installupdates.sh" >/dev/null
[[ -f $runtime_root/myhypr-update-complete ]]
rg -Fxq 'signal <-RTMIN+1 waybar>' "$UPDATE_TEST_LOG"

UPDATE_TEST_FAIL=1 PATH="$TEST_ROOT/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$runtime_root" \
    "$fixture_root/dotfiles/.config/myhypr/scripts/installupdates.sh" >/dev/null 2>&1 &&
    fail 'failed update unexpectedly returned success'
[[ ! -e $runtime_root/myhypr-update-complete ]] ||
    fail 'failed update retained a stale successful-update marker'

printf 'Simple updates use full upgrades, graphical auth, and honest failures.\n'
