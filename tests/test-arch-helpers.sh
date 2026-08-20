#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ARCH_ROOT="$REPO_ROOT/dotfiles/.config/myhypr/scripts/arch"

fail() {
    printf 'Arch helper test failed: %s\n' "$*" >&2
    exit 1
}

for helper in \
    cleanup.sh installprinters.sh installtimeshift.sh lid-improvements.sh \
    pacman.sh snapshot.sh unlock-pacman.sh; do
    [[ -x $ARCH_ROOT/$helper ]] || fail "$helper is not executable"
    rg -q 'source "\$SCRIPT_DIR/lib\.sh"' "$ARCH_ROOT/$helper" || \
        fail "$helper does not use the guarded helper library"
done
[[ ! -x $ARCH_ROOT/lib.sh ]] || fail 'the sourced helper library must not be executable'

if rg -n '\$aur_helper|_isInstalled(AUR|Yay)|settings/aur' "$ARCH_ROOT"; then
    fail 'a maintenance script still executes an unchecked AUR-helper setting'
fi
if rg -n 'footmatic|doomatic' "$ARCH_ROOT/installprinters.sh"; then
    fail 'the printer package list contains a misspelled package'
fi
for package in cups foomatic-db-engine ipp-usb system-config-printer; do
    rg -q "^[[:space:]]+$package$" "$ARCH_ROOT/installprinters.sh" || \
        fail "printer stack is missing $package"
done

rg -q 'pgrep -x' "$ARCH_ROOT/unlock-pacman.sh" || \
    fail 'pacman unlock does not check active package processes'
rg -q 'fuser "\$lock_file"' "$ARCH_ROOT/unlock-pacman.sh" || \
    fail 'pacman unlock does not check the lock owner'

"$ARCH_ROOT/installprinters.sh" --help >/dev/null
"$ARCH_ROOT/installtimeshift.sh" --help >/dev/null
"$ARCH_ROOT/snapshot.sh" --help >/dev/null
printf 'Arch maintenance helpers are guarded and deterministic.\n'
