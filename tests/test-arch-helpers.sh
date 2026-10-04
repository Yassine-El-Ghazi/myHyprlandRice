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
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ ${1:-} == -Qmq ]]; then printf "%s" "${FOREIGN_TEST_PACKAGES:-}"; exit 0; fi' \
    'if [[ ${1:-} == -Qu ]]; then' \
    '  case ${LOCAL_REPO_TEST_MODE:-none} in' \
    '    updates) printf "%s\n" local-one local-two; exit 0 ;;' \
    '    none) exit 1 ;;' \
    '    failure) printf "local database failed\n" >&2; exit 3 ;;' \
    '  esac' \
    'fi' \
    'exit 0' > "$TEST_ROOT/bin/pacman"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    '[[ ${CHECKUPDATES_DB:-} == */myhypr-update-check.*/db ]] || exit 3' \
    'case ${UPDATE_COUNT_TEST_MODE:-none} in' \
    '  updates) printf "%s\n" package-one package-two; exit 0 ;;' \
    '  none) exit 2 ;;' \
    '  failure) exit 1 ;;' \
    '  timeout) sleep 2; exit 0 ;;' \
    'esac' > "$TEST_ROOT/bin/checkupdates"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case ${AUR_TEST_MODE:-none} in' \
    '  updates) printf "%s\n" aur-one; exit 0 ;;' \
    '  none) exit 1 ;;' \
    '  failure) printf "AUR failed\n" >&2; exit 1 ;;' \
    'esac' > "$TEST_ROOT/bin/paru"
chmod +x -- "$TEST_ROOT/bin/pacman" "$TEST_ROOT/bin/checkupdates" \
    "$TEST_ROOT/bin/paru"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    '[[ $2 == remote-ls && $3 == --updates && $4 == --columns=ref ]] || exit 4' \
    'case ${FLATPAK_TEST_MODE:-none} in' \
    ' updates) printf "%s\n" app/one/x86_64/stable app/one/x86_64/stable ;;' \
    ' failure) exit 1 ;;' \
    ' warning) printf "Remote unavailable\n" >&2 ;;' \
    'esac' > "$TEST_ROOT/bin/flatpak"
chmod +x -- "$TEST_ROOT/bin/flatpak"
export MYHYPR_TEST_PACMAN_DB_LOCK="$TEST_ROOT/pacman-db.lck"
export MYHYPR_TEST_CHECKUPDATES_DB_LOCK="$TEST_ROOT/checkupdates-db.lck"

mkdir -p "$TEST_ROOT/runtime"
export XDG_RUNTIME_DIR="$TEST_ROOT/runtime"
: > "$TEST_ROOT/runtime/myhypr-update-status.json"
printf '%s\n' '{"text":"3","alt":"3","tooltip":"Verified after update","class":"yellow"}' \
    > "$TEST_ROOT/runtime/myhypr-update-status.json"
update_json=$(PATH="$TEST_ROOT/bin:/usr/bin:/bin" UPDATE_COUNT_TEST_MODE=failure \
    "$UPDATES_SCRIPT")
jq -e '.text == "?" and (.tooltip | contains("Incomplete/cached"))' \
    <<< "$update_json" >/dev/null || fail 'stale marker overrode a fresh check'

: > "$MYHYPR_TEST_PACMAN_DB_LOCK"
update_json=$(PATH="$TEST_ROOT/bin:/usr/bin:/bin" UPDATE_COUNT_TEST_MODE=updates \
    "$UPDATES_SCRIPT")
jq -e '.text == "…" and .tooltip == "Package database is busy"' \
    <<< "$update_json" >/dev/null || fail 'active package database was not reported as busy'
rm -- "$MYHYPR_TEST_PACMAN_DB_LOCK"

update_json=$(PATH="$TEST_ROOT/bin:/usr/bin:/bin" UPDATE_COUNT_TEST_MODE=updates \
    "$UPDATES_SCRIPT")
jq -e '.text == "2" and (.tooltip | contains("Repository: 2")) and (.tooltip | contains("Checked:"))' \
    <<< "$update_json" >/dev/null || fail 'available updates were not counted'
jq -e '.class == "yellow"' <<< "$update_json" >/dev/null || \
    fail 'available updates did not use the warning color'
update_json=$(PATH="$TEST_ROOT/bin:/usr/bin:/bin" UPDATE_COUNT_TEST_MODE=none \
    "$UPDATES_SCRIPT")
