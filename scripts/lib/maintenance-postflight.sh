#!/usr/bin/env bash

# Bounded post-update health evidence. This library is sourced after lib.sh and
# maintenance-transaction.sh and intentionally never records command output.
# shellcheck disable=SC2016  # Single-quoted jq programs must not expand in Bash.

_postflight_safe_name() {
    [[ ${1:-} =~ ^[a-z0-9-]{1,64}$ ]]
}

_postflight_safe_class() {
    case ${1:-} in
        health|optional|package) return 0 ;;
        *) return 1 ;;
    esac
}

_postflight_safe_status() {
    case ${1:-} in
        passed|failed|unavailable|needs-attention) return 0 ;;
        *) return 1 ;;
    esac
}

_postflight_context() {
    local operation=$1 profile=$2 requested=$3 journal
    local recorded_operation recorded_profile state

    case $operation in dotfiles|system) ;; *) return 64 ;; esac
    case $profile in core|desktop|full) ;; *) return 64 ;; esac
    _maintenance_tx_require_active "$requested" || {
        warn 'Postflight requires the active locked transaction.'
        return 1
    }
    _POSTFLIGHT_TX_DIR=$_MAINTENANCE_VALIDATED_TX_DIR
    journal="$_POSTFLIGHT_TX_DIR/journal.json"
    recorded_operation=$(jq -er '.operation | select(type == "string")' \
        "$journal" 2>/dev/null) || return 1
    recorded_profile=$(jq -er '.profile | select(type == "string")' \
        "$journal" 2>/dev/null) || return 1
    state=$(jq -er '.state | select(type == "string")' "$journal" \
        2>/dev/null) || return 1
    [[ $recorded_operation == "$operation" && $recorded_profile == "$profile" && \
        $state == verifying ]] || {
        warn 'Postflight arguments or state differ from the active transaction.'
        return 1
    }
    [[ $REPO_ROOT == /* && -d $REPO_ROOT && ! -L $REPO_ROOT ]] || return 1
    [[ -x $REPO_ROOT/scripts/check.sh && -x $REPO_ROOT/scripts/doctor.sh ]] || \
        return 1
}

_postflight_append_record() {
    local name=$1 required=$2 class=$3 status=$4 exit_status=$5
    local numeric_status

    _postflight_safe_name "$name" && _postflight_safe_class "$class" && \
        _postflight_safe_status "$status" || return 1
    [[ $required == true || $required == false ]] || return 1
    [[ $exit_status =~ ^[0-9]{1,3}$ ]] || return 1
    numeric_status=$((10#$exit_status))
    ((numeric_status >= 0 && numeric_status <= 255)) || return 1
    if ! jq -cn --arg name "$name" --argjson required "$required" \
        --arg class "$class" --arg status "$status" \
        --argjson exit_status "$numeric_status" '
        {
            name: $name,
            required: $required,
            class: $class,
            status: $status,
            exit_status: $exit_status
        }
    ' >> "$_POSTFLIGHT_CHECKS_FILE"; then
        return 1
    fi
    if [[ $required == true && $status == failed ]]; then
        _POSTFLIGHT_REQUIRED_FAILED=1
    elif [[ $required == true && $status == needs-attention ]]; then
        _POSTFLIGHT_NEEDS_ATTENTION=1
    fi
}

postflight_append() {
    local name=$1 required=$2 check_status=$3
    local class=${4:-health} numeric_status status=failed

    [[ $check_status =~ ^[0-9]{1,3}$ ]] || return 1
    numeric_status=$((10#$check_status))
    ((numeric_status >= 0 && numeric_status <= 255)) || return 1
    [[ $numeric_status -eq 0 ]] && status=passed
    if ! _postflight_append_record "$name" "$required" "$class" "$status" \
        "$numeric_status"; then
        _POSTFLIGHT_ENGINE_FAILED=1
        return 1
    fi
}

postflight_check() {
    local name=$1 required=$2
    shift 2
    local check_status=0 class=${_POSTFLIGHT_CHECK_CLASS:-health}

    "$@" >/dev/null 2>&1 || check_status=$?
    postflight_append "$name" "$required" "$check_status" "$class" || return 1
    [[ $required == false || $check_status -eq 0 ]]
}

_postflight_run_check() {
    local name=$1 required=$2 class=$3
    shift 3
    local previous_class=${_POSTFLIGHT_CHECK_CLASS:-}
    local check_status=0

    _POSTFLIGHT_CHECK_CLASS=$class
    postflight_check "$name" "$required" "$@" || check_status=$?
    _POSTFLIGHT_CHECK_CLASS=$previous_class
    return "$check_status"
}

_postflight_timed_check() {
    local name=$1 required=$2 class=$3
    shift 3

    _postflight_run_check "$name" "$required" "$class" \
        timeout --kill-after=1 5 "$@"
}

_postflight_unavailable() {
    local name=$1 class=${2:-optional}

    if ! _postflight_append_record "$name" false "$class" unavailable 127; then
        _POSTFLIGHT_ENGINE_FAILED=1
        return 1
    fi
}

_postflight_capture() {
    local tx_dir=$1
    shift
    local output size
    local -a statuses=()

    output=$(mktemp "$tx_dir/.postflight-output.XXXXXXXX") || return 1
    chmod 0600 -- "$output" || {
        rm -f -- "$output"
        return 1
    }
    if timeout --kill-after=1 5 "$@" 2>/dev/null | \
        head -c 65537 > "$output"; then
        statuses=("${PIPESTATUS[@]}")
    else
        statuses=("${PIPESTATUS[@]}")
    fi
    [[ ${statuses[1]} -eq 0 ]] || {
        rm -f -- "$output"
        return 1
    }
    size=$(stat -c %s -- "$output" 2>/dev/null) || {
        rm -f -- "$output"
        return 1
    }
    if ((size > 65536)); then
        _POSTFLIGHT_CAPTURE_STATUS=75
    else
        _POSTFLIGHT_CAPTURE_STATUS=${statuses[0]}
        ((_POSTFLIGHT_CAPTURE_STATUS <= 255)) || _POSTFLIGHT_CAPTURE_STATUS=74
    fi
    _POSTFLIGHT_CAPTURE_FILE=$output
}

_postflight_bounded_count() {
    local file=$1 matcher=${2:-} count suffix pattern

    if [[ $matcher == suffix:* ]]; then
        suffix=${matcher#suffix:}
        [[ -n $suffix ]] || return 1
        count=$(awk -v suffix="$suffix" '
            length($0) >= length(suffix) &&
                substr($0, length($0) - length(suffix) + 1) == suffix {
                count += 1
            }
            END { print count + 0 }
        ' "$file") || return 1
    elif [[ $matcher == regex:* ]]; then
        pattern=${matcher#regex:}
        [[ -n $pattern ]] || return 1
        count=$(awk -v pattern="$pattern" '
            $0 ~ pattern { count += 1 }
            END { print count + 0 }
        ' "$file") || return 1
    else
        count=$(awk 'NF { count += 1 } END { print count + 0 }' "$file") || return 1
    fi
    [[ $count =~ ^[0-9]+$ ]] || return 1
    if ((count > 1000)); then
        _POSTFLIGHT_COUNT=1000
        _POSTFLIGHT_COUNT_CAPPED=true
    else
        _POSTFLIGHT_COUNT=$count
        _POSTFLIGHT_COUNT_CAPPED=false
    fi
}

_postflight_recommendation() {
    local class=$1 count=$2 capped=$3

    case $class in
        pacnew-findings|pacsave-findings|outdated-processes|aur-rebuilds|\
            reboot-sensitive) ;;
        *) return 1 ;;
    esac
    [[ $count =~ ^[0-9]+$ ]] || return 1
    ((count > 0 && count <= 1000)) || return 1
    [[ $capped == true || $capped == false ]] || return 1
    if ! jq -cn --arg class "$class" --argjson count "$count" \
        --argjson capped "$capped" \
        '{class: $class, count: $count, capped: $capped}' \
        >> "$_POSTFLIGHT_RECOMMENDATIONS_FILE"; then
        _POSTFLIGHT_ENGINE_FAILED=1
        return 1
    fi
}

_postflight_hyprland_config() {
    local tx_dir=$1 status

    _postflight_capture "$tx_dir" hyprctl configerrors || {
        _POSTFLIGHT_ENGINE_FAILED=1
        return 1
    }
    status=$_POSTFLIGHT_CAPTURE_STATUS
    if [[ $status -eq 0 ]] && \
        ! LC_ALL=C grep -q '[^[:space:]]' "$_POSTFLIGHT_CAPTURE_FILE"; then
        postflight_append hyprland-config true 0 health
    else
        [[ $status -ne 0 ]] || status=1
        postflight_append hyprland-config true "$status" health
    fi
    rm -f -- "$_POSTFLIGHT_CAPTURE_FILE"
}

_postflight_process_absent() {
    local status=0

    timeout --kill-after=1 5 "$@" >/dev/null 2>&1 || status=$?
    [[ $status -eq 1 ]]
}

_postflight_component_process() {
    local name=$1 disabled_marker=$2
    shift 2

    if [[ -e $disabled_marker || -L $disabled_marker ]]; then
        if [[ ! -f $disabled_marker || -L $disabled_marker ]]; then
            postflight_append "$name" true 1 health
            return
        fi
        _postflight_run_check "$name" true health \
            _postflight_process_absent "$@"
        return
    fi
    _postflight_timed_check "$name" true health "$@"
}

_postflight_live_desktop() {
    local tx_dir=$1 config_root settings_root

    config_root=${XDG_CONFIG_HOME:-$HOME/.config}
    settings_root="$config_root/myhypr/settings"

    _postflight_hyprland_config "$tx_dir" || true
    _postflight_timed_check myhypr-session true health \
        systemctl --user is-active myhypr-session.target || true
    _postflight_timed_check elephant-service true health \
        systemctl --user is-active elephant.service || true
    _postflight_timed_check walker-service true health \
        systemctl --user is-active walker.service || true
    _postflight_component_process waybar "$settings_root/waybar-disabled" \
        pgrep -x waybar || true
    _postflight_component_process dock "$settings_root/dock-disabled" pgrep -f -- \
        '(^|/)[n]wg-dock-hyprland([[:space:]]|$)' || true
    _postflight_timed_check quickshell-process true health \
        pgrep -x quickshell || true
    _postflight_timed_check quickshell-ipc true health qs ipc show || true
    _postflight_timed_check swaync-process true health pgrep -x swaync || true
    _postflight_timed_check wallpaper true health pgrep -x awww-daemon || true

    _postflight_timed_check network-manager true health \
        systemctl is-active NetworkManager.service || true
    _postflight_timed_check wifi-availability true health \
        nmcli --terse --fields STATE general status || true
    _postflight_timed_check wifi-control true health nmcli radio wifi || true

    _postflight_timed_check pipewire-service true health \
        systemctl --user is-active pipewire.service || true
    _postflight_timed_check pipewire-pulse-service true health \
        systemctl --user is-active pipewire-pulse.service || true
    _postflight_timed_check wireplumber-service true health \
        systemctl --user is-active wireplumber.service || true
    _postflight_timed_check audio-sink true health \
        wpctl get-volume '@DEFAULT_AUDIO_SINK@' || true

    _postflight_timed_check notification-daemon true health \
        busctl --user --timeout=3 status org.freedesktop.Notifications || true
    _postflight_timed_check swaync-control true health \
        busctl --user --timeout=3 status org.erikreider.swaync.cc || true
}

_postflight_package_plan() {
    local tx_dir=$1 plan count

    plan="$tx_dir/package-plan.json"

    if ! _maintenance_validate_owned_file "$plan" || ! jq -e \
        --arg id "${tx_dir##*/}" '
        .version == 1 and .transaction_id == $id and
        (.reboot_sensitive_classes | type == "array" and length <= 5) and
        all(.reboot_sensitive_classes[];
            . == "kernel" or . == "systemd" or . == "graphics-stack" or
            . == "firmware" or . == "libc"
        ) and
        (.reboot_sensitive_classes | length) ==
            (.reboot_sensitive_classes | unique | length) and
        (keys | sort) ==
            (["reboot_sensitive_classes","transaction_id","version"] | sort)
    ' "$plan" >/dev/null 2>&1; then
        postflight_append package-plan true 1 package
        return
    fi
    postflight_append package-plan true 0 package || return 1
    count=$(jq -er '.reboot_sensitive_classes | length' "$plan") || return 1
    if ((count > 0)); then
        _postflight_recommendation reboot-sensitive "$count" false
    fi
}

