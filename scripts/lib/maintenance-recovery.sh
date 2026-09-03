#!/usr/bin/env bash

# Universal, allow-listed configuration recovery for MyHyprlandRice.
# Source scripts/lib.sh and maintenance-transaction.sh before this file.
# shellcheck disable=SC2016  # Single-quoted jq programs must not expand in Bash.

recovery_validate_relative() {
    local relative=${1:-}

    [[ -n $relative && $relative != /* && $relative != */ && $relative != . ]] || return 1
    [[ $relative != *$'\t'* && $relative != *$'\n'* ]] || return 1
    [[ /$relative/ != *'/../'* && /$relative/ != *'/./'* ]] || return 1
    [[ $relative != *'//'* ]]
}

_recovery_local_scope() {
    printf '%s\0' \
        .config/fish/config.local.fish \
        .config/fish/fish_variables \
        .config/hypr/local.lua \
        .config/hypr/monitors.conf \
        .config/hypr/monitors.lua \
        .config/hypr/workspaces.conf \
        .config/hypr/workspaces.lua \
        .config/waypaper/config.ini \
        .config/gtk-3.0/colors.css \
        .config/gtk-4.0/colors.css \
        .config/hypr/colors.conf \
        .config/hypr/colors.lua \
        .config/kitty/colors-matugen.conf \
        .config/myhypr/colors/onsurface \
        .config/myhypr/colors/primary \
        .config/myhypr/colors/secondary \
        .config/nwg-dock-hyprland/colors.css \
        .config/rofi/colors.rasi \
        .config/swaync/colors.css \
        .config/walker/colors.css \
        .config/waybar/colors.css \
        .config/wlogout/colors.css \
        .config/myhypr/settings/dock-disabled \
        .config/myhypr/settings/gamemode-enabled \
        .config/myhypr/settings/waybar-disabled
}

_recovery_context_validate() {
    local tx_dir=$1 repo_root=$2 target_home=$3 owner

    _maintenance_tx_require_active "$tx_dir" || return 1
    [[ -d $repo_root && ! -L $repo_root ]] || return 1
    [[ -d $target_home && ! -L $target_home ]] || return 1
    owner=$(stat -c %u -- "$target_home" 2>/dev/null) || return 1
    [[ $owner == "$(id -u)" ]] || return 1
    _RECOVERY_TX_DIR=$_MAINTENANCE_VALIDATED_TX_DIR
    _RECOVERY_REPO_ROOT=$(realpath -e -- "$repo_root" 2>/dev/null) || return 1
    _RECOVERY_TARGET_HOME=$(realpath -e -- "$target_home" 2>/dev/null) || return 1
    [[ $_RECOVERY_TARGET_HOME != / ]] || return 1
    [[ $_RECOVERY_REPO_ROOT != / ]] || return 1
    [[ $_RECOVERY_TARGET_HOME != *$'\n'* && $_RECOVERY_TARGET_HOME != *$'\t'* ]] || \
        return 1
}

_recovery_blocking_parent() {
    local target_home=$1 relative=$2 partial='' component parent_relative
    local -a components

    parent_relative=$(dirname -- "$relative")
    [[ $parent_relative != . ]] || return 1
    IFS='/' read -r -a components <<< "$parent_relative"
    for component in "${components[@]}"; do
        partial=${partial:+$partial/}$component
        if [[ -L $target_home/$partial || \
            ( -e $target_home/$partial && ! -d $target_home/$partial ) ]]; then
            printf '%s\n' "$partial"
            return 0
        fi
    done
    return 1
}

