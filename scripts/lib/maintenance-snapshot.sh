#!/usr/bin/env bash

# Conservative adapters for already-configured Snapper and Timeshift providers.
# This library never installs a provider and never performs a snapshot restore.

_snapshot_safe_provider() {
    [[ ${1:-} == none || ${1:-} == snapper || ${1:-} == timeshift ]]
}

_snapshot_trusted_binary() {
    local name=$1 path canonical owner mode numeric_mode

    case $name in
        cat|snapper|sudo|timeshift) path="/usr/bin/$name" ;;
        *) return 1 ;;
    esac
    [[ -x $path && -f $path && ! -L $path ]] || return 1
    canonical=$(/usr/bin/realpath -e -- "$path" 2>/dev/null) || return 1
    [[ $canonical == "$path" ]] || return 1
    owner=$(/usr/bin/stat -c %u -- "$path" 2>/dev/null) || return 1
    mode=$(/usr/bin/stat -c %a -- "$path" 2>/dev/null) || return 1
    [[ $owner == 0 && $mode =~ ^[0-7]{3,4}$ ]] || return 1
    numeric_mode=$((8#$mode))
    (( (numeric_mode & 0022) == 0 )) || return 1
    printf '%s\n' "$path"
}

_snapshot_mount_json() {
    local mount_target=$1 mount_output

    mount_output=$(findmnt -J -T "$mount_target" -o TARGET,FSTYPE,SOURCE,OPTIONS \
        2>/dev/null) || return 1
    jq -ce '
        .filesystems | select(type == "array" and length == 1) | .[0] |
        select(
            (.target | type == "string") and
            (.fstype | type == "string") and
            (.source | type == "string") and
            (.options | type == "string")
        ) |
        {target,fstype,source,options}
    ' <<< "$mount_output" 2>/dev/null
}

_snapshot_same_mount() {
    local root_mount=$1 layer_mount=$2

    jq -en --argjson root "$root_mount" --argjson layer "$layer_mount" '
        $root.target == $layer.target and
        $root.fstype == $layer.fstype and
        $root.source == $layer.source
    ' >/dev/null
}

_snapshot_path_has_no_nested_subvolume() {
    local path=$1 mount_target=$2 current inode

    [[ $path == /* && $mount_target == /* ]] || return 1
    if [[ $mount_target == / ]]; then
        [[ $path == /* ]] || return 1
    else
        [[ $path == "$mount_target" || $path == "$mount_target"/* ]] || return 1
    fi
    current=$path
    while [[ $current != "$mount_target" ]]; do
        [[ -e $current && ! -L $current ]] || return 1
        inode=$(stat -Lc %i -- "$current" 2>/dev/null) || return 1
        # Every Btrfs subvolume root has inode 256; root snapshots are not recursive.
        [[ $inode != 256 ]] || return 1
        current=${current%/*}
        [[ -n $current ]] || current=/
    done
}

_snapshot_root_covers_layer() {
    local root_mount=$1 layer_mount=$2 layer_path=$3 mount_target

    _snapshot_same_mount "$root_mount" "$layer_mount" || return 1
    mount_target=$(jq -er '.target' <<< "$root_mount") || return 1
    _snapshot_path_has_no_nested_subvolume "$layer_path" "$mount_target"
}

_snapshot_probe_mounts() {
    _SNAPSHOT_ROOT_MOUNT=$(_snapshot_mount_json /) || return 1
    _SNAPSHOT_PACKAGE_MOUNT=$(_snapshot_mount_json /var/lib/pacman) || return 1
    _SNAPSHOT_HOME_MOUNT=$(_snapshot_mount_json /home) || return 1
    _SNAPSHOT_BOOT_MOUNT=$(_snapshot_mount_json /boot) || return 1
}

_snapshot_emit_probe() {
    local provider=$1 reason=$2 root=$3 package_db=$4 home=$5 boot=$6

    jq -cn --arg provider "$provider" --arg reason "$reason" \
        --argjson root "$root" --argjson package_db "$package_db" \
        --argjson home "$home" --argjson boot "$boot" '
        {
            version: 1,
            provider: $provider,
            coverage: {
                root: $root,
                package_db: $package_db,
                home: $home,
                boot: $boot
            },
            system_restorable: ($root and $package_db and $boot),
            reason: $reason
        }
    '
}

_snapshot_probe_snapper() {
    local configs snapper_bin sudo_bin root_type
    local root=false package_db=false home=false boot=false

    snapper_bin=$(_snapshot_trusted_binary snapper) || return 2
    if ! configs=$("$snapper_bin" --jsonout list-configs 2>/dev/null); then
        sudo_bin=$(_snapshot_trusted_binary sudo) || return 1
        configs=$("$sudo_bin" -n "$snapper_bin" --jsonout list-configs 2>/dev/null) || \
            return 1
    fi
    jq -e '
        .configs | select(type == "array") |
        all(.[]; (.config | type == "string") and (.subvolume | type == "string"))
    ' <<< "$configs" >/dev/null 2>&1 || return 1
    if ! jq -e '.configs | any(.config == "root" and .subvolume == "/")' \
        <<< "$configs" >/dev/null; then
        return 2
    fi
    _snapshot_probe_mounts || return 1
    root_type=$(jq -r '.fstype' <<< "$_SNAPSHOT_ROOT_MOUNT") || return 1
    [[ $root_type == btrfs ]] || return 1
    root=true
    _snapshot_root_covers_layer \
        "$_SNAPSHOT_ROOT_MOUNT" "$_SNAPSHOT_PACKAGE_MOUNT" /var/lib/pacman && \
        package_db=true
    _snapshot_root_covers_layer \
        "$_SNAPSHOT_ROOT_MOUNT" "$_SNAPSHOT_HOME_MOUNT" /home && home=true
    _snapshot_root_covers_layer \
        "$_SNAPSHOT_ROOT_MOUNT" "$_SNAPSHOT_BOOT_MOUNT" /boot && boot=true
    _SNAPSHOT_PROBE_JSON=$(
        _snapshot_emit_probe snapper healthy "$root" "$package_db" "$home" "$boot"
    ) || return 1
}

_snapshot_timeshift_config_valid() {
    local config=$1

    jq -e '
        type == "object" and
        (.btrfs_mode == true or .btrfs_mode == false or
         .btrfs_mode == "true" or .btrfs_mode == "false") and
        (.include_btrfs_home == true or .include_btrfs_home == false or
         .include_btrfs_home == "true" or .include_btrfs_home == "false") and
        (.exclude | type == "array") and
        all(.exclude[];
            type == "string" and length <= 512 and
            (contains("\n") or contains("\t") | not)
        )
    ' <<< "$config" >/dev/null 2>&1
}

_snapshot_probe_timeshift() {
    local list_output config mode timeshift_bin sudo_bin cat_bin
    local root=false package_db=false home=false boot=false

    timeshift_bin=$(_snapshot_trusted_binary timeshift) || return 2
    sudo_bin=$(_snapshot_trusted_binary sudo) || return 2
    cat_bin=$(_snapshot_trusted_binary cat) || return 2
    config=$("$sudo_bin" -n "$cat_bin" /etc/timeshift/timeshift.json 2>/dev/null) || \
        return 2
    _snapshot_timeshift_config_valid "$config" || return 1
    list_output=$(LC_ALL=C "$sudo_bin" -n "$timeshift_bin" --scripted --list \
        2>/dev/null) || return 1
    mode=$(sed -nE 's/^[[:space:]]*Mode[[:space:]]*:[[:space:]]*(BTRFS|RSYNC)[[:space:]]*$/\1/p' \
        <<< "$list_output" | tail -n 1)
    [[ $mode == BTRFS ]] || return 1
    sed -nE 's/^[[:space:]]*Status[[:space:]]*:[[:space:]]*(OK)[[:space:]]*$/\1/p' \
        <<< "$list_output" | tail -n 1 | jq -R -e 'select(. == "OK")' >/dev/null || return 1

    _snapshot_probe_mounts || return 1
    jq -e '
        .fstype == "btrfs" and
        (.source | test("\\[/@\\]$"))
    ' <<< "$_SNAPSHOT_ROOT_MOUNT" >/dev/null || return 1
    jq -e '.btrfs_mode == true or .btrfs_mode == "true"' \
        <<< "$config" >/dev/null || return 1
    root=true
    if _snapshot_root_covers_layer \
        "$_SNAPSHOT_ROOT_MOUNT" "$_SNAPSHOT_PACKAGE_MOUNT" /var/lib/pacman; then
        package_db=true
    fi
    if jq -e '
        .include_btrfs_home == true or .include_btrfs_home == "true"
    ' <<< "$config" >/dev/null; then
        jq -e '
            .fstype == "btrfs" and
            (.source | test("\\[/@home\\]$"))
        ' <<< "$_SNAPSHOT_HOME_MOUNT" >/dev/null && home=true
    fi
    _snapshot_root_covers_layer \
        "$_SNAPSHOT_ROOT_MOUNT" "$_SNAPSHOT_BOOT_MOUNT" /boot && boot=true
    _SNAPSHOT_PROBE_JSON=$(
        _snapshot_emit_probe timeshift healthy "$root" "$package_db" "$home" "$boot"
    ) || return 1
}

snapshot_probe() {
    local selected=${MYHYPR_SNAPSHOT_PROVIDER:-auto}
    local snapper_status=2 timeshift_status=2

    case $selected in
        none)
            _snapshot_emit_probe none explicitly-disabled false false false false
            return
            ;;
        snapper)
            if _snapshot_probe_snapper; then
                printf '%s\n' "$_SNAPSHOT_PROBE_JSON"
                return
            fi
            warn 'The requested snapper root provider is unavailable or unhealthy.'
            return 69
            ;;
        timeshift)
            if _snapshot_probe_timeshift; then
                printf '%s\n' "$_SNAPSHOT_PROBE_JSON"
                return
            fi
            warn 'The requested timeshift provider is unavailable or unhealthy.'
            return 69
            ;;
        auto) ;;
        *)
            warn 'Snapshot provider must be auto, none, snapper, or timeshift.'
            return 64
            ;;
    esac

    if _snapshot_probe_snapper; then
        printf '%s\n' "$_SNAPSHOT_PROBE_JSON"
        return
    else
        snapper_status=$?
    fi
    if _snapshot_probe_timeshift; then
        printf '%s\n' "$_SNAPSHOT_PROBE_JSON"
        return
    else
        timeshift_status=$?
    fi
    if (( snapper_status == 1 || timeshift_status == 1 )); then
        _snapshot_emit_probe none probe-failed false false false false
    else
        _snapshot_emit_probe none no-provider false false false false
    fi
}

_snapshot_load_coverage() {
    local tx_dir=$1 provider=$2

    _maintenance_tx_require_active "$tx_dir" || return 1
    _SNAPSHOT_TX_DIR=$_MAINTENANCE_VALIDATED_TX_DIR
    _SNAPSHOT_COVERAGE_JSON=$(jq -ce --arg provider "$provider" '
        select(
            .state == "checkpointed" and
            (.completed_stages | index("checkpoint") != null) and
            .recovery.configuration == "ready"
        ) |
        select(.recovery.system_provider == $provider) |
        .recovery.system_coverage |
        select(
            type == "object" and .version == 1 and .provider == $provider and
            (keys | sort) ==
                (["coverage","provider","reason","system_restorable","version"] | sort) and
            (.reason | type == "string" and test("^[a-z0-9-]{1,64}$")) and
            (.coverage | type == "object") and
            (.coverage | keys | sort) ==
                (["boot","home","package_db","root"] | sort) and
            (.coverage.root | type == "boolean") and
            (.coverage.package_db | type == "boolean") and
            (.coverage.home | type == "boolean") and
            (.coverage.boot | type == "boolean") and
            (.system_restorable | type == "boolean")
        ) |
        select(
            .system_restorable ==
            (.coverage.root and .coverage.package_db and .coverage.boot)
        )
    ' "$_SNAPSHOT_TX_DIR/journal.json" 2>/dev/null) || return 1
}

_snapshot_uncovered_layers() {
    local coverage=$1 layer joined IFS=,
    local -a uncovered=()

    for layer in root package_db home boot; do
        jq -e --arg layer "$layer" '.coverage[$layer] == true' \
            <<< "$coverage" >/dev/null || uncovered+=("${layer//_/-}")
    done
    joined=${uncovered[*]}
    printf '%s\n' "$joined"
}

_snapshot_accept_coverage() {
    local coverage=$1 uncovered answer

    jq -e '.provider == "none" and .reason == "explicitly-disabled"' \
        <<< "$coverage" >/dev/null && return 0
    uncovered=$(_snapshot_uncovered_layers "$coverage") || return 1
    [[ -z $uncovered ]] && return 0
    warn "System snapshot coverage is incomplete; uncovered layers: $uncovered"
    warn 'Universal configuration recovery remains available; package rollback stays manual.'
    [[ ${ASSUME_YES:-0} == 1 ]] && return 0
    if [[ -t 0 ]]; then
        read -r -p 'Proceed with this recovery limitation? [y/N] ' answer
        [[ $answer == [yY] || $answer == [yY][eE][sS] ]] && return 0
    fi
    return 2
}

_snapshot_revalidate_coverage() {
    local provider=$1 expected=$2 current

    [[ $provider != none ]] || return 0
    current=$(MYHYPR_SNAPSHOT_PROVIDER="$provider" snapshot_probe 2>/dev/null) || return 69
    jq -en --argjson expected "$expected" --argjson current "$current" \
        '$expected == $current' >/dev/null || return 65
}

_snapshot_fail_transaction() {
    local tx_dir=$1 exit_status=$2 message_class=$3

    if ! maintenance_tx_fail "$tx_dir" snapshot "$exit_status" "$message_class" \
        >/dev/null 2>&1; then
        warn 'Snapshot failure could not be published to the transaction journal.'
        return 74
    fi
    return "$exit_status"
}

_snapshot_write_pending() {
    local tx_dir=$1 provider=$2 status=$3 identifier=${4:-} final next now transaction_id

    _snapshot_safe_provider "$provider" && [[ $provider != none ]] || return 1
    [[ $status == creating || $status == created-unpublished ]] || return 1
    if [[ $status == creating ]]; then
        [[ -z $identifier ]] || return 1
    else
        case $provider in
            snapper) [[ $identifier =~ ^[0-9]{1,20}$ ]] || return 1 ;;
            timeshift)
                [[ $identifier =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]] || \
                    return 1
                ;;
        esac
    fi
    transaction_id=${tx_dir##*/}
    _maintenance_safe_transaction_id "$transaction_id" || return 1
    final="$tx_dir/snapshot.pending.json"
    if [[ $status == creating ]]; then
        [[ ! -e $final && ! -L $final ]] || return 1
    else
        _maintenance_validate_owned_file "$final" || return 1
        jq -e --arg provider "$provider" --arg transaction_id "$transaction_id" '
            .version == 1 and .provider == $provider and
            .transaction_id == $transaction_id and .status == "creating" and
            .identifier == "" and
            (keys | sort) ==
                (["identifier","provider","status","transaction_id","updated_at","version"] | sort)
        ' "$final" >/dev/null || return 1
    fi
    next=$(mktemp "$tx_dir/.snapshot-pending.XXXXXXXX") || return 1
    now=$(timestamp)
    if ! jq -n --arg provider "$provider" --arg transaction_id "$transaction_id" \
        --arg status "$status" --arg identifier "$identifier" --arg now "$now" '
        {
            version: 1,
            provider: $provider,
            transaction_id: $transaction_id,
            status: $status,
            identifier: $identifier,
            updated_at: $now
        }
    ' > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    chmod 0600 -- "$next" || {
        rm -f -- "$next"
        return 1
    }
    mv -- "$next" "$final" || {
        rm -f -- "$next"
        return 1
    }
}

_snapshot_clear_pending() {
    local pending=$1/snapshot.pending.json

    _maintenance_validate_owned_file "$pending" || return 1
    rm -f -- "$pending"
}

_snapshot_write_metadata() {
    local tx_dir=$1 provider=$2 identifier=$3 coverage=$4 now next final

    now=$(timestamp)
    final="$tx_dir/snapshot.json"
    [[ ! -e $final && ! -L $final ]] || return 1
    next=$(mktemp "$tx_dir/.snapshot.XXXXXXXX") || return 1
    if ! jq -n --arg provider "$provider" --arg identifier "$identifier" \
        --arg now "$now" --argjson probe "$coverage" '
        {
            version: 1,
            provider: $provider,
            identifier: $identifier,
            coverage: $probe.coverage,
            created_at: $now
        }
    ' > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    chmod 0600 -- "$next" || {
        rm -f -- "$next"
        return 1
    }
    mv -- "$next" "$final" || {
        rm -f -- "$next"
        return 1
    }
}

