#!/usr/bin/env bash
# shellcheck disable=SC2016  # Mock scripts intentionally contain literal variables.
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

UPDATES_SCRIPT="$REPO_ROOT/dotfiles/.config/myhypr/scripts/updates.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-update-count-test.XXXXXXXX")
cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-update-count-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT
mkdir -p -- "$TEST_ROOT/bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TEST_ROOT/bin/pacman"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case ${UPDATE_COUNT_TEST_MODE:-none} in' \
    '  updates) printf "%s\n" package-one package-two; exit 0 ;;' \
    '  none) exit 2 ;;' \
    '  failure) exit 1 ;;' \
    'esac' > "$TEST_ROOT/bin/checkupdates"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TEST_ROOT/bin/paru"
chmod +x -- "$TEST_ROOT/bin/pacman" "$TEST_ROOT/bin/checkupdates" \
    "$TEST_ROOT/bin/paru"

update_json=$(PATH="$TEST_ROOT/bin:/usr/bin:/bin" UPDATE_COUNT_TEST_MODE=updates \
    "$UPDATES_SCRIPT")
jq -e '.text == "2" and .tooltip == "Click to update the system"' \
    <<< "$update_json" >/dev/null || fail 'available updates were not counted'
update_json=$(PATH="$TEST_ROOT/bin:/usr/bin:/bin" UPDATE_COUNT_TEST_MODE=none \
    "$UPDATES_SCRIPT")
jq -e '.text == "0" and .tooltip == "System is up to date"' \
    <<< "$update_json" >/dev/null || fail 'documented no-update status was rejected'
update_json=$(PATH="$TEST_ROOT/bin:/usr/bin:/bin" UPDATE_COUNT_TEST_MODE=failure \
    "$UPDATES_SCRIPT")
jq -e '.text == "!" and .tooltip == "Update check failed; click to run the updater"' \
    <<< "$update_json" >/dev/null || fail 'failed update check was reported as current'

"$ARCH_ROOT/installprinters.sh" --help >/dev/null
"$ARCH_ROOT/installtimeshift.sh" --help >/dev/null
"$ARCH_ROOT/snapshot.sh" --help >/dev/null
printf 'Arch maintenance helpers are guarded and deterministic.\n'