jq -e '.text == "0" and .class == "green" and (.tooltip | contains("Available updates at last check"))' \
    <<< "$update_json" >/dev/null || fail 'documented no-update status was rejected'
update_json=$(PATH="$TEST_ROOT/bin:/usr/bin:/bin" UPDATE_COUNT_TEST_MODE=failure \
    "$UPDATES_SCRIPT")
jq -e '.text == "?" and .class == "yellow" and (.tooltip | contains("local package data"))' \
    <<< "$update_json" >/dev/null || fail 'local fallback did not replace a failed refresh'
update_json=$(PATH="$TEST_ROOT/bin:/usr/bin:/bin" UPDATE_COUNT_TEST_MODE=timeout \
    MYHYPR_UPDATE_CHECK_TIMEOUT_SECONDS=0.1 "$UPDATES_SCRIPT")
jq -e '.text == "?" and .class == "yellow" and (.tooltip | contains("timed out"))' \
    <<< "$update_json" >/dev/null || fail 'stalled refresh did not use local data'

update_json=$(PATH="$TEST_ROOT/bin:/usr/bin:/bin" UPDATE_COUNT_TEST_MODE=failure \
    LOCAL_REPO_TEST_MODE=failure AUR_TEST_MODE=failure "$UPDATES_SCRIPT")
jq -e '.text == "?" and .class == "yellow"' <<< "$update_json" >/dev/null || \
    fail 'complete update-check failure was not reported'

update_json=$(PATH="$TEST_ROOT/bin:/usr/bin:/bin" LOCAL_REPO_TEST_MODE=updates \
    AUR_TEST_MODE=updates "$UPDATES_SCRIPT" --local)
jq -e '.text == "3+" and .class == "yellow"' <<< "$update_json" >/dev/null || \
    fail 'post-update local verification did not count repository and AUR updates'

update_json=$(PATH="$TEST_ROOT/bin:/usr/bin:/bin" LOCAL_REPO_TEST_MODE=failure \
    AUR_TEST_MODE=updates "$UPDATES_SCRIPT" --local)
jq -e '.text == "1+" and (.tooltip | contains("Repository update status unavailable"))' \
    <<< "$update_json" >/dev/null || fail 'partial local verification claimed full success'

update_json=$(PATH="$TEST_ROOT/bin:/usr/bin:/bin" "$UPDATES_SCRIPT" --local)
jq -e '.text == "?" and .class == "yellow"' \
    <<< "$update_json" >/dev/null || fail 'cached no-update result claimed current success'

update_json=$(PATH="$TEST_ROOT/bin:/usr/bin:/bin" UPDATE_COUNT_TEST_MODE=updates \
    AUR_TEST_MODE=updates FLATPAK_TEST_MODE=updates "$UPDATES_SCRIPT")
jq -e '.text == "5" and (.tooltip | contains("AUR: 1")) and (.tooltip | contains("Flatpak user: 1")) and (.tooltip | contains("Flatpak system: 1"))' \
    <<< "$update_json" >/dev/null || fail 'source counts or Flatpak deduplication failed'
for flatpak_mode in failure warning; do
    update_json=$(PATH="$TEST_ROOT/bin:/usr/bin:/bin" FLATPAK_TEST_MODE="$flatpak_mode" "$UPDATES_SCRIPT")
    jq -e '.text == "?" and .class != "green"' <<< "$update_json" >/dev/null || \
        fail 'failed or partial Flatpak query claimed zero'
done
update_json=$(PATH="$TEST_ROOT/bin:/usr/bin:/bin" MYHYPR_UPDATE_AUR_HELPER=none \
    FOREIGN_TEST_PACKAGES=foreign-package "$UPDATES_SCRIPT")
jq -e '.text == "?" and (.tooltip | contains("Foreign packages not checked"))' \
    <<< "$update_json" >/dev/null || fail 'disabled AUR helper hid foreign packages'
update_json=$(PATH="$TEST_ROOT/bin:/usr/bin:/bin" UPDATE_COUNT_TEST_MODE=updates \
    AUR_TEST_MODE=failure "$UPDATES_SCRIPT")
jq -e '.text == "2+" and .class == "yellow"' <<< "$update_json" >/dev/null || \
    fail 'failed AUR query did not mark positive counts as partial'

"$ARCH_ROOT/installprinters.sh" --help >/dev/null
"$ARCH_ROOT/installtimeshift.sh" --help >/dev/null
"$ARCH_ROOT/snapshot.sh" --help >/dev/null
printf 'Arch maintenance helpers are guarded and deterministic.\n'