snapshot_create() {
    local tx_dir=${1:-} provider=${2:-} command_output='' command_status=0 identifier=''
    local transaction_id sudo_bin provider_bin

    _snapshot_safe_provider "$provider" || return 64
    _snapshot_load_coverage "$tx_dir" "$provider" || return 1
    tx_dir=$_SNAPSHOT_TX_DIR
    [[ ! -e $tx_dir/snapshot.json && ! -L $tx_dir/snapshot.json &&
        ! -e $tx_dir/snapshot.pending.json && ! -L $tx_dir/snapshot.pending.json ]] || \
        return 1
    if _snapshot_revalidate_coverage "$provider" "$_SNAPSHOT_COVERAGE_JSON"; then
        command_status=0
    else
        command_status=$?
        if (( command_status == 69 )); then
            _snapshot_fail_transaction "$tx_dir" "$command_status" snapshot-provider-changed
        else
            _snapshot_fail_transaction "$tx_dir" "$command_status" snapshot-coverage-changed
        fi
        return $?
    fi
    _snapshot_accept_coverage "$_SNAPSHOT_COVERAGE_JSON" || return $?
    transaction_id=${tx_dir##*/}
    if [[ $provider == none ]]; then
        _snapshot_write_metadata "$tx_dir" none none "$_SNAPSHOT_COVERAGE_JSON" || {
            _snapshot_fail_transaction "$tx_dir" 74 snapshot-metadata-failed
            return $?
        }
        return 0
    fi
    _snapshot_write_pending "$tx_dir" "$provider" creating || {
        _snapshot_fail_transaction "$tx_dir" 74 snapshot-pending-failed
        return $?
    }
    sudo_bin=$(_snapshot_trusted_binary sudo) || {
        _snapshot_fail_transaction "$tx_dir" 69 snapshot-provider-unavailable
        return $?
    }
    case $provider in
        snapper)
            provider_bin=$(_snapshot_trusted_binary snapper) || {
                _snapshot_fail_transaction "$tx_dir" 69 snapshot-provider-unavailable
                return $?
            }
            if command_output=$(LC_ALL=C "$sudo_bin" "$provider_bin" \
                -c root create --type single \
                --print-number --description "MyHypr $transaction_id" \
                --userdata "myhypr_transaction=$transaction_id" 2>&1); then
                command_status=0
            else
                command_status=$?
            fi
            if (( command_status == 0 )) && [[ $command_output =~ ^[0-9]{1,20}$ ]]; then
                identifier=$command_output
            fi
            ;;
        timeshift)
            provider_bin=$(_snapshot_trusted_binary timeshift) || {
                _snapshot_fail_transaction "$tx_dir" 69 snapshot-provider-unavailable
                return $?
            }
            if command_output=$(LC_ALL=C "$sudo_bin" "$provider_bin" --create \
                --comments "MyHypr $transaction_id" 2>&1); then
                command_status=0
            else
                command_status=$?
            fi
            if (( command_status == 0 )); then
                identifier=$(sed -nE \
                    "s/.*Tagged snapshot '([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2})'.*/\\1/p" \
                    <<< "$command_output" | tail -n 1)
            fi
            ;;
    esac
    if (( command_status != 0 )); then
        _snapshot_clear_pending "$tx_dir" >/dev/null 2>&1 || true
        _snapshot_fail_transaction "$tx_dir" "$command_status" snapshot-create-failed
        return $?
    fi
    if [[ -z $identifier ]]; then
        _snapshot_fail_transaction "$tx_dir" 65 snapshot-identifier-invalid
        return $?
    fi
    _snapshot_write_pending "$tx_dir" "$provider" created-unpublished "$identifier" || {
        _snapshot_fail_transaction "$tx_dir" 74 snapshot-metadata-failed
        return $?
    }
    _snapshot_write_metadata "$tx_dir" "$provider" "$identifier" \
        "$_SNAPSHOT_COVERAGE_JSON" || {
        _snapshot_fail_transaction "$tx_dir" 74 snapshot-metadata-failed
        return $?
    }
    _snapshot_clear_pending "$tx_dir" || {
        _snapshot_fail_transaction "$tx_dir" 74 snapshot-pending-cleanup-failed
        return $?
    }
}