_recovery_build_scope() {
    local repo_root=$1 target_home=$2 output=$3 candidate_root=${4:-}
    local inventory_root path relative blocking
    local defaults_inventory tracked_inventory inventory_error=0
    local -a inventory_roots=("$repo_root")
    local -A candidates=() final=()

    [[ -z $candidate_root ]] || inventory_roots+=("$candidate_root")
    defaults_inventory=$(mktemp "$(dirname -- "$output")/.defaults.XXXXXXXX") || return 1
    tracked_inventory=$(mktemp "$(dirname -- "$output")/.tracked.XXXXXXXX") || {
        rm -f -- "$defaults_inventory"
        return 1
    }
    for inventory_root in "${inventory_roots[@]}"; do
        : > "$defaults_inventory"
        : > "$tracked_inventory"
        if [[ -d $inventory_root/defaults ]]; then
            if ! find -P "$inventory_root/defaults" -type f -print0 \
                > "$defaults_inventory"; then
                rm -f -- "$defaults_inventory" "$tracked_inventory"
                return 1
            fi
            while IFS= read -r -d '' path; do
                relative=${path#"$inventory_root/defaults/"}
                if ! recovery_validate_relative "$relative"; then
                    inventory_error=1
                    break
                fi
                candidates["$relative"]=1
            done < "$defaults_inventory"
            if (( inventory_error != 0 )); then
                rm -f -- "$defaults_inventory" "$tracked_inventory"
                return 1
            fi
        fi
        while IFS= read -r -d '' relative; do
            recovery_validate_relative "$relative" || {
                rm -f -- "$defaults_inventory" "$tracked_inventory"
                return 1
            }
            candidates["$relative"]=1
        done < <(_recovery_local_scope)
        if ! git -C "$inventory_root" ls-files -z -- dotfiles \
            > "$tracked_inventory"; then
            rm -f -- "$defaults_inventory" "$tracked_inventory"
            return 1
        fi
        while IFS= read -r -d '' path; do
            relative=${path#dotfiles/}
            [[ $relative == .stow-local-ignore ]] && continue
            if ! recovery_validate_relative "$relative"; then
                inventory_error=1
                break
            fi
            [[ -f $inventory_root/$path || -L $inventory_root/$path ]] || continue
            candidates["$relative"]=1
        done < "$tracked_inventory"
        if (( inventory_error != 0 )); then
            rm -f -- "$defaults_inventory" "$tracked_inventory"
            return 1
        fi
    done
    rm -f -- "$defaults_inventory" "$tracked_inventory"

    while IFS= read -r relative; do
        if blocking=$(_recovery_blocking_parent "$target_home" "$relative"); then
            recovery_validate_relative "$blocking" || return 1
            final["$blocking"]=1
        else
            final["$relative"]=1
        fi
    done < <(printf '%s\n' "${!candidates[@]}" | LC_ALL=C sort -u)
    printf '%s\n' "${!final[@]}" | LC_ALL=C sort -u > "$output"
}

_recovery_candidate_root() {
    local tx_dir=$1 repo_root=$2 candidate_root candidate expected top canonical

    candidate_root="$tx_dir/candidate"
    if [[ ! -e $candidate_root && ! -L $candidate_root ]]; then
        return 0
    fi
    [[ -d $candidate_root && ! -L $candidate_root ]] || return 1
    canonical=$(realpath -e -- "$candidate_root" 2>/dev/null) || return 1
    [[ $canonical == "$tx_dir/candidate" ]] || return 1
    top=$(git -C "$canonical" rev-parse --show-toplevel 2>/dev/null) || return 1
    top=$(realpath -e -- "$top" 2>/dev/null) || return 1
    [[ $top == "$canonical" ]] || return 1
    candidate=$(git -C "$canonical" rev-parse HEAD 2>/dev/null) || return 1
    expected=$(jq -er '.candidate_commit | select(type == "string")' \
        "$tx_dir/journal.json" 2>/dev/null) || return 1
    [[ $candidate =~ ^[0-9a-f]{40}$ && $candidate == "$expected" ]] || return 1
    [[ $(git -C "$repo_root" cat-file -t "$candidate" 2>/dev/null) == commit ]] || \
        return 1
    printf '%s\n' "$canonical"
}

_recovery_capture_state() {
    local target_home=$1 relative=$2 target blocking

    recovery_validate_relative "$relative" || return 1
    if blocking=$(_recovery_blocking_parent "$target_home" "$relative"); then
        _RECOVERY_CAPTURE_TYPE=blocked
        _RECOVERY_CAPTURE_DETAIL=$blocking
        return 2
    fi
    target="$target_home/$relative"
    if [[ -L $target ]]; then
        _RECOVERY_CAPTURE_TYPE=symlink
        _RECOVERY_CAPTURE_DETAIL=$(readlink -- "$target") || return 1
        [[ $_RECOVERY_CAPTURE_DETAIL != *$'\t'* && \
            $_RECOVERY_CAPTURE_DETAIL != *$'\n'* ]] || return 1
    elif [[ -f $target ]]; then
        _RECOVERY_CAPTURE_TYPE='file'
        _RECOVERY_CAPTURE_DETAIL=$(sha256sum "$target" | cut -d' ' -f1) || return 1
    elif [[ -d $target ]]; then
        _RECOVERY_CAPTURE_TYPE=directory-owned
        _RECOVERY_CAPTURE_DETAIL=-
    elif [[ ! -e $target ]]; then
        _RECOVERY_CAPTURE_TYPE=missing
        _RECOVERY_CAPTURE_DETAIL=-
    else
        return 1
    fi
}

_recovery_link_is_managed() {
    local repo_root=$1 target_home=$2 relative=$3 link_target=$4 resolved package_root

    package_root=$(realpath -e -- "$repo_root/dotfiles" 2>/dev/null) || return 1
    if [[ $link_target == /* ]]; then
        resolved=$(realpath -m -- "$link_target") || return 1
    else
        resolved=$(realpath -m -- "$(dirname -- "$target_home/$relative")/$link_target") || \
            return 1
    fi
    [[ $resolved == "$package_root" || $resolved == "$package_root/"* ]]
}

_recovery_backup_matches() {
    local runtime=$1 type=$2 relative=$3 detail=$4
    local backup="$runtime/$relative" partial='' component parent_relative
    local -a components

    case $type in
        file|symlink)
            parent_relative=$(dirname -- "$relative")
            if [[ $parent_relative != . ]]; then
                IFS='/' read -r -a components <<< "$parent_relative"
                for component in "${components[@]}"; do
                    partial=${partial:+$partial/}$component
                    _maintenance_validate_private_directory "$runtime/$partial" || return 1
                done
            fi
            ;;&
        file)
            _maintenance_validate_owned_file "$backup" || return 1
            [[ $(sha256sum "$backup" | cut -d' ' -f1) == "$detail" ]]
            ;;
        symlink)
            [[ -L $backup ]] || return 1
            [[ $(readlink -- "$backup") == "$detail" ]]
            ;;
        missing|directory-owned) return 0 ;;
        *) return 1 ;;
    esac
}

_recovery_service_state() {
    local unit=$1 output service_status

    set +e
    output=$(systemctl --user is-active "$unit" 2>/dev/null)
    service_status=$?
    set -e
    case $output:$service_status in
        active:0) printf 'active\n' ;;
        inactive:3|failed:3|unknown:3|inactive:4|unknown:4) printf 'inactive\n' ;;
        *) return 1 ;;
    esac
}

_recovery_sha256_text() {
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

recovery_checkpoint_create() {
    local tx_dir=${1:-} repo_root=${2:-} target_home=${3:-}
    local checkpoint checkpoint_tmp runtime scope manifest missing managed services modes
    local candidate_root
    local relative type detail mode current_commit repo_commit target_digest manifest_digest
    local modes_digest now
    local unit service_state

    _recovery_context_validate "$tx_dir" "$repo_root" "$target_home" || return 1
    tx_dir=$_RECOVERY_TX_DIR
    repo_root=$_RECOVERY_REPO_ROOT
    target_home=$_RECOVERY_TARGET_HOME
    checkpoint="$tx_dir/checkpoint"
    [[ ! -e $checkpoint && ! -L $checkpoint ]] || return 1
    [[ -d $repo_root/defaults && -d $repo_root/dotfiles ]] || return 1

    current_commit=$(jq -er '.current_commit | select(type == "string")' \
        "$tx_dir/journal.json" 2>/dev/null) || return 1
    repo_commit=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null) || return 1
    [[ $current_commit == "$repo_commit" ]] || return 1
    candidate_root=$(_recovery_candidate_root "$tx_dir" "$repo_root") || return 1
    checkpoint_tmp=$(mktemp -d "$tx_dir/.checkpoint.XXXXXXXX") || return 1
    chmod 0700 -- "$checkpoint_tmp" || {
        rm -rf -- "$checkpoint_tmp"
        return 1
    }
    runtime="$checkpoint_tmp/runtime"
    scope="$checkpoint_tmp/.scope"
    manifest="$checkpoint_tmp/manifest.tsv"
    missing="$checkpoint_tmp/missing.txt"
    managed="$checkpoint_tmp/managed-links.tsv"
    services="$checkpoint_tmp/user-services.tsv"
    modes="$checkpoint_tmp/file-modes.tsv"
    mkdir -m 0700 -- "$runtime" || {
        rm -rf -- "$checkpoint_tmp"
        return 1
    }
    : > "$manifest"
    : > "$missing"
    : > "$managed"
    : > "$services"
    : > "$modes"
    chmod 0600 -- "$manifest" "$missing" "$managed" "$services" "$modes" || {
        rm -rf -- "$checkpoint_tmp"
        return 1
    }
    if ! _recovery_build_scope "$repo_root" "$target_home" "$scope" \
        "$candidate_root"; then
        rm -rf -- "$checkpoint_tmp"
        return 1
    fi

    while IFS= read -r relative; do
        [[ -n $relative ]] || continue
        if ! _recovery_capture_state "$target_home" "$relative"; then
            rm -rf -- "$checkpoint_tmp"
            return 1
        fi
        type=$_RECOVERY_CAPTURE_TYPE
        detail=$_RECOVERY_CAPTURE_DETAIL
        printf '%s\t%s\t%s\n' "$type" "$relative" "$detail" >> "$manifest"
        case $type in
            file|symlink)
                if ! rsync -aR -- "$target_home/./$relative" "$runtime/"; then
                    rm -rf -- "$checkpoint_tmp"
                    return 1
                fi
                if [[ $type == file ]]; then
                    mode=$(stat -c %a -- "$target_home/$relative" 2>/dev/null) || {
                        rm -rf -- "$checkpoint_tmp"
                        return 1
                    }
                    [[ $mode =~ ^[0-7]{3}$ ]] || {
                        rm -rf -- "$checkpoint_tmp"
                        return 1
                    }
                    printf '%s\t%s\n' "$relative" "$mode" >> "$modes"
                fi
                ;;
            missing) printf '%s\n' "$relative" >> "$missing" ;;
        esac
        if [[ $type == symlink ]] && \
            _recovery_link_is_managed "$repo_root" "$target_home" "$relative" "$detail"; then
            printf '%s\t%s\n' "$relative" "$detail" >> "$managed"
        fi
    done < "$scope"
    rm -f -- "$scope"

    for unit in myhypr-session.target elephant.service walker.service; do
        service_state=$(_recovery_service_state "$unit") || {
            rm -rf -- "$checkpoint_tmp"
            return 1
        }
        printf '%s\t%s\tpending\n' "$unit" "$service_state" >> "$services"
    done
    find "$runtime" -type d -exec chmod 0700 -- {} + || {
        rm -rf -- "$checkpoint_tmp"
        return 1
    }
    find "$runtime" -type f -exec chmod 0600 -- {} + || {
        rm -rf -- "$checkpoint_tmp"
        return 1
    }
    _recovery_manifest_validate "$manifest" "$runtime" || {
        rm -rf -- "$checkpoint_tmp"
        return 1
    }
    manifest_digest=$(sha256sum "$manifest" | cut -d' ' -f1) || {
        rm -rf -- "$checkpoint_tmp"
        return 1
    }
    modes_digest=$(sha256sum "$modes" | cut -d' ' -f1) || {
        rm -rf -- "$checkpoint_tmp"
        return 1
    }
    target_digest=$(_recovery_sha256_text "$target_home") || {
        rm -rf -- "$checkpoint_tmp"
        return 1
    }
    now=$(timestamp)
    if ! jq -n --arg id "${tx_dir##*/}" --arg target_digest "$target_digest" \
        --arg commit "$current_commit" --arg manifest_digest "$manifest_digest" \
        --arg modes_digest "$modes_digest" --arg now "$now" '
        {
            version: 1,
            transaction_id: $id,
            target_scope: "target-home",
            target_home_digest: $target_digest,
            current_commit: $commit,
            manifest_sha256: $manifest_digest,
            file_modes_sha256: $modes_digest,
            owned_after_sha256: null,
            services_sha256: null,
            created_at: $now
        }
    ' > "$checkpoint_tmp/checkpoint.json"; then
        rm -rf -- "$checkpoint_tmp"
        return 1
    fi
    chmod 0600 -- "$checkpoint_tmp/checkpoint.json" || {
        rm -rf -- "$checkpoint_tmp"
        return 1
    }
    mv -- "$checkpoint_tmp" "$checkpoint" || {
        rm -rf -- "$checkpoint_tmp"
        return 1
    }
    if ! maintenance_journal_update "$tx_dir" '
        .recovery.configuration = "ready" |
        .updated_at = $now
    ' --arg now "$now"; then
        rm -rf -- "$checkpoint"
        return 1
    fi
}

_recovery_manifest_validate() {
    local manifest=$1 runtime=$2 line type relative detail extra previous=''

    while IFS= read -r line; do
        [[ -n $line ]] || return 1
        IFS=$'\t' read -r type relative detail extra <<< "$line"
        [[ -z ${extra:-} ]] || return 1
        recovery_validate_relative "$relative" || return 1
        [[ -z $previous || $relative > $previous ]] || return 1
        previous=$relative
        case $type in
            file) [[ $detail =~ ^[0-9a-f]{64}$ ]] || return 1 ;;
            symlink)
                [[ -n $detail && $detail != *$'\t'* && $detail != *$'\n'* ]] || return 1
                ;;
            missing|directory-owned) [[ $detail == - ]] || return 1 ;;
            *) return 1 ;;
        esac
        _recovery_backup_matches "$runtime" "$type" "$relative" "$detail" || return 1
    done < "$manifest"
    [[ -n $previous ]]
}

