#!/usr/bin/env bash
# shellcheck disable=SC2016  # Mock scripts deliberately retain their variables.
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-flatpak-repair.XXXXXXXX")
cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-flatpak-repair.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT
mkdir -p "$TEST_ROOT/repo/scripts" "$TEST_ROOT/bin"
cp -- "$REPO_ROOT/scripts/repair-flatpak.sh" "$REPO_ROOT/scripts/lib.sh" \
    "$TEST_ROOT/repo/scripts/"

export FLATPAK_REPAIR_TEST_LOG="$TEST_ROOT/commands.log"
rg -q '^gtk-theme-name=Breeze$' "$REPO_ROOT/dotfiles/.config/gtk-3.0/settings.ini"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "$*" in' \
    '  "--user remotes --columns=name"|"--system remotes --columns=name") printf "flathub\\n" ;;' \
    '  "--user info org.gtk.Gtk3theme.Breeze-Dark") exit 1 ;;' \
    '  "--system info org.gtk.Gtk3theme.Breeze-Dark") exit 0 ;;' \
    '  "--system info org.gtk.Gtk3theme.Breeze") exit "${FLATPAK_REPAIR_REPLACEMENT_MISSING:-0}" ;;' \
    '  *) printf "unexpected flatpak call: %s\\n" "$*" >&2; exit 2 ;;' \
    'esac' > "$TEST_ROOT/bin/flatpak"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\\n" "$*" >> "$FLATPAK_REPAIR_TEST_LOG"' \
    > "$TEST_ROOT/bin/pkexec"
chmod +x "$TEST_ROOT/bin/flatpak" "$TEST_ROOT/bin/pkexec"

PATH="$TEST_ROOT/bin:/usr/bin:/bin" "$TEST_ROOT/repo/scripts/repair-flatpak.sh" --yes
rg -Fxq 'flatpak --system uninstall --runtime -y org.gtk.Gtk3theme.Breeze-Dark' \
    "$FLATPAK_REPAIR_TEST_LOG"

: > "$FLATPAK_REPAIR_TEST_LOG"
output=$(PATH="$TEST_ROOT/bin:/usr/bin:/bin" FLATPAK_REPAIR_REPLACEMENT_MISSING=1 \
    "$TEST_ROOT/repo/scripts/repair-flatpak.sh" --yes 2>&1)
[[ ! -s $FLATPAK_REPAIR_TEST_LOG ]]
[[ $output == *'replacement is unavailable'* ]]

printf 'Flatpak repair retires Breeze-Dark only when Breeze is available.\n'
