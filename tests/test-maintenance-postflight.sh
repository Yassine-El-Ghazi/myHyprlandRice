#!/usr/bin/env bash
# shellcheck disable=SC2016  # Fixture scripts intentionally contain literal variables.
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-postflight-test.XXXXXXXX")
FAKE_REPO="$TEST_ROOT/repository"
FAKE_BIN="$TEST_ROOT/bin"
COMMAND_LOG="$TEST_ROOT/commands.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-postflight-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Maintenance postflight test failed: %s\n' "$*" >&2
    exit 1
}

# shellcheck source=scripts/lib.sh
source "$PROJECT_ROOT/scripts/lib.sh"
# shellcheck source=scripts/lib/maintenance-transaction.sh
source "$PROJECT_ROOT/scripts/lib/maintenance-transaction.sh"
# shellcheck source=scripts/lib/maintenance-postflight.sh
source "$PROJECT_ROOT/scripts/lib/maintenance-postflight.sh"

mkdir -p -- "$FAKE_REPO/scripts" "$FAKE_BIN"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'printf "check.sh" >> "$POSTFLIGHT_COMMAND_LOG"' \
    'printf " <%s>" "$@" >> "$POSTFLIGHT_COMMAND_LOG"' \
    'printf "\n" >> "$POSTFLIGHT_COMMAND_LOG"' \
    'printf "repository-output fixture-worktree-name\n"' \
    '[[ $POSTFLIGHT_SCENARIO != repository-fail ]]' \
    > "$FAKE_REPO/scripts/check.sh"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'printf "doctor.sh" >> "$POSTFLIGHT_COMMAND_LOG"' \
    'printf " <%s>" "$@" >> "$POSTFLIGHT_COMMAND_LOG"' \
    'printf "\n" >> "$POSTFLIGHT_COMMAND_LOG"' \
    'printf "doctor-output fixture-device-name\n"' \
    '[[ $POSTFLIGHT_SCENARIO != doctor-fail ]]' \
    > "$FAKE_REPO/scripts/doctor.sh"
chmod 0755 -- "$FAKE_REPO/scripts/check.sh" "$FAKE_REPO/scripts/doctor.sh"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'command_name=${0##*/}' \
    'printf "%s" "$command_name" >> "$POSTFLIGHT_COMMAND_LOG"' \
    'printf " <%s>" "$@" >> "$POSTFLIGHT_COMMAND_LOG"' \
    'printf "\n" >> "$POSTFLIGHT_COMMAND_LOG"' \
    'case $command_name in' \
    '  hyprctl)' \
    '    [[ ${1:-} == configerrors ]] || exit 64' \
    '    if [[ $POSTFLIGHT_SCENARIO == config-errors ]]; then' \
    '      printf "fixture-private-config-path: invalid rule\n"' \
    '    elif [[ $POSTFLIGHT_SCENARIO == oversized-output ]]; then' \
    '      printf "%070000d" 0' \
    '    fi' \
    '    ;;' \
    '  systemctl)' \
    '    if [[ $POSTFLIGHT_SCENARIO == service-fail && ${*: -1} == walker.service ]]; then' \
    '      exit 42' \
    '    fi' \
    '    ;;' \
    '  pgrep)' \
    '    if [[ $POSTFLIGHT_SCENARIO == process-fail && $* == *waybar* ]]; then exit 43; fi' \
    '    ;;' \
    '  qs) [[ $* == "ipc show" ]] || exit 64 ;;' \
    '  nmcli)' \
    '    case $* in' \
    '      "--terse --fields STATE general status") printf "connected:fixture-network-name\n" ;;' \
    '      "radio wifi") printf "enabled\n" ;;' \
    '      *) exit 64 ;;' \
    '    esac' \
    '    ;;' \
    '  wpctl)' \
    '    [[ $* == "get-volume @DEFAULT_AUDIO_SINK@" ]] || exit 64' \
    '    printf "Volume: 0.50 fixture-audio-device\n"' \
    '    ;;' \
    '  busctl)' \
    '    printf "fixture-notification-content\n"' \
    '    ;;' \
    '  flatpak)' \
    '    [[ $* == "remotes --columns=name" ]] || exit 64' \
    '    [[ $POSTFLIGHT_SCENARIO != flatpak-command-fail ]] || exit 44' \
    '    ;;' \
    '  pacdiff)' \
    '    [[ $* == "--output" ]] || exit 64' \
    '    if [[ $POSTFLIGHT_SCENARIO == package-attention ]]; then' \
    '      printf "%s\n" /etc/fixture-private.conf.pacnew /etc/fixture-old.conf.pacsave' \
    '    fi' \
    '    ;;' \
    '  needrestart)' \
    '    [[ $* == "-b" ]] || exit 64' \
    '    if [[ $POSTFLIGHT_SCENARIO == recommendations ]]; then' \
    '      printf "%s\n" "NEEDRESTART-SVC: fixture-one" "NEEDRESTART-SESS: fixture-two"' \
    '    fi' \
    '    ;;' \
    '  checkrebuild)' \
    '    if [[ $POSTFLIGHT_SCENARIO == recommendations ]]; then' \
    '      for index in $(seq 1 1005); do printf "fixture-aur-%s\n" "$index"; done' \
    '    fi' \
    '    ;;' \
    '  *) exit 64 ;;' \
    'esac' \
    > "$FAKE_BIN/fixture-command"