_postflight_package_merges() {
    local tx_dir=$1 status pacnew pacsave capped output

    if ! command -v pacdiff >/dev/null 2>&1; then
        _postflight_unavailable package-config-merges package
        return
    fi
    _postflight_capture "$tx_dir" pacdiff --output || {
        _POSTFLIGHT_ENGINE_FAILED=1
        return 1
    }
    output=$_POSTFLIGHT_CAPTURE_FILE
    status=$_POSTFLIGHT_CAPTURE_STATUS
    if [[ $status -ne 0 ]]; then
        postflight_append package-config-merges true "$status" package
        rm -f -- "$output"
        return
    fi
    if ! _postflight_bounded_count "$output" 'suffix:.pacnew'; then
        rm -f -- "$output"
        _POSTFLIGHT_ENGINE_FAILED=1
        return 1
    fi
    pacnew=$_POSTFLIGHT_COUNT
    capped=$_POSTFLIGHT_COUNT_CAPPED
    if ((pacnew > 0)) && \
        ! _postflight_recommendation pacnew-findings "$pacnew" "$capped"; then
        rm -f -- "$output"
        return 1
    fi
    if ! _postflight_bounded_count "$output" 'suffix:.pacsave'; then
        rm -f -- "$output"
        _POSTFLIGHT_ENGINE_FAILED=1
        return 1
    fi
    pacsave=$_POSTFLIGHT_COUNT
    capped=$_POSTFLIGHT_COUNT_CAPPED
    if ((pacsave > 0)) && \
        ! _postflight_recommendation pacsave-findings "$pacsave" "$capped"; then
        rm -f -- "$output"
        return 1
    fi
    rm -f -- "$output"
    if ((pacnew > 0 || pacsave > 0)); then
        if ! _postflight_append_record package-config-merges true package \
            needs-attention 0; then
            _POSTFLIGHT_ENGINE_FAILED=1
            return 1
        fi
    else
        postflight_append package-config-merges true 0 package
    fi
}

