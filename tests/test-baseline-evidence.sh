#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes intentionally write literal fixture variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-baseline-test.XXXXXXXX")
FIXTURE_REPO="$TEST_ROOT/repo"
TEST_HOME="$TEST_ROOT/home"
STATE_ROOT="$TEST_ROOT/state"
FAKE_BIN="$TEST_ROOT/bin"
export BASELINE_TEST_LOG="$TEST_ROOT/commands.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-baseline-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Baseline evidence test failed: %s\n' "$*" >&2
    exit 1
}

[[ -x $REPO_ROOT/scripts/capture-baseline.sh ]] || \
    fail 'scripts/capture-baseline.sh is missing or not executable'

mkdir -p -- \
    "$FIXTURE_REPO/scripts" \
    "$FIXTURE_REPO/tests" \
    "$FIXTURE_REPO/dotfiles/.config/hypr/conf/keybindings" \
    "$FIXTURE_REPO/dotfiles/.config/waybar" \
    "$TEST_HOME/.config/hypr/conf" \
    "$TEST_HOME/.config/myhypr/colors" \
    "$TEST_HOME/.config/myhypr/settings" \
    "$STATE_ROOT" \
    "$FAKE_BIN"
cp -- "$REPO_ROOT/scripts/capture-baseline.sh" "$FIXTURE_REPO/scripts/"
cp -- "$REPO_ROOT/scripts/lib.sh" "$FIXTURE_REPO/scripts/"

write_fixture_command() {
    local path=$1 label=$2
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        "printf '%s <%s>\\n' '$label' \"\$*\" >> \"\$BASELINE_TEST_LOG\"" \
        'printf "%s completed\n" "${0##*/}"' \
        > "$path"
    chmod +x -- "$path"
}

write_fixture_command "$FIXTURE_REPO/scripts/audit.sh" audit
write_fixture_command "$FIXTURE_REPO/scripts/doctor.sh" doctor
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'printf "check <%s>\n" "$*" >> "$BASELINE_TEST_LOG"' \
    'if [[ ${BASELINE_FAIL_CHECK:-} == quick && ${1:-} == --quick ]]; then' \
    '    printf "synthetic quick failure\n" >&2' \
    '    exit 42' \
    'fi' \
    'printf "validation completed\n"' \
    > "$FIXTURE_REPO/scripts/check.sh"
chmod +x -- "$FIXTURE_REPO/scripts/check.sh"

printf 'fixture keybindings\n' \
    > "$FIXTURE_REPO/tests/test-keybindings.lua"
printf 'fixture actions\n' \
    > "$FIXTURE_REPO/tests/test-waybar-actions.sh"
printf 'fixture default bindings\n' \
    > "$FIXTURE_REPO/dotfiles/.config/hypr/conf/keybindings/default.lua"
printf 'fixture waybar actions\n' \
    > "$FIXTURE_REPO/dotfiles/.config/waybar/modules.json"

for selector in animation decoration environment layout monitor \
    window windowrule workspace; do
    printf 'source = ~/.config/hypr/conf/%ss/fixture-choice.conf\n' "$selector" \
        > "$TEST_HOME/.config/hypr/conf/$selector.conf"
