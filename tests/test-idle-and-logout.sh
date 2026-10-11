#!/usr/bin/env bash
# shellcheck disable=SC2016  # Mock scripts deliberately retain their variables.
set -Eeuo pipefail
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-idle-logout.XXXXXXXX")
cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-idle-logout.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/config/myhypr/bin"
export CONTROL_TEST_LOG="$TEST_ROOT/log"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''[{"focused":true,"height":1080,"scale":%s}]\n'\'' "${CONTROL_TEST_SCALE:-1}"' \
    > "$TEST_ROOT/bin/hyprctl"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\\n" "$*" > "$CONTROL_TEST_LOG"' > "$TEST_ROOT/bin/wlogout"
chmod +x "$TEST_ROOT/bin/"*
export PATH="$TEST_ROOT/bin:$PATH" XDG_CONFIG_HOME="$TEST_ROOT/config"
for sample in 1:291 1.25:233 1.5:194 2:145; do
    CONTROL_TEST_SCALE=${sample%:*} "$REPO_ROOT/dotfiles/.config/myhypr/scripts/wlogout.sh"
    [[ $(<"$CONTROL_TEST_LOG") == "-b 5 -T ${sample#*:} -B ${sample#*:}" ]]
done
if CONTROL_TEST_SCALE=0 "$REPO_ROOT/dotfiles/.config/myhypr/scripts/wlogout.sh"; then
    printf 'Invalid monitor scale was accepted.\n' >&2; exit 1
fi
rg -Fq '"on-click-right": "~/.config/myhypr/bin/launch-app ~/.config/hypr/scripts/power.sh lock"' \
    "$REPO_ROOT/dotfiles/.config/waybar/modules.json"
printf 'Logout scaling and shared lock action passed.\n'