_recovery_services_validate() {
    local services=$1 unit before after extra count=0 expected

    while IFS=$'\t' read -r unit before after extra; do
        [[ -z ${extra:-} ]] || return 1
        case $unit in
            myhypr-session.target|elephant.service|walker.service) ;;
            *) return 1 ;;
        esac
        [[ $before == active || $before == inactive ]] || return 1
        [[ $after == pending || $after == active || $after == inactive ]] || return 1
        count=$((count + 1))
    done < "$services"
    [[ $count -eq 3 ]] || return 1
    for expected in myhypr-session.target elephant.service walker.service; do
        [[ $(awk -F '\t' -v unit="$expected" '$1 == unit { count++ } END { print count + 0 }' \
            "$services") -eq 1 ]] || return 1
    done
}

_recovery_modes_validate() {
    local manifest=$1 modes=$2 type relative detail extra mode previous=''
    local -A expected=() observed=()

    while IFS=$'\t' read -r type relative detail extra; do
        [[ -z ${extra:-} ]] || return 1
        [[ $type == file ]] && expected["$relative"]=1
    done < "$manifest"
    while IFS=$'\t' read -r relative mode extra; do
        [[ -z ${extra:-} ]] || return 1
        recovery_validate_relative "$relative" || return 1
        [[ $mode =~ ^[0-7]{3}$ ]] || return 1
        [[ -n ${expected[$relative]+x} && -z ${observed[$relative]+x} ]] || return 1
        [[ -z $previous || $relative > $previous ]] || return 1
        previous=$relative
        observed["$relative"]=$mode
    done < "$modes"
    [[ ${#expected[@]} -eq ${#observed[@]} ]]
}

_recovery_checkpoint_validate() {
    local tx_dir=$1 repo_root=$2 target_home=$3 checkpoint metadata manifest runtime
    local services modes target_digest manifest_digest modes_digest current_commit

    _recovery_context_validate "$tx_dir" "$repo_root" "$target_home" || return 1
    tx_dir=$_RECOVERY_TX_DIR
    checkpoint="$tx_dir/checkpoint"
    _maintenance_validate_private_directory "$checkpoint" || return 1
    metadata="$checkpoint/checkpoint.json"
    manifest="$checkpoint/manifest.tsv"
    runtime="$checkpoint/runtime"
    services="$checkpoint/user-services.tsv"
    modes="$checkpoint/file-modes.tsv"
    _maintenance_validate_owned_file "$metadata" || return 1
    _maintenance_validate_owned_file "$manifest" || return 1
    _maintenance_validate_owned_file "$checkpoint/missing.txt" || return 1
    _maintenance_validate_owned_file "$checkpoint/managed-links.tsv" || return 1
    _maintenance_validate_owned_file "$services" || return 1
    _maintenance_validate_owned_file "$modes" || return 1
    _maintenance_validate_private_directory "$runtime" || return 1
    target_digest=$(_recovery_sha256_text "$_RECOVERY_TARGET_HOME") || return 1
    manifest_digest=$(sha256sum "$manifest" | cut -d' ' -f1) || return 1
    modes_digest=$(sha256sum "$modes" | cut -d' ' -f1) || return 1
    current_commit=$(jq -er '.current_commit | select(type == "string")' \
        "$tx_dir/journal.json" 2>/dev/null) || return 1
    jq -e --arg id "${tx_dir##*/}" --arg target_digest "$target_digest" \
        --arg manifest_digest "$manifest_digest" --arg modes_digest "$modes_digest" \
        --arg commit "$current_commit" '
        .version == 1 and .transaction_id == $id and
        .target_scope == "target-home" and
        .target_home_digest == $target_digest and
        .current_commit == $commit and
        .manifest_sha256 == $manifest_digest and
        .file_modes_sha256 == $modes_digest and
        (.created_at | type == "string") and
        (keys | sort) == ([
            "created_at","current_commit","file_modes_sha256","manifest_sha256",
            "owned_after_sha256","services_sha256","target_home_digest","target_scope",
            "transaction_id","version"
        ] | sort)
    ' "$metadata" >/dev/null || return 1
    _recovery_manifest_validate "$manifest" "$runtime" || return 1
    _recovery_modes_validate "$manifest" "$modes" || return 1
    _recovery_services_validate "$services" || return 1
    _RECOVERY_CHECKPOINT=$checkpoint
}

recovery_capture_owned_state() {
    local tx_dir=${1:-} repo_root=${2:-} target_home=${3:-}
    local manifest owned next_owned services next_services type relative detail extra
    local unit before after service_state metadata next_metadata owned_digest services_digest

    _recovery_checkpoint_validate "$tx_dir" "$repo_root" "$target_home" || return 1
    tx_dir=$_RECOVERY_TX_DIR
    target_home=$_RECOVERY_TARGET_HOME
    manifest="$_RECOVERY_CHECKPOINT/manifest.tsv"
    services="$_RECOVERY_CHECKPOINT/user-services.tsv"
    metadata="$_RECOVERY_CHECKPOINT/checkpoint.json"
    owned="$tx_dir/owned-after.tsv"
    [[ ! -e $owned && ! -L $owned ]] || return 1
    next_owned=$(mktemp "$tx_dir/.owned-after.XXXXXXXX") || return 1
    next_services=$(mktemp "$_RECOVERY_CHECKPOINT/.services.XXXXXXXX") || {
        rm -f -- "$next_owned"
        return 1
    }
    chmod 0600 -- "$next_owned" "$next_services" || {
        rm -f -- "$next_owned" "$next_services"
        return 1
    }
    while IFS=$'\t' read -r type relative detail extra; do
        [[ -z ${extra:-} ]] || {
            rm -f -- "$next_owned" "$next_services"
            return 1
        }
        if ! _recovery_capture_state "$target_home" "$relative"; then
            rm -f -- "$next_owned" "$next_services"
            return 1
        fi
        printf '%s\t%s\t%s\n' "$_RECOVERY_CAPTURE_TYPE" "$relative" \
            "$_RECOVERY_CAPTURE_DETAIL" >> "$next_owned"
    done < "$manifest"
    while IFS=$'\t' read -r unit before after extra; do
        [[ -z ${extra:-} && $after == pending ]] || {
            rm -f -- "$next_owned" "$next_services"
            return 1
        }
        service_state=$(_recovery_service_state "$unit") || {
            rm -f -- "$next_owned" "$next_services"
            return 1
        }
        printf '%s\t%s\t%s\n' "$unit" "$before" "$service_state" >> "$next_services"
    done < "$services"
    owned_digest=$(sha256sum "$next_owned" | cut -d' ' -f1) || {
        rm -f -- "$next_owned" "$next_services"
        return 1
    }
    services_digest=$(sha256sum "$next_services" | cut -d' ' -f1) || {
        rm -f -- "$next_owned" "$next_services"
        return 1
    }
    next_metadata=$(mktemp "$_RECOVERY_CHECKPOINT/.checkpoint.XXXXXXXX") || {
        rm -f -- "$next_owned" "$next_services"
        return 1
    }
    if ! jq --arg owned_digest "$owned_digest" --arg services_digest "$services_digest" '
        .owned_after_sha256 = $owned_digest |
        .services_sha256 = $services_digest
    ' "$metadata" > "$next_metadata"; then
        rm -f -- "$next_owned" "$next_services" "$next_metadata"
        return 1
    fi
    chmod 0600 -- "$next_metadata" || {
        rm -f -- "$next_owned" "$next_services" "$next_metadata"
        return 1
    }
    mv -- "$next_services" "$services" || {
        rm -f -- "$next_owned" "$next_services" "$next_metadata"
        return 1
    }
    mv -- "$next_owned" "$owned" || {
        rm -f -- "$next_owned" "$next_metadata"
        return 1
    }
    mv -- "$next_metadata" "$metadata" || {
        rm -f -- "$next_metadata"
        return 1
    }
}

_recovery_record_matches_current() {
    local target_home=$1 type=$2 relative=$3 detail=$4

    _recovery_capture_state "$target_home" "$relative" || return 1
    [[ $_RECOVERY_CAPTURE_TYPE == "$type" && $_RECOVERY_CAPTURE_DETAIL == "$detail" ]]
}

_recovery_restore_backup() {
    local checkpoint=$1 target_home=$2 relative=$3 mode=${4:-}
    local parent backup temporary

    parent=$(dirname -- "$target_home/$relative")
    [[ -d $parent && ! -L $parent ]] || return 1
    backup="$checkpoint/runtime/$relative"
    temporary=$(mktemp -d "$parent/.myhypr-restore.XXXXXXXX") || return 1
    chmod 0700 -- "$temporary" || {
        rmdir -- "$temporary" 2>/dev/null || true
        return 1
    }
    if ! rsync -a -- "$backup" "$temporary/item"; then
        rm -rf -- "$temporary"
        return 1
    fi
    if [[ -n $mode ]] && ! chmod "$mode" -- "$temporary/item"; then
        rm -rf -- "$temporary"
        return 1
    fi
    if ! mv -T -- "$temporary/item" "$target_home/$relative"; then
        rm -rf -- "$temporary"
        return 1
    fi
    rmdir -- "$temporary" 2>/dev/null || true
}

_recovery_attention_add() {
    local output=$1 relative=$2 reason=$3

    recovery_validate_relative "$relative" || return 1
    _maintenance_safe_class "$reason" || return 1
    printf '%s\t%s\n' "$relative" "$reason" >> "$output"
}

recovery_checkpoint_restore() {
    local tx_dir=${1:-} repo_root=${2:-} target_home=${3:-}
    local manifest owned services attention next_attention type relative detail extra
    local after_type after_detail issue_count=0 unit before after current action
    local owned_digest services_digest
    local modes mode
    local -A original_types=() after_types=() after_details=() original_modes=()

    _recovery_checkpoint_validate "$tx_dir" "$repo_root" "$target_home" || return 1
    tx_dir=$_RECOVERY_TX_DIR
    target_home=$_RECOVERY_TARGET_HOME
    manifest="$_RECOVERY_CHECKPOINT/manifest.tsv"
    services="$_RECOVERY_CHECKPOINT/user-services.tsv"
    modes="$_RECOVERY_CHECKPOINT/file-modes.tsv"
    owned="$tx_dir/owned-after.tsv"
    attention="$tx_dir/needs-attention.txt"
    _maintenance_validate_owned_file "$owned" || return 1
    owned_digest=$(sha256sum "$owned" | cut -d' ' -f1) || return 1
    services_digest=$(sha256sum "$services" | cut -d' ' -f1) || return 1
    jq -e --arg owned_digest "$owned_digest" --arg services_digest "$services_digest" '
        .owned_after_sha256 == $owned_digest and
        .services_sha256 == $services_digest
    ' "$_RECOVERY_CHECKPOINT/checkpoint.json" >/dev/null || return 1

    while IFS=$'\t' read -r type relative detail extra; do
        [[ -z ${extra:-} ]] || return 1
        original_types["$relative"]=$type
    done < "$manifest"
    while IFS=$'\t' read -r type relative detail extra; do
        [[ -z ${extra:-} && -n ${original_types[$relative]+x} ]] || return 1
        [[ -z ${after_types[$relative]+x} ]] || return 1
        case $type in
            file) [[ $detail =~ ^[0-9a-f]{64}$ ]] || return 1 ;;
            symlink) [[ -n $detail && $detail != *$'\t'* && $detail != *$'\n'* ]] || return 1 ;;
            missing|directory-owned) [[ $detail == - ]] || return 1 ;;
            *) return 1 ;;
        esac
        after_types["$relative"]=$type
        after_details["$relative"]=$detail
    done < "$owned"
    [[ ${#original_types[@]} -eq ${#after_types[@]} ]] || return 1
    while IFS=$'\t' read -r relative mode extra; do
        [[ -z ${extra:-} ]] || return 1
        original_modes["$relative"]=$mode
    done < "$modes"

    next_attention=$(mktemp "$tx_dir/.needs-attention.XXXXXXXX") || return 1
    chmod 0600 -- "$next_attention" || {
        rm -f -- "$next_attention"
        return 1
    }
    if [[ -e $attention || -L $attention ]]; then
        _maintenance_validate_owned_file "$attention" || {
            rm -f -- "$next_attention"
            return 1
        }
        cat -- "$attention" > "$next_attention" || {
            rm -f -- "$next_attention"
            return 1
        }
    fi

    while IFS=$'\t' read -r type relative detail extra; do
        after_type=${after_types[$relative]}
        after_detail=${after_details[$relative]}
        if _recovery_record_matches_current "$target_home" "$type" "$relative" "$detail"; then
            continue
        fi
        if ! _recovery_record_matches_current \
            "$target_home" "$after_type" "$relative" "$after_detail"; then
            _recovery_attention_add "$next_attention" "$relative" content-changed || {
                rm -f -- "$next_attention"
                return 1
            }
            issue_count=$((issue_count + 1))
            continue
        fi
        case $type in
            file|symlink)
                if [[ $after_type == directory-owned ]] || \
                    ! _recovery_restore_backup "$_RECOVERY_CHECKPOINT" \
                        "$target_home" "$relative" "${original_modes[$relative]:-}"; then
                    _recovery_attention_add "$next_attention" "$relative" \
                        restore-collision || {
                        rm -f -- "$next_attention"
                        return 1
                    }
                    issue_count=$((issue_count + 1))
                fi
                ;;
            missing)
                if [[ $after_type == file || $after_type == symlink ]]; then
                    rm -- "$target_home/$relative" || {
                        _recovery_attention_add "$next_attention" "$relative" \
                            remove-failed || {
                            rm -f -- "$next_attention"
                            return 1
                        }
                        issue_count=$((issue_count + 1))
                    }
                elif [[ $after_type != missing ]]; then
                    _recovery_attention_add "$next_attention" "$relative" \
                        directory-collision || {
                        rm -f -- "$next_attention"
                        return 1
                    }
                    issue_count=$((issue_count + 1))
                fi
                ;;
            directory-owned)
                _recovery_attention_add "$next_attention" "$relative" \
                    directory-collision || {
                    rm -f -- "$next_attention"
                    return 1
                }
                issue_count=$((issue_count + 1))
                ;;
        esac
    done < "$manifest"

    while IFS=$'\t' read -r unit before after extra; do
        [[ -z ${extra:-} && $after != pending ]] || {
            rm -f -- "$next_attention"
            return 1
        }
        current=$(_recovery_service_state "$unit") || {
            _recovery_attention_add "$next_attention" "service/$unit" \
                service-state-unavailable || {
                rm -f -- "$next_attention"
                return 1
            }
            issue_count=$((issue_count + 1))
            continue
        }
        [[ $current == "$before" ]] && continue
        if [[ $current != "$after" ]]; then
            _recovery_attention_add "$next_attention" "service/$unit" \
                service-state-changed || {
                rm -f -- "$next_attention"
                return 1
            }
            issue_count=$((issue_count + 1))
            continue
        fi
        [[ $before == active ]] && action=start || action=stop
        if ! systemctl --user "$action" "$unit" >/dev/null 2>&1 || \
            [[ $(_recovery_service_state "$unit") != "$before" ]]; then
            _recovery_attention_add "$next_attention" "service/$unit" \
                service-restore-failed || {
                rm -f -- "$next_attention"
                return 1
            }
            issue_count=$((issue_count + 1))
        fi
    done < "$services"

    if (( issue_count > 0 )); then
        LC_ALL=C sort -u -o "$next_attention" "$next_attention" || {
            rm -f -- "$next_attention"
            return 1
        }
        mv -- "$next_attention" "$attention" || {
            rm -f -- "$next_attention"
            return 1
        }
        maintenance_journal_update "$tx_dir" '
            .recovery.configuration = "needs-attention" |
            .updated_at = $now
        ' --arg now "$(timestamp)" || return 1
        return 1
    fi
    rm -f -- "$next_attention"
    rm -f -- "$attention"
    maintenance_journal_update "$tx_dir" '
        .recovery.configuration = "recovered" |
        .updated_at = $now
    ' --arg now "$(timestamp)"
}
