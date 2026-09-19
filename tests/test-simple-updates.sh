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
runtime_root="$TEST_ROOT/runtime"
mkdir -p "$TEST_ROOT/bin" "$runtime_root"
ln -s /usr/bin/bash "$TEST_ROOT/bin/bash"
export UPDATE_TEST_LOG="$TEST_ROOT/log"
export MYHYPR_TEST_PACMAN_DB_LOCK="$TEST_ROOT/pacman-db.lck"
export MYHYPR_TEST_CHECKUPDATES_DB_LOCK="$TEST_ROOT/checkupdates-db.lck"
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
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "signal <%s>\\n" "$*" >> "$UPDATE_TEST_LOG"' \
    > "$TEST_ROOT/bin/pkill"
chmod +x "$TEST_ROOT/bin/"{pacman,pkexec,paru,flatpak,pkill}

UPDATE_ROOT="$TEST_ROOT/update-repo"
UPDATE_SCRIPT="$UPDATE_ROOT/scripts/update-system.sh"
mkdir -p -- "$UPDATE_ROOT/scripts" "$UPDATE_ROOT/dotfiles/.config/myhypr/scripts"
cp -- "$REPO_ROOT/dotfiles/.config/myhypr/scripts/updates.sh" \
    "$UPDATE_ROOT/dotfiles/.config/myhypr/scripts/updates.sh"
sed \
    -e "s|^PACMAN_BIN=.*|PACMAN_BIN=$TEST_ROOT/bin/pacman|" \
    -e "s|^PKEXEC_BIN=.*|PKEXEC_BIN=$TEST_ROOT/bin/pkexec|" \
    -e "s|^PARU_BIN=.*|PARU_BIN=$TEST_ROOT/bin/paru|" \
    -e "s|^YAY_BIN=.*|YAY_BIN=$TEST_ROOT/bin/yay|" \
    "$REPO_ROOT/scripts/update-system.sh" > "$UPDATE_SCRIPT"
chmod +x "$UPDATE_SCRIPT"

PATH="$TEST_ROOT/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$runtime_root" \
    "$UPDATE_SCRIPT"
rg -Fxq "pkexec <$TEST_ROOT/bin/pacman -Syu>" "$UPDATE_TEST_LOG"
if rg -q '^helper ' "$UPDATE_TEST_LOG"; then
    printf 'Routine update unexpectedly executed an AUR helper.\n' >&2; exit 1
fi
rg -Fxq 'flatpak <--user update>' "$UPDATE_TEST_LOG"
rg -Fxq 'flatpak <--system update>' "$UPDATE_TEST_LOG"
rg -Fxq 'signal <-RTMIN+1 waybar>' "$UPDATE_TEST_LOG"
jq -e '.text == "0" and .class == "green"' \
    "$runtime_root/myhypr-update-status.json" >/dev/null || {
    printf 'Successful update produced an invalid Waybar status: ' >&2
    cat -- "$runtime_root/myhypr-update-status.json" >&2
    exit 1
}

: > "$UPDATE_TEST_LOG"
if PATH="$TEST_ROOT/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$runtime_root" \
    UPDATE_TEST_FAIL=42 "$UPDATE_SCRIPT"; then
    printf 'Package-manager failure was hidden.\n' >&2; exit 1
else
    [[ $? -eq 42 ]]
fi
[[ ! -e $runtime_root/myhypr-update-status.json ]] || {
    printf 'Failed update retained a successful status marker.\n' >&2; exit 1;
}
rg -Fxq 'signal <-RTMIN+1 waybar>' "$UPDATE_TEST_LOG"
if rg -q flatpak "$UPDATE_TEST_LOG"; then
    printf 'Flatpak ran after the Arch upgrade failed.\n' >&2; exit 1
fi

: > "$UPDATE_TEST_LOG"
PATH="$TEST_ROOT/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$runtime_root" \
    "$UPDATE_SCRIPT" --allow-aur
rg -Fxq 'helper <--sudo>' "$UPDATE_TEST_LOG" >/dev/null 2>&1 && {
    printf 'AUR helper command lost its absolute pkexec path.\n' >&2; exit 1;
}
rg -Fq "helper <--sudo> <$TEST_ROOT/bin/pkexec> <--sudoflags> <> <--nosudoloop> <-Sua>" \
    "$UPDATE_TEST_LOG"

fixture_root="$TEST_ROOT/repo"
mkdir -p "$fixture_root/dotfiles/.config/myhypr/scripts" \
    "$fixture_root/scripts" "$runtime_root"
cp -- "$REPO_ROOT/dotfiles/.config/myhypr/scripts/installupdates.sh" \
    "$fixture_root/dotfiles/.config/myhypr/scripts/installupdates.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit "${UPDATE_TEST_FAIL:-0}"' \
    > "$fixture_root/scripts/update-system.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TEST_ROOT/bin/gum"
chmod +x "$fixture_root/dotfiles/.config/myhypr/scripts/installupdates.sh" \
    "$fixture_root/scripts/update-system.sh" "$TEST_ROOT/bin/gum" "$TEST_ROOT/bin/pkill"

PATH="$TEST_ROOT/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$runtime_root" \
    "$fixture_root/dotfiles/.config/myhypr/scripts/installupdates.sh" >/dev/null

UPDATE_TEST_FAIL=1 PATH="$TEST_ROOT/bin:/usr/bin:/bin" XDG_RUNTIME_DIR="$runtime_root" \
    "$fixture_root/dotfiles/.config/myhypr/scripts/installupdates.sh" >/dev/null 2>&1 &&
    { printf 'Failed update unexpectedly returned success.\n' >&2; exit 1; }

printf 'Simple updates use full upgrades, graphical auth, and honest failures.\n'