chmod 0755 -- "$FAKE_BIN/fixture-command"
for command_name in hyprctl systemctl pgrep qs nmcli wpctl busctl flatpak \
    pacdiff needrestart checkrebuild; do
    ln -s -- fixture-command "$FAKE_BIN/$command_name"
done
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'if [[ ${POSTFLIGHT_SCENARIO:-} == engine-fail && $* == *"--arg name repository"* ]]; then' \
    '  exit 73' \
    'fi' \
    'exec /usr/bin/jq "$@"' \
    > "$FAKE_BIN/jq"
chmod 0755 -- "$FAKE_BIN/jq"

export POSTFLIGHT_COMMAND_LOG="$COMMAND_LOG"
REPO_ROOT=$FAKE_REPO

reset_context() {
    _maintenance_close_lock_fd
    unset MYHYPR_TRANSACTION_DIR MAINTENANCE_STATE_ROOT
    unset MAINTENANCE_RUNTIME_ROOT MAINTENANCE_TX_ROOT
    unset WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE
}

begin_case() {
    local name=$1 operation=$2 profile=$3 case_root

    reset_context
    case_root="$TEST_ROOT/$name"
    HOME="$case_root/home"
    XDG_STATE_HOME="$case_root/state"
    XDG_RUNTIME_DIR="$case_root/run"
    export HOME XDG_STATE_HOME XDG_RUNTIME_DIR
    mkdir -p -- "$HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
    chmod 0700 -- "$HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
    maintenance_paths_init || fail "$name paths could not be initialized"
    maintenance_lock_acquire || fail "$name lock could not be acquired"
    maintenance_tx_begin "$operation" "$profile" '' '' || \
        fail "$name transaction could not begin"
    TX_DIR=$MYHYPR_TRANSACTION_DIR
    maintenance_tx_transition "$TX_DIR" planned preflighted preflight || \
        fail "$name could not enter preflighted"
    maintenance_tx_transition "$TX_DIR" preflighted checkpointed checkpoint || \
        fail "$name could not enter checkpointed"
    maintenance_tx_transition "$TX_DIR" checkpointed applying apply || \
        fail "$name could not enter applying"
    maintenance_tx_transition "$TX_DIR" applying verifying postflight || \
        fail "$name could not enter verifying"
    : > "$COMMAND_LOG"
}

write_package_plan() {
    local tx_dir=$1
    shift
    jq -n --arg id "${tx_dir##*/}" --args '
        {
            version: 1,
            transaction_id: $id,
            reboot_sensitive_classes: $ARGS.positional
        }
    ' -- "$@" > "$tx_dir/package-plan.json"
    chmod 0600 -- "$tx_dir/package-plan.json"
}

run_postflight() {
    local operation=$1 profile=$2 expected_status=$3 actual_status

    set +e
    PATH="$FAKE_BIN:/usr/bin:/bin" \
        maintenance_postflight "$operation" "$profile" "$TX_DIR"
    actual_status=$?
    set -e
    [[ $actual_status -eq $expected_status ]] || \
        fail "$operation/$profile returned $actual_status instead of $expected_status"
}