_postflight_optional_count() {
    local tx_dir=$1 check_name=$2 recommendation_class=$3 pattern=$4
    shift 4
    local status output

    if ! command -v -- "$1" >/dev/null 2>&1; then
        _postflight_unavailable "$check_name" optional
        return
    fi
    _postflight_capture "$tx_dir" "$@" || {
        _POSTFLIGHT_ENGINE_FAILED=1
        return 1
    }
    output=$_POSTFLIGHT_CAPTURE_FILE
    status=$_POSTFLIGHT_CAPTURE_STATUS
    if ! postflight_append "$check_name" false "$status" optional; then
        rm -f -- "$output"
        return 1
    fi
    if [[ $status -eq 0 ]]; then
        if ! _postflight_bounded_count "$output" "$pattern"; then
            rm -f -- "$output"
            _POSTFLIGHT_ENGINE_FAILED=1
            return 1
        fi
        if ((_POSTFLIGHT_COUNT > 0)); then
            if ! _postflight_recommendation "$recommendation_class" \
                "$_POSTFLIGHT_COUNT" "$_POSTFLIGHT_COUNT_CAPPED"; then
                rm -f -- "$output"
                return 1
            fi
        fi
    fi
    rm -f -- "$output"
}

_postflight_invalidate_previous() {
    local tx_dir=$1 operation=$2 profile=$3 next

    next=$(mktemp "$tx_dir/.postflight.pending.XXXXXXXX") || return 1
    if ! jq -n --arg id "${tx_dir##*/}" --arg operation "$operation" \
        --arg profile "$profile" '
        {
            version: 1,
            transaction_id: $id,
            operation: $operation,
            profile: $profile,
            result: "in-progress",
            required_passed: false
        }
    ' > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    chmod 0600 -- "$next" || {
        rm -f -- "$next"
        return 1
    }
    if ! mv -- "$next" "$tx_dir/postflight.json"; then
        rm -f -- "$next"
        return 1
    fi
}