done
printf 'fr\n' > "$TEST_HOME/.config/myhypr/settings/keybinding-profile"
printf '#112233\n' > "$TEST_HOME/.config/myhypr/colors/primary"
printf '#445566\n' > "$TEST_HOME/.config/myhypr/colors/secondary"
printf '#ddeeff\n' > "$TEST_HOME/.config/myhypr/colors/onsurface"
printf 'awww\n' > "$TEST_HOME/.config/myhypr/settings/wallpaper-engine.sh"
printf 'none\n' > "$TEST_HOME/.config/myhypr/settings/wallpaper-effect.sh"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'printf "hyprctl <%s>\n" "$*" >> "$BASELINE_TEST_LOG"' \
    'case ${1:-} in' \
    '    configerrors)' \
    '        [[ ${BASELINE_HYPR_UNAVAILABLE:-0} == 0 ]] || exit 2' \
    '        [[ ${BASELINE_HYPR_ERRORS:-0} == 0 ]] || printf "synthetic config error\n"' \
    '        exit 0' \
    '        ;;' \
    '    *) printf "healthy\n" ;;' \
    'esac' > "$FAKE_BIN/hyprctl"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'printf "systemctl <%s>\n" "$*" >> "$BASELINE_TEST_LOG"' \
    'printf "active\n"' > "$FAKE_BIN/systemctl"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'printf "ps <%s>\n" "$*" >> "$BASELINE_TEST_LOG"' \
    'printf "waybar 0.1 0.2 1024\n"' > "$FAKE_BIN/ps"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'printf "systemd-analyze <%s>\n" "$*" >> "$BASELINE_TEST_LOG"' \
    '[[ ${BASELINE_STARTUP_UNAVAILABLE:-0} == 0 ]] || exit 125' \
    'printf "Startup finished in 1.000s\n"' > "$FAKE_BIN/systemd-analyze"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'printf "grim <%s>\n" "$*" >> "$BASELINE_TEST_LOG"' \
    'printf "fixture image\n" > "${!#}"' > "$FAKE_BIN/grim"
chmod +x -- "$FAKE_BIN/hyprctl" "$FAKE_BIN/systemctl" "$FAKE_BIN/ps" \
    "$FAKE_BIN/systemd-analyze" "$FAKE_BIN/grim"

git -C "$FIXTURE_REPO" init -q
git -C "$FIXTURE_REPO" config user.name 'Baseline Fixture'
git -C "$FIXTURE_REPO" config user.email 'fixture@example.invalid'
git -C "$FIXTURE_REPO" add -A
git -C "$FIXTURE_REPO" commit -qm 'fixture baseline'
fixture_commit=$(git -C "$FIXTURE_REPO" rev-parse HEAD)

run_recorder() {
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="$TEST_HOME/.config" \
    XDG_STATE_HOME="$STATE_ROOT" \
    HYPRLAND_INSTANCE_SIGNATURE=fixture-instance \
    WAYLAND_DISPLAY=wayland-fixture \
    BASELINE_PRIVATE_SENTINEL='do-not-record-this-value' \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
        "$FIXTURE_REPO/scripts/capture-baseline.sh" "$@"
}

evidence="$STATE_ROOT/evidence"
printed_path=$(run_recorder --output "$evidence")
[[ $printed_path == "$evidence" ]] || fail 'the recorder did not print its exact output path'
[[ $(stat -c %a "$evidence") == 700 ]] || fail 'evidence directory is not private'
while IFS= read -r mode; do
    [[ $mode == 600 ]] || fail "evidence file has mode $mode instead of 600"
done < <(find "$evidence" -type f -printf '%m\n')
[[ ! -e $evidence/desktop.png ]] || fail 'a screenshot was captured without consent'

jq -e --arg commit "$fixture_commit" '
    .version == 1 and
    .commit == $commit and
    .worktree_clean == true and
    .screenshot == "not-requested" and
    .visual.primary == "#112233" and
    .visual.secondary == "#445566" and
    .visual.on_surface == "#ddeeff" and
    .visual.wallpaper_engine == "awww" and
    .visual.wallpaper_effect == "none" and
    .visual.waybar == "enabled" and
    .visual.dock == "enabled" and
    (.selectors | length) == 9 and
    (.inventories.bindings.sha256 | test("^[0-9a-f]{64}$")) and
    (.inventories.desktop_actions.sha256 | test("^[0-9a-f]{64}$")) and
    ([.checks[].name] | index("validation-full") != null) and
    ([.checks[].name] | index("validation-quick") != null) and
    ([.checks[].name] | index("history-audit") != null) and
    ([.checks[].name] | index("doctor-quick") != null) and
    ([.checks[].name] | index("hyprland-configerrors") != null) and
    ([.checks[].name] | index("desktop-services") != null) and
    ([.checks[].name] | index("desktop-resources") != null) and
    ([.checks[].name] | index("startup-summary") != null) and
    ([.checks[] | select(.status != 0)] | length) == 0
