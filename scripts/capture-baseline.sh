#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329  # jq/regex literals and run_evidence callbacks are intentional.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

OUTPUT=''
CAPTURE_SCREENSHOT=0

usage() {
    cat <<'EOF'
Usage: scripts/capture-baseline.sh [--output DIR] [--screenshot]

Capture a private, bounded validation and desktop-health baseline. The output
is local evidence only and is never added to Git or published automatically.
EOF
}

while (($#)); do
    case $1 in
        --output)
            (($# >= 2)) || die '--output requires a directory'
            OUTPUT=$2
            shift 2
            ;;
        --screenshot)
            CAPTURE_SCREENSHOT=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

require_command git
require_command jq
require_command realpath
require_command sha256sum

umask 077
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/myhyprlandrice"
EVIDENCE_ROOT="$STATE_ROOT/evidence"

create_private_directory() {
    local directory=$1
    [[ $directory != / && ! -e $directory && ! -L $directory ]] || return 1
    mkdir -m 0700 -- "$directory"
    [[ -d $directory && ! -L $directory ]] || return 1
    chmod 0700 -- "$directory"
}

if [[ -n $OUTPUT ]]; then
    OUTPUT=$(realpath -m -- "$OUTPUT")
    parent_directory=$(dirname -- "$OUTPUT")
    mkdir -p -- "$parent_directory"
    create_private_directory "$OUTPUT" || \
        die "Evidence output must be a new, non-symlink directory: $OUTPUT"
else
    mkdir -p -- "$EVIDENCE_ROOT"
    [[ -d $EVIDENCE_ROOT && ! -L $EVIDENCE_ROOT ]] || \
        die "Evidence root is not a private directory: $EVIDENCE_ROOT"
    chmod 0700 -- "$EVIDENCE_ROOT"
    OUTPUT=$(mktemp -d "$EVIDENCE_ROOT/baseline.XXXXXXXX")
    chmod 0700 -- "$OUTPUT"
fi

MANIFEST="$OUTPUT/manifest.json"
overall_status=0
LAST_EVIDENCE_STATUS=0

read_bounded_value() {
    local path=$1 pattern=$2 fallback=$3
    local value
    if [[ ! -f $path || -L $path ]] || (( $(wc -c < "$path") > 256 )); then
        printf '%s\n' "$fallback"
        return
    fi
    IFS= read -r value < "$path" || true
    if [[ $value =~ $pattern ]]; then
        printf '%s\n' "$value"
    else
        printf '%s\n' "$fallback"
    fi
}

selector_value() {
    local category=$1
    local path="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/conf/$category.conf"
    local value
    value=$(read_bounded_value "$path" '^[A-Za-z0-9_./~=${} -]{1,256}$' unavailable)
    [[ $value != unavailable ]] || {
        printf 'unavailable\n'
        return
    }
    value=${value##*/}
    value=${value%%.*}
    if [[ $value =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
        printf '%s\n' "$value"
    else
        printf 'unavailable\n'
    fi
}

hash_inventory() {
    local relative
    if (($# == 0)); then
        printf 'empty\n' | sha256sum | cut -d' ' -f1
        return
    fi
    for relative in "$@"; do
        printf '%s\0' "$relative"
        sha256sum -- "$REPO_ROOT/$relative" | cut -d' ' -f1
    done | sha256sum | cut -d' ' -f1
}

mapfile -d '' binding_files < <(
    git -C "$REPO_ROOT" ls-files -z -- \
        tests/test-keybindings.lua dotfiles/.config/hypr/conf/keybindings | sort -z
)
mapfile -d '' action_files < <(
    git -C "$REPO_ROOT" ls-files -z -- \
        tests/test-waybar-actions.sh dotfiles/.config/waybar/modules.json | sort -z
)
binding_hash=$(hash_inventory "${binding_files[@]}")
action_hash=$(hash_inventory "${action_files[@]}")

CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
selectors='{}'
for category in animation decoration environment layout monitor \
    window windowrule workspace; do
    selected=$(selector_value "$category")
    selectors=$(jq -c --arg category "$category" --arg selected "$selected" \
        '. + {($category): $selected}' <<< "$selectors")
done
keybinding_profile=$(read_bounded_value \
    "$CONFIG_ROOT/myhypr/settings/keybinding-profile" \
    '^(default|fr)$' default)
selectors=$(jq -c --arg selected "$keybinding_profile" \
    '. + {keybinding: $selected}' <<< "$selectors")

primary=$(read_bounded_value "$CONFIG_ROOT/myhypr/colors/primary" \
    '^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$' unavailable)
secondary=$(read_bounded_value "$CONFIG_ROOT/myhypr/colors/secondary" \
    '^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$' unavailable)
on_surface=$(read_bounded_value "$CONFIG_ROOT/myhypr/colors/onsurface" \
    '^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$' unavailable)
wallpaper_engine=$(read_bounded_value \
    "$CONFIG_ROOT/myhypr/settings/wallpaper-engine.sh" \
    '^[A-Za-z0-9._-]{1,64}$' unavailable)
wallpaper_effect=$(read_bounded_value \
    "$CONFIG_ROOT/myhypr/settings/wallpaper-effect.sh" \
    '^[A-Za-z0-9._-]{1,64}$' unavailable)
[[ -e $CONFIG_ROOT/myhypr/settings/waybar-disabled ]] && waybar_state=disabled || \
    waybar_state=enabled
[[ -e $CONFIG_ROOT/myhypr/settings/dock-disabled ]] && dock_state=disabled || \
    dock_state=enabled

commit=$(git -C "$REPO_ROOT" rev-parse HEAD)
if [[ -z $(git -C "$REPO_ROOT" status --porcelain) ]]; then
    worktree_clean=true
else
    worktree_clean=false
fi

jq -n \
    --arg created_at "$(timestamp)" \
    --arg commit "$commit" \
    --argjson worktree_clean "$worktree_clean" \
    --argjson selectors "$selectors" \
    --arg primary "$primary" \
    --arg secondary "$secondary" \
    --arg on_surface "$on_surface" \
    --arg wallpaper_engine "$wallpaper_engine" \
    --arg wallpaper_effect "$wallpaper_effect" \
    --arg waybar "$waybar_state" \
    --arg dock "$dock_state" \
    --arg binding_hash "$binding_hash" \
    --argjson binding_count "${#binding_files[@]}" \
    --arg action_hash "$action_hash" \
    --argjson action_count "${#action_files[@]}" \
    '{
        version: 1,
        created_at: $created_at,
        commit: $commit,
        worktree_clean: $worktree_clean,
        screenshot: "not-requested",
        checks: [],
        inventories: {
            bindings: {count: $binding_count, sha256: $binding_hash},
            desktop_actions: {count: $action_count, sha256: $action_hash}
        },
        selectors: $selectors,
        visual: {
            primary: $primary,
            secondary: $secondary,
            on_surface: $on_surface,
            wallpaper_engine: $wallpaper_engine,
            wallpaper_effect: $wallpaper_effect,
            waybar: $waybar,
            dock: $dock
        }
    }' > "$MANIFEST"
chmod 0600 -- "$MANIFEST"

update_manifest() {
    local filter=$1
    shift
    local next="$OUTPUT/.manifest.$$.json"
    jq "$@" "$filter" "$MANIFEST" > "$next"
    chmod 0600 -- "$next"
    mv -- "$next" "$MANIFEST"
}

append_check() {
    local name=$1 status=$2 artifact=$3 required=$4 class=${5:-completed}
    update_manifest \
        '.checks += [{name: $name, status: $status, required: $required,
                      class: $class, artifact: $artifact}]' \
        --arg name "$name" \
        --argjson status "$status" \
        --argjson required "$required" \
        --arg class "$class" \
        --arg artifact "$artifact"
}

run_evidence() {
    local required=$1 name=$2
    shift 2
    local log="$OUTPUT/$name.log"
    set +e
    "$@" > "$log" 2>&1
    LAST_EVIDENCE_STATUS=$?
    set -e
    chmod 0600 -- "$log"
    append_check "$name" "$LAST_EVIDENCE_STATUS" "$name.log" "$required"
    if [[ $required == true ]] && (( LAST_EVIDENCE_STATUS != 0 )); then
        overall_status=1
    fi
}

record_unavailable() {
    local name=$1 reason=$2
    local log="$OUTPUT/$name.log"
    printf 'unavailable: %s\n' "$reason" > "$log"
    chmod 0600 -- "$log"
    append_check "$name" 0 "$name.log" false unavailable
}

classify_check() {
    local name=$1 required=$2 class=$3 status=$4
    update_manifest \
        '.checks |= map(
            if .name == $name then
                .required = $required | .class = $class | .status = $status
            else . end
        )' \
        --arg name "$name" \
        --argjson required "$required" \
        --arg class "$class" \
        --argjson status "$status"
}

capture_service_health() {
    local unit
    for unit in myhypr-session.target elephant.service walker.service; do
        if systemctl --user is-active "$unit" >/dev/null 2>&1; then
            printf '%s active\n' "$unit"
        else
            printf '%s inactive\n' "$unit"
        fi
    done
}

capture_hyprland_configerrors() {
    local output command_status
    output=$(hyprctl configerrors)
    command_status=$?
    (( command_status == 0 )) || return 125
    [[ -n $output ]] && printf '%s\n' "$output"
    [[ -z ${output//[[:space:]]/} ]] || return 1
}

capture_process_resources() {
    ps -C 'waybar,quickshell,swaync,awww-daemon,nwg-dock-hyprland,walker,elephant' \
        -o comm=,pcpu=,pmem=,rss=
}

run_evidence true repository-status git -C "$REPO_ROOT" status --short --branch
run_evidence true repository-commit git -C "$REPO_ROOT" rev-parse HEAD
run_evidence true validation-full "$REPO_ROOT/scripts/check.sh"
run_evidence true validation-quick "$REPO_ROOT/scripts/check.sh" --quick
run_evidence true history-audit "$REPO_ROOT/scripts/audit.sh" --history
run_evidence false doctor-quick "$REPO_ROOT/scripts/doctor.sh" --profile desktop --quick

if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} && -n ${WAYLAND_DISPLAY:-} ]] && \
    command -v hyprctl >/dev/null 2>&1; then
    run_evidence false hyprland-configerrors capture_hyprland_configerrors
    case $LAST_EVIDENCE_STATUS in
        0)
            classify_check hyprland-configerrors true completed 0
            ;;
        1)
            classify_check hyprland-configerrors true config-errors 1
            overall_status=1
            ;;
        *)
            classify_check hyprland-configerrors false unavailable 125
            ;;
    esac
    if command -v systemctl >/dev/null 2>&1; then
        run_evidence false desktop-services capture_service_health
    else
        record_unavailable desktop-services systemctl-missing
    fi
    if command -v ps >/dev/null 2>&1; then
        run_evidence false desktop-resources capture_process_resources
    else
        record_unavailable desktop-resources ps-missing
    fi
    if command -v systemd-analyze >/dev/null 2>&1; then
        run_evidence false startup-summary systemd-analyze --user
    else
        record_unavailable startup-summary systemd-analyze-missing
    fi
else
    record_unavailable hyprland-configerrors no-live-hyprland-session
    record_unavailable desktop-services no-live-hyprland-session
    record_unavailable desktop-resources no-live-hyprland-session
    record_unavailable startup-summary no-live-hyprland-session
fi

if (( CAPTURE_SCREENSHOT == 1 )); then
    if command -v grim >/dev/null 2>&1; then
        run_evidence true screenshot-capture grim "$OUTPUT/desktop.png"
        if (( LAST_EVIDENCE_STATUS == 0 )) && [[ -f $OUTPUT/desktop.png ]]; then
            chmod 0600 -- "$OUTPUT/desktop.png"
            update_manifest '.screenshot = "captured"'
        else
            update_manifest '.screenshot = "failed"'
            overall_status=1
        fi
    else
        record_unavailable screenshot-capture grim-missing
        update_manifest '.screenshot = "unavailable"'
        overall_status=1
    fi
fi

find "$OUTPUT" -type f -exec chmod 0600 -- {} +
printf '%s\n' "$OUTPUT"
exit "$overall_status"