_postflight_system_checks() {
    local tx_dir=$1

    _postflight_package_plan "$tx_dir" || true
    _postflight_package_merges "$tx_dir" || true
    if command -v flatpak >/dev/null 2>&1; then
        _postflight_run_check flatpak-remotes false optional \
            flatpak remotes --columns=name || true
    else
        _postflight_unavailable flatpak-remotes optional || true
    fi
    _postflight_optional_count "$tx_dir" outdated-process-scan \
        outdated-processes 'regex:^NEEDRESTART-(SVC|CONT|SESS):' \
        needrestart -b || true
    _postflight_optional_count "$tx_dir" aur-rebuild-scan \
        aur-rebuilds '' checkrebuild || true
}

_postflight_publish() {
    local tx_dir=$1 operation=$2 profile=$3 live=$4
    local required_passed=true needs_attention=false result=passed now next

    if [[ $_POSTFLIGHT_NEEDS_ATTENTION -ne 0 ]]; then
        needs_attention=true
    fi
    if [[ $_POSTFLIGHT_REQUIRED_FAILED -ne 0 ]]; then
        required_passed=false
        result=failed
    elif [[ $_POSTFLIGHT_NEEDS_ATTENTION -ne 0 ]]; then
        required_passed=false
        result=needs-attention
    fi
    now=$(timestamp)
    next=$(mktemp "$tx_dir/.postflight.XXXXXXXX") || return 1
    if ! jq -n --slurpfile checks "$_POSTFLIGHT_CHECKS_FILE" \
        --slurpfile recommendations "$_POSTFLIGHT_RECOMMENDATIONS_FILE" \
        --arg id "${tx_dir##*/}" --arg operation "$operation" \
        --arg profile "$profile" --arg now "$now" --arg result "$result" \
        --argjson live "$live" --argjson required_passed "$required_passed" \
        --argjson needs_attention "$needs_attention" '
        {
            version: 1,
            transaction_id: $id,
            operation: $operation,
            profile: $profile,
            live_session: $live,
            created_at: $now,
            result: $result,
            required_passed: $required_passed,
            needs_attention: $needs_attention,
            checks: $checks,
            recommendations: $recommendations
        }
    ' > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    chmod 0600 -- "$next" || {
        rm -f -- "$next"
        return 1
    }
    if ! mv -- "$next" "$tx_dir/postflight.json"; then
        rm -f -- "$next"
        return 1
    fi
    [[ $required_passed == true ]]
}