' "$evidence/manifest.json" >/dev/null || fail 'manifest omitted required bounded evidence'

rg -Fq 'check <>' "$BASELINE_TEST_LOG" || fail 'full validation did not run'
rg -Fq 'check <--quick>' "$BASELINE_TEST_LOG" || fail 'quick validation did not run'
rg -Fq 'audit <--history>' "$BASELINE_TEST_LOG" || fail 'history audit did not run'
rg -Fq 'doctor <--profile desktop --quick>' "$BASELINE_TEST_LOG" || \
    fail 'desktop doctor did not run'
if rg -q '(^|[[:space:]<])(aux|-ef|ww)([[:space:]>]|$)' "$BASELINE_TEST_LOG"; then
    fail 'process capture requested unbounded process data'
fi
if rg -Fq 'do-not-record-this-value' "$evidence"; then
    fail 'environment/private data leaked into evidence'
fi

screenshot_evidence="$STATE_ROOT/screenshot-evidence"
run_recorder --output "$screenshot_evidence" --screenshot >/dev/null
[[ -s $screenshot_evidence/desktop.png ]] || fail 'requested screenshot was not captured'
[[ $(stat -c %a "$screenshot_evidence/desktop.png") == 600 ]] || \
    fail 'screenshot mode is not private'
jq -e '.screenshot == "captured"' "$screenshot_evidence/manifest.json" >/dev/null || \
    fail 'screenshot status was not recorded'

failure_evidence="$STATE_ROOT/failure-evidence"
set +e
BASELINE_FAIL_CHECK=quick run_recorder --output "$failure_evidence" >/dev/null
failure_status=$?
set -e
[[ $failure_status -ne 0 ]] || fail 'a failed evidence command reported success'
jq -e '[.checks[] | select(.name == "validation-quick" and .status == 42)] | length == 1' \
    "$failure_evidence/manifest.json" >/dev/null || fail 'command failure status was not preserved'

config_error_evidence="$STATE_ROOT/config-error-evidence"
set +e
BASELINE_HYPR_ERRORS=1 run_recorder --output "$config_error_evidence" >/dev/null
config_error_status=$?
set -e
[[ $config_error_status -ne 0 ]] || fail 'reported Hyprland config errors were treated as healthy'
jq -e '[.checks[] | select(.name == "hyprland-configerrors" and .status != 0)] | length == 1' \
    "$config_error_evidence/manifest.json" >/dev/null || \
    fail 'Hyprland config-error health was not represented in the manifest'

optional_evidence="$STATE_ROOT/optional-evidence"
BASELINE_STARTUP_UNAVAILABLE=1 run_recorder --output "$optional_evidence" >/dev/null || \
    fail 'an unavailable optional measurement prevented evidence capture'
jq -e '[.checks[] | select(
    .name == "startup-summary" and .required == false and .status == 125
)] | length == 1' "$optional_evidence/manifest.json" >/dev/null || \
    fail 'the optional measurement status was not retained truthfully'

hypr_unavailable_evidence="$STATE_ROOT/hypr-unavailable-evidence"
BASELINE_HYPR_UNAVAILABLE=1 run_recorder \
    --output "$hypr_unavailable_evidence" >/dev/null || \
    fail 'an unavailable Hyprland transport was treated as a config error'
jq -e '[.checks[] | select(
    .name == "hyprland-configerrors" and .required == false and
    .status == 125 and .class == "unavailable"
)] | length == 1' "$hypr_unavailable_evidence/manifest.json" >/dev/null || \
    fail 'Hyprland transport failure was not classified as unavailable'

mkdir -p -- "$STATE_ROOT/outside"
ln -s -- "$STATE_ROOT/outside" "$STATE_ROOT/symlink-evidence"
if run_recorder --output "$STATE_ROOT/symlink-evidence" >/dev/null 2>&1; then
    fail 'a symlink output directory was accepted'
fi
if run_recorder --output "$evidence" >/dev/null 2>&1; then
    fail 'an existing evidence directory was overwritten'
fi

printf 'Private baseline evidence is bounded and non-destructive.\n'