assert_common_schema() {
    local file=$1 operation=$2 profile=$3 live=$4

    [[ $(stat -c %a -- "$file") == 600 ]] || fail 'postflight evidence is not private'
    jq -e --arg id "${TX_DIR##*/}" --arg operation "$operation" \
        --arg profile "$profile" --argjson live "$live" '
        .version == 1 and .transaction_id == $id and
        .operation == $operation and .profile == $profile and
        .live_session == $live and
        (.created_at | type == "string" and test("^[0-9]{8}T[0-9]{6}Z$")) and
        (.required_passed | type == "boolean") and
        (.needs_attention | type == "boolean") and
        (.result == "passed" or .result == "failed" or .result == "needs-attention") and
        (.checks | type == "array" and length > 0) and
        all(.checks[];
            (keys | sort) == (["class","exit_status","name","required","status"] | sort) and
            (.name | type == "string" and test("^[a-z0-9-]{1,64}$")) and
            (.required | type == "boolean") and
            (.class == "health" or .class == "optional" or .class == "package") and
            (.status == "passed" or .status == "failed" or
             .status == "unavailable" or .status == "needs-attention") and
            (.exit_status | type == "number" and . >= 0 and . <= 255)
        ) and
        ([.checks[].name] | length) == ([.checks[].name] | unique | length) and
        (.recommendations | type == "array") and
        all(.recommendations[];
            (keys | sort) == (["capped","class","count"] | sort) and
            (.class | type == "string" and test("^[a-z0-9-]{1,64}$")) and
            (.count | type == "number" and . > 0 and . <= 1000) and
            (.capped | type == "boolean")
        ) and
        (keys | sort) == ([
            "checks","created_at","live_session","needs_attention","operation",
            "profile","recommendations","required_passed","result",
            "transaction_id","version"
        ] | sort)
    ' "$file" >/dev/null || fail 'postflight JSON schema is unbounded or incorrect'
}

assert_json_omits_outputs() {
    local file=$1 forbidden

    for forbidden in fixture-worktree-name fixture-device-name fixture-network-name \
        fixture-audio-device fixture-notification-content fixture-private-config-path \
        fixture-private.conf fixture-old.conf fixture-aur-one fixture-one; do
        ! rg -Fq "$forbidden" "$file" || \
            fail "postflight JSON captured command output: $forbidden"
    done
}

begin_case core dotfiles core
POSTFLIGHT_SCENARIO=core
export POSTFLIGHT_SCENARIO
run_postflight dotfiles core 0
assert_common_schema "$TX_DIR/postflight.json" dotfiles core false
jq -e '
    .required_passed == true and .needs_attention == false and .result == "passed" and
    [.checks[].name] == ["repository","doctor"] and
    all(.checks[]; .required == true and .status == "passed") and
    .recommendations == []
' "$TX_DIR/postflight.json" >/dev/null || fail 'core/headless checks were not minimal'
if rg -q '^(hyprctl|systemctl|pgrep|qs|nmcli|wpctl|busctl|flatpak|pacdiff)' \
    "$COMMAND_LOG"; then
    fail 'core/headless postflight ran desktop or package checks'
fi
assert_json_omits_outputs "$TX_DIR/postflight.json"

begin_case repository-fail dotfiles core
POSTFLIGHT_SCENARIO=repository-fail
export POSTFLIGHT_SCENARIO
run_postflight dotfiles core 1
assert_common_schema "$TX_DIR/postflight.json" dotfiles core false
jq -e '
    .required_passed == false and .result == "failed" and
    any(.checks[]; .name == "repository" and .required == true and
        .status == "failed")
' "$TX_DIR/postflight.json" >/dev/null || fail 'failed repository validation passed'
assert_json_omits_outputs "$TX_DIR/postflight.json"

begin_case partial-session dotfiles desktop
POSTFLIGHT_SCENARIO=core
export POSTFLIGHT_SCENARIO WAYLAND_DISPLAY=wayland-fixture
unset HYPRLAND_INSTANCE_SIGNATURE
run_postflight dotfiles desktop 0
assert_common_schema "$TX_DIR/postflight.json" dotfiles desktop false
jq -e '
    [.checks[].name] == ["repository","doctor"] and
    .required_passed == true and .recommendations == []
' "$TX_DIR/postflight.json" >/dev/null || \
    fail 'partial session variables triggered unsafe live checks'
if rg -q '^(hyprctl|systemctl|pgrep|qs|nmcli|wpctl|busctl)' "$COMMAND_LOG"; then
    fail 'postflight attempted live checks without a complete Hyprland session'