maintenance_postflight() {
    local operation=${1:-} profile=${2:-} tx_dir=${3:-} live=false result=0

    _postflight_context "$operation" "$profile" "$tx_dir" || return $?
    tx_dir=$_POSTFLIGHT_TX_DIR
    if [[ -e $tx_dir/postflight.json || -L $tx_dir/postflight.json ]]; then
        _maintenance_validate_owned_file "$tx_dir/postflight.json" || return 1
    fi
    umask 077
    _POSTFLIGHT_CHECKS_FILE=$(mktemp "$tx_dir/.postflight-checks.XXXXXXXX") || \
        return 1
    _POSTFLIGHT_RECOMMENDATIONS_FILE=$(
        mktemp "$tx_dir/.postflight-recommendations.XXXXXXXX"
    ) || {
        rm -f -- "$_POSTFLIGHT_CHECKS_FILE"
        return 1
    }
    chmod 0600 -- "$_POSTFLIGHT_CHECKS_FILE" \
        "$_POSTFLIGHT_RECOMMENDATIONS_FILE" || {
        rm -f -- "$_POSTFLIGHT_CHECKS_FILE" \
            "$_POSTFLIGHT_RECOMMENDATIONS_FILE"
        return 1
    }
    _POSTFLIGHT_REQUIRED_FAILED=0
    _POSTFLIGHT_NEEDS_ATTENTION=0
    _POSTFLIGHT_ENGINE_FAILED=0

    _postflight_invalidate_previous "$tx_dir" "$operation" "$profile" || {
        rm -f -- "$_POSTFLIGHT_CHECKS_FILE" \
            "$_POSTFLIGHT_RECOMMENDATIONS_FILE"
        return 1
    }

    _postflight_run_check repository true health \
        "$REPO_ROOT/scripts/check.sh" --quick || true
    _postflight_run_check doctor true health \
        "$REPO_ROOT/scripts/doctor.sh" --profile "$profile" --quick || true

    if [[ ($profile == desktop || $profile == full) && \
        -n ${WAYLAND_DISPLAY:-} && -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
        live=true
        _postflight_live_desktop "$tx_dir"
    fi
    if [[ $operation == system ]]; then
        _postflight_system_checks "$tx_dir"
    fi
    if [[ $_POSTFLIGHT_ENGINE_FAILED -ne 0 ]]; then
        rm -f -- "$_POSTFLIGHT_CHECKS_FILE" \
            "$_POSTFLIGHT_RECOMMENDATIONS_FILE"
        warn 'Postflight could not complete its bounded health evidence.'
        return 74
    fi
    _postflight_publish "$tx_dir" "$operation" "$profile" "$live" || result=$?
    rm -f -- "$_POSTFLIGHT_CHECKS_FILE" \
        "$_POSTFLIGHT_RECOMMENDATIONS_FILE"
    if [[ $result -ne 0 ]]; then
        warn 'Required postflight health checks did not pass.'
    fi
    return "$result"
}