snapshot_guidance() {
    local tx_dir=${1:-} provider=${2:-} snapshot_file pending_file journal
    local identifier coverage uncovered documentation metadata_state transaction_label=''

    _snapshot_safe_provider "$provider" || return 64
    _maintenance_tx_validate "$tx_dir" || return 1
    tx_dir=$_MAINTENANCE_VALIDATED_TX_DIR
    snapshot_file="$tx_dir/snapshot.json"
    pending_file="$tx_dir/snapshot.pending.json"
    journal="$tx_dir/journal.json"
    if _maintenance_validate_owned_file "$snapshot_file" && jq -e --arg provider "$provider" '
        .version == 1 and .provider == $provider and
        (
            ($provider == "snapper" and (.identifier | test("^[0-9]{1,20}$"))) or
            ($provider == "timeshift" and
                (.identifier | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$"))) or
            ($provider == "none" and .identifier == "none")
        ) and
        (.coverage | type == "object") and
        (.coverage | keys | sort) ==
            (["boot","home","package_db","root"] | sort) and
        all(.coverage[]; type == "boolean") and
        (.created_at | test("^[0-9]{8}T[0-9]{6}Z$")) and
        (keys | sort) == (["coverage","created_at","identifier","provider","version"] | sort)
    ' "$snapshot_file" >/dev/null; then
        identifier=$(jq -r '.identifier' "$snapshot_file") || return 1
        coverage=$(jq -c '{coverage}' "$snapshot_file") || return 1
        jq -e --arg provider "$provider" --argjson snapshot "$coverage" '
            .recovery.system_provider == $provider and
            .recovery.system_coverage.coverage == $snapshot.coverage
        ' "$journal" >/dev/null || return 1
        metadata_state=published
    elif _maintenance_validate_owned_file "$pending_file" && \
        jq -e --arg provider "$provider" --arg transaction_id "${tx_dir##*/}" '
            .version == 1 and .provider == $provider and
            .transaction_id == $transaction_id and
            (
                (.status == "creating" and .identifier == "") or
                (
                    .status == "created-unpublished" and
                    (
                        ($provider == "snapper" and
                            (.identifier | test("^[0-9]{1,20}$"))) or
                        ($provider == "timeshift" and
                            (.identifier | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$")))
                    )
                )
            ) and
            (.updated_at | test("^[0-9]{8}T[0-9]{6}Z$")) and
            (keys | sort) ==
                (["identifier","provider","status","transaction_id","updated_at","version"] | sort)
        ' "$pending_file" >/dev/null; then
        identifier=$(jq -r '.identifier' "$pending_file") || return 1
        metadata_state=$(jq -r '.status' "$pending_file") || return 1
        [[ -n $identifier ]] || identifier=unresolved
        transaction_label="MyHypr ${tx_dir##*/}"
        coverage=$(jq -ce --arg provider "$provider" '
            select(.recovery.system_provider == $provider) |
            .recovery.system_coverage |
            select(
                type == "object" and .version == 1 and .provider == $provider and
                (keys | sort) ==
                    (["coverage","provider","reason","system_restorable","version"] | sort) and
                (.reason | type == "string" and test("^[a-z0-9-]{1,64}$")) and
                (.coverage | type == "object") and
                (.coverage | keys | sort) ==
                    (["boot","home","package_db","root"] | sort) and
                all(.coverage[]; type == "boolean") and
                (.system_restorable | type == "boolean") and
                .system_restorable ==
                    (.coverage.root and .coverage.package_db and .coverage.boot)
            ) |
            {coverage}
        ' "$journal") || return 1
    else
        return 1
    fi
    uncovered=$(_snapshot_uncovered_layers "$coverage") || return 1
    case $provider in
        snapper) documentation='https://man.archlinux.org/man/snapper.8' ;;
        timeshift) documentation='https://github.com/linuxmint/timeshift' ;;
        none) documentation='https://wiki.archlinux.org/title/System_backup' ;;
    esac
    printf 'Snapshot provider: %s\n' "$provider"
    printf 'Snapshot identifier: %s\n' "$identifier"
    printf 'Snapshot metadata state: %s\n' "$metadata_state"
    [[ -z $transaction_label ]] || \
        printf 'Snapshot transaction label: %s\n' "$transaction_label"
    printf 'Uncovered layers: %s\n' "${uncovered:-none}"
    printf 'Package transaction log: /var/log/pacman.log\n'
    printf 'Review provider recovery documentation: %s\n' "$documentation"
    printf 'No filesystem restore, package downgrade, deletion, or reboot is run automatically.\n'
}