fi

begin_case live dotfiles desktop
POSTFLIGHT_SCENARIO=live
export POSTFLIGHT_SCENARIO WAYLAND_DISPLAY=wayland-fixture
export HYPRLAND_INSTANCE_SIGNATURE=hypr-fixture
run_postflight dotfiles desktop 0
assert_common_schema "$TX_DIR/postflight.json" dotfiles desktop true
jq -e '
    .required_passed == true and .result == "passed" and
    ([.checks[] | select(.required == true) | .name] | sort) == ([
        "audio-sink","doctor","dock","elephant-service","hyprland-config",
        "myhypr-session","network-manager","notification-daemon",
        "pipewire-pulse-service","pipewire-service","quickshell-ipc",
        "quickshell-process","repository","swaync-control","swaync-process",
        "walker-service","wallpaper","waybar","wifi-availability",
        "wifi-control","wireplumber-service"
    ] | sort)
' "$TX_DIR/postflight.json" >/dev/null || fail 'live desktop required checks are incomplete'
for expected in \
    'hyprctl <configerrors>' \
    'systemctl <--user> <is-active> <myhypr-session.target>' \
    'pgrep <-x> <waybar>' \
    'pgrep <-f> <--> <(^|/)[n]wg-dock-hyprland([[:space:]]|$)>' \
    'qs <ipc> <show>' \
    'nmcli <--terse> <--fields> <STATE> <general> <status>' \
    'nmcli <radio> <wifi>' \
    'wpctl <get-volume> <@DEFAULT_AUDIO_SINK@>' \
    'busctl <--user> <--timeout=3> <status> <org.freedesktop.Notifications>'; do
    rg -Fq "$expected" "$COMMAND_LOG" || fail "live check was not called exactly: $expected"
done
assert_json_omits_outputs "$TX_DIR/postflight.json"

begin_case config-errors dotfiles desktop
POSTFLIGHT_SCENARIO=config-errors
export POSTFLIGHT_SCENARIO WAYLAND_DISPLAY=wayland-fixture
export HYPRLAND_INSTANCE_SIGNATURE=hypr-fixture
run_postflight dotfiles desktop 1
assert_common_schema "$TX_DIR/postflight.json" dotfiles desktop true
jq -e '
    .required_passed == false and .result == "failed" and
    any(.checks[]; .name == "hyprland-config" and .status == "failed")
' "$TX_DIR/postflight.json" >/dev/null || fail 'Hyprland config errors passed postflight'
assert_json_omits_outputs "$TX_DIR/postflight.json"

begin_case oversized-output dotfiles desktop
POSTFLIGHT_SCENARIO=oversized-output
export POSTFLIGHT_SCENARIO WAYLAND_DISPLAY=wayland-fixture
export HYPRLAND_INSTANCE_SIGNATURE=hypr-fixture
run_postflight dotfiles desktop 1
assert_common_schema "$TX_DIR/postflight.json" dotfiles desktop true
jq -e '
    .required_passed == false and .result == "failed" and
    any(.checks[]; .name == "hyprland-config" and .exit_status == 75)
' "$TX_DIR/postflight.json" >/dev/null || fail 'oversized command output was accepted'
if find "$TX_DIR" -maxdepth 1 -name '.postflight-output.*' -print -quit | \
    grep -q .; then
    fail 'bounded command output remained in transaction state'
fi

begin_case service-fail dotfiles desktop
POSTFLIGHT_SCENARIO=service-fail
export POSTFLIGHT_SCENARIO WAYLAND_DISPLAY=wayland-fixture
export HYPRLAND_INSTANCE_SIGNATURE=hypr-fixture
run_postflight dotfiles desktop 1
assert_common_schema "$TX_DIR/postflight.json" dotfiles desktop true
jq -e '
    .required_passed == false and .result == "failed" and
    any(.checks[]; .name == "walker-service" and .exit_status == 42)
' "$TX_DIR/postflight.json" >/dev/null || fail 'failed required user service passed'

begin_case optional-flatpak system desktop
POSTFLIGHT_SCENARIO=optional-flatpak
export POSTFLIGHT_SCENARIO
write_package_plan "$TX_DIR"
run_postflight system desktop 0
assert_common_schema "$TX_DIR/postflight.json" system desktop false
jq -e '
    .required_passed == true and .result == "passed" and
    any(.checks[]; .name == "flatpak-remotes" and
        .required == false and .status == "passed") and
    any(.checks[]; .name == "package-config-merges" and .status == "passed")
' "$TX_DIR/postflight.json" >/dev/null || fail 'missing optional Flatpak remote failed'

begin_case optional-flatpak-fail system desktop
POSTFLIGHT_SCENARIO=flatpak-command-fail
export POSTFLIGHT_SCENARIO
write_package_plan "$TX_DIR"
run_postflight system desktop 0
assert_common_schema "$TX_DIR/postflight.json" system desktop false
jq -e '
    .required_passed == true and .result == "passed" and
    any(.checks[]; .name == "flatpak-remotes" and
        .required == false and .status == "failed" and .exit_status == 44)
' "$TX_DIR/postflight.json" >/dev/null || fail 'optional Flatpak failure blocked promotion'

begin_case package-attention system desktop
POSTFLIGHT_SCENARIO=package-attention
export POSTFLIGHT_SCENARIO
write_package_plan "$TX_DIR"
run_postflight system desktop 1
assert_common_schema "$TX_DIR/postflight.json" system desktop false
jq -e '
    .required_passed == false and .needs_attention == true and
    .result == "needs-attention" and
    any(.checks[]; .name == "package-config-merges" and
        .status == "needs-attention") and
    any(.recommendations[]; .class == "pacnew-findings" and .count == 1) and
    any(.recommendations[]; .class == "pacsave-findings" and .count == 1)
' "$TX_DIR/postflight.json" >/dev/null || fail 'package merge findings were false success'
assert_json_omits_outputs "$TX_DIR/postflight.json"

begin_case invalid-plan system desktop
POSTFLIGHT_SCENARIO=optional-flatpak
export POSTFLIGHT_SCENARIO
printf '%s\n' '{"version":1,"transaction_id":"wrong","reboot_sensitive_classes":[]}' \
    > "$TX_DIR/package-plan.json"
chmod 0600 -- "$TX_DIR/package-plan.json"
run_postflight system desktop 1
assert_common_schema "$TX_DIR/postflight.json" system desktop false
jq -e '
    .required_passed == false and .result == "failed" and
    any(.checks[]; .name == "package-plan" and .status == "failed")
' "$TX_DIR/postflight.json" >/dev/null || \
    fail 'invalid package plan permitted postflight success'

begin_case recommendations system full
POSTFLIGHT_SCENARIO=recommendations
export POSTFLIGHT_SCENARIO
write_package_plan "$TX_DIR" kernel graphics-stack firmware
run_postflight system full 0
assert_common_schema "$TX_DIR/postflight.json" system full false
jq -e '
    .required_passed == true and .needs_attention == false and
    .result == "passed" and
    any(.recommendations[]; .class == "outdated-processes" and .count == 2) and
    any(.recommendations[]; .class == "aur-rebuilds" and
        .count == 1000 and .capped == true) and
    any(.recommendations[]; .class == "reboot-sensitive" and .count == 3)
' "$TX_DIR/postflight.json" >/dev/null || fail 'bounded recommendation counts are missing'
assert_json_omits_outputs "$TX_DIR/postflight.json"

begin_case engine-fail dotfiles core
POSTFLIGHT_SCENARIO=engine-fail
export POSTFLIGHT_SCENARIO
run_postflight dotfiles core 74
jq -e '
    .version == 1 and .result == "in-progress" and
    .required_passed == false
' "$TX_DIR/postflight.json" >/dev/null || \
    fail 'internal recorder failure left trusted success evidence'
if find "$TX_DIR" -maxdepth 1 \
    \( -name '.postflight-checks.*' -o -name '.postflight-recommendations.*' \) \
    -print -quit | grep -q .; then
    fail 'internal recorder failure left temporary status files'
fi

begin_case mismatch dotfiles desktop
POSTFLIGHT_SCENARIO=core
export POSTFLIGHT_SCENARIO
if PATH="$FAKE_BIN:/usr/bin:/bin" \
    maintenance_postflight system desktop "$TX_DIR"; then
    fail 'postflight accepted an operation that differs from its journal'
fi
[[ ! -e $TX_DIR/postflight.json ]] || fail 'rejected context wrote postflight evidence'

printf 'Postflight health evidence is bounded, private, and profile-aware.\n'
