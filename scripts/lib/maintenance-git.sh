#!/usr/bin/env bash

# Prepare and promote an incoming Git revision without allowing candidate code
# to inherit the live desktop or privileged maintenance environment. This file
# is sourced after scripts/lib.sh and maintenance-transaction.sh.
# shellcheck disable=SC2016  # Single-quoted jq programs must not expand in Bash.

_maintenance_git_command() {
    command git "$@"
}

_maintenance_git_trusted_binary() {
    local name=${1:-} path resolved owner mode numeric_mode

    case $name in
        bwrap|env|setpriv|timeout) path="/usr/bin/$name" ;;
        *) return 1 ;;
    esac
    [[ -x $path && ! -L $path ]] || return 1
    resolved=$(realpath -e -- "$path" 2>/dev/null) || return 1
    [[ $resolved == "$path" ]] || return 1
    owner=$(stat -Lc %u -- "$path" 2>/dev/null) || return 1
    [[ $owner == 0 ]] || return 1
    mode=$(stat -Lc %a -- "$path" 2>/dev/null) || return 1
    [[ $mode =~ ^[0-7]{3,4}$ ]] || return 1
    numeric_mode=$((8#$mode))
    (( (numeric_mode & 0022) == 0 )) || return 1
    printf '%s\n' "$path"
}

_maintenance_git_validate_repo() {
    local requested=${1:-} canonical top

    [[ $requested == /* && -d $requested && ! -L $requested ]] || return 1
    _maintenance_validate_owned_directory "$requested" || return 1
    canonical=$(realpath -e -- "$requested" 2>/dev/null) || return 1
    [[ $canonical == "$requested" ]] || return 1
    top=$(_maintenance_git_command -C "$canonical" rev-parse --show-toplevel \
        2>/dev/null) || return 1
    top=$(realpath -e -- "$top" 2>/dev/null) || return 1
    [[ $top == "$canonical" ]] || return 1
    [[ $(_maintenance_git_command -C "$canonical" rev-parse \
        --is-inside-work-tree 2>/dev/null) == true ]] || return 1
    _MAINTENANCE_GIT_REPO=$canonical
}

_maintenance_git_context() {
    local tx_dir=${1:-} repo_root=${2:-}

    _maintenance_tx_require_active "$tx_dir" || {
        warn 'Git maintenance requires the active locked transaction.'
        return 1
    }
    _maintenance_git_validate_repo "$repo_root" || {
        warn 'The active Git repository path is not trusted.'
        return 1
    }
    _MAINTENANCE_GIT_TX_DIR=$_MAINTENANCE_VALIDATED_TX_DIR
}

_maintenance_git_clean() {
    local repo_root=$1 untracked

    _maintenance_git_command -C "$repo_root" diff --quiet || return 1
    _maintenance_git_command -C "$repo_root" diff --cached --quiet || return 1
    untracked=$(_maintenance_git_command -C "$repo_root" \
        ls-files --others --exclude-standard) || return 1
    [[ -z $untracked ]]
}

_maintenance_git_status_valid() {
    [[ ${1:-} == null || ${1:-} =~ ^([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$ ]]
}

_maintenance_git_write_evidence() {
    local tx_dir=$1 candidate=$2 trusted_scan=$3 audit_status=$4 quick_status=$5
    local next

    _maintenance_commit_value_valid "$candidate" && [[ -n $candidate ]] || return 1
    _maintenance_git_status_valid "$trusted_scan" || return 1
    _maintenance_git_status_valid "$audit_status" || return 1
    _maintenance_git_status_valid "$quick_status" || return 1
    next=$(mktemp "$tx_dir/.git.XXXXXXXX") || return 1
    if ! jq -n --arg id "${tx_dir##*/}" --arg candidate "$candidate" \
        --argjson trusted_scan "$trusted_scan" --argjson audit "$audit_status" \
        --argjson quick "$quick_status" '
        {
            version: 1,
            transaction_id: $id,
            candidate_commit: $candidate,
            checks: {
                trusted_scan: $trusted_scan,
                audit: $audit,
                quick: $quick
            }
        }
    ' > "$next"; then
        rm -f -- "$next"
        return 1
    fi
    chmod 0600 -- "$next" || {
        rm -f -- "$next"
        return 1
    }
    if ! mv -- "$next" "$tx_dir/git.json"; then
        rm -f -- "$next"
        return 1
    fi
}

_maintenance_git_record_candidate() {
    local tx_dir=$1 candidate=$2 now

    now=$(timestamp)
    maintenance_journal_update "$tx_dir" '
        .candidate_commit = $candidate |
        .updated_at = $now
    ' --arg candidate "$candidate" --arg now "$now"
}

_maintenance_git_tree_inventory() {
    local repo_root=$1 commit=$2 output=$3

    _maintenance_git_command -C "$repo_root" ls-tree -rz --full-tree \
        "$commit" > "$output"
}

_maintenance_git_verify_candidate_signature() {
    local repo_root=$1 current=$2 candidate=$3 tx_dir=$4
    local allowed_signers="$tx_dir/allowed-signers"

    # Anchor update authorization in the currently installed commit. Reading
    # this file from the candidate would let an untrusted update add its own key.
    if ! _maintenance_git_command -C "$repo_root" show \
        "$current:.config/git/allowed_signers" > "$allowed_signers"; then
        warn 'The trusted commit does not contain a Git signing allow-list.'
        return 65
    fi
    chmod 0600 -- "$allowed_signers" || return 1

    if ! _maintenance_git_command -C "$repo_root" \
        -c gpg.format=ssh \
        -c gpg.ssh.allowedSignersFile="$allowed_signers" \
        verify-commit "$candidate" >/dev/null 2>&1; then
        warn 'Incoming candidate is not signed by an authorized maintenance key.'
        return 65
    fi
}

_maintenance_git_sensitive_filename() {
    local path=${1,,}

    case $path in
        *.env.example|*.env.*.example|*.example) return 1 ;;
        .env|.env.*|*/.env|*/.env.*|id_rsa|*/id_rsa|id_ed25519|*/id_ed25519|\
            *.pem|*.key|*.p12|*.pfx|*.kdbx|credentials|credentials.*|\
            */credentials|*/credentials.*|secrets/*|*/secrets/*) return 0 ;;
        *) return 1 ;;
    esac
}

_maintenance_git_active_content_path() {
    local path=${1,,} mode=${2:-}

    # Plain documentation may name prohibited commands while explaining the
    # policy. Executable documentation remains active and is scanned.
    if [[ $mode == 100644 ]]; then
        case ${path##*/} in
            readme|readme.*|notice|license|license.*|*.md|*.markdown|*.mdown|\
                *.rst|*.adoc) return 1 ;;
        esac
    fi
    return 0
}

_maintenance_git_blob_matches() {
    local repo_root=$1 object=$2 pattern=$3
    local -a statuses=()

    if _maintenance_git_command -C "$repo_root" cat-file blob "$object" | \
        rg -I -q --pcre2 "$pattern"; then
        statuses=("${PIPESTATUS[@]}")
    else
        statuses=("${PIPESTATUS[@]}")
    fi
    [[ ${statuses[0]} -eq 0 ]] || return 2
    case ${statuses[1]} in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

_maintenance_git_blob_has_generic_secret() {
    local repo_root=$1 object=$2 generic_pattern=$3 placeholder_pattern=$4
    local -a statuses=()

    if _maintenance_git_command -C "$repo_root" cat-file blob "$object" | \
        rg -I --pcre2 "$generic_pattern" | \
        rg -I -v -q --pcre2 "$placeholder_pattern"; then
        statuses=("${PIPESTATUS[@]}")
    else
        statuses=("${PIPESTATUS[@]}")
    fi
    [[ ${statuses[0]} -eq 0 ]] || return 2
    [[ ${statuses[1]} -eq 0 || ${statuses[1]} -eq 1 ]] || return 2
    case ${statuses[2]} in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

_maintenance_git_trusted_scan() {
    local tx_dir=$1 repo_root=$2 current=$3 candidate=$4
    local current_tree candidate_tree record metadata path mode type object size status target
    local high_confidence_pattern generic_secret_pattern placeholder_pattern
    local home_pattern network_tools shell_tools privilege_tools legacy_names
    local unsafe_pattern legacy_fetch_pattern
    declare -A reviewed_blobs=()

    command -v rg >/dev/null 2>&1 || {
        warn 'The trusted candidate scanner requires ripgrep.'
        return 69
    }
    current_tree=$(mktemp "$tx_dir/.git-current-tree.XXXXXXXX") || return 1
    candidate_tree=$(mktemp "$tx_dir/.git-candidate-tree.XXXXXXXX") || {
        rm -f -- "$current_tree"
        return 1
    }
    if ! _maintenance_git_tree_inventory "$repo_root" "$current" "$current_tree" || \
        ! _maintenance_git_tree_inventory "$repo_root" "$candidate" "$candidate_tree"; then
        rm -f -- "$current_tree" "$candidate_tree"
        warn 'The trusted candidate tree inventory failed.'
        return 74
    fi

    while IFS= read -r -d '' record; do
        metadata=${record%%$'\t'*}
        path=${record#*$'\t'}
        IFS=' ' read -r mode type object <<< "$metadata"
        if [[ $type == blob && $object =~ ^[0-9a-f]{40,64}$ ]]; then
            reviewed_blobs["$path"]=$object
        fi
    done < "$current_tree"

    high_confidence_pattern='(BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE'
    high_confidence_pattern+=' KEY|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|'
    high_confidence_pattern+='gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|'
    high_confidence_pattern+='sk-[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})'
    generic_secret_pattern='(?i:(api[_-]?key|access[_-]?token|auth[_-]?token|'
    generic_secret_pattern+='client[_-]?secret|password|passwd))[[:space:]]*[:=]'
    generic_secret_pattern+='[[:space:]]*[\x22\x27]?[^$<{[:space:]\x22\x27]'
    generic_secret_pattern+='[^\x22\x27[:space:]]{7,}'
    placeholder_pattern='(?i:(example|placeholder|change.?me|replace|redacted|dummy|'
    placeholder_pattern+='your.{0,16}(api.?key|key)))'
    home_pattern='/home/(?!(?:user|example|username)\b)[A-Za-z0-9._-]+'
    network_tools='(cu'
    network_tools+='rl|wg'
    network_tools+='et)'
    shell_tools='(sh|ba'
    shell_tools+='sh|zsh)'
    privilege_tools='(su'
    privilege_tools+='do|pke'
    privilege_tools+='xec)'
    legacy_names='(ml'
    legacy_names+='4w|mylinuxfor'
    legacy_names+='work)'
    unsafe_pattern="credential\\.helper[[:space:]]+store|chmod[[:space:]]+777|"
    unsafe_pattern+="${network_tools}[^\n|]{0,512}\\|[[:space:]]*${shell_tools}|"
    unsafe_pattern+="${shell_tools}[[:space:]]+<\\([^\n]{0,128}${network_tools}|"
    unsafe_pattern+="${privilege_tools}[[:space:]]+${shell_tools}([[:space:]]+-c)?|"
    unsafe_pattern+="${privilege_tools}[^\n]{0,128}${network_tools}"
    legacy_fetch_pattern="(${network_tools}|git[[:space:]]+clone|"
    legacy_fetch_pattern+="flatpak[[:space:]]+remote-add)[^\n]{0,512}${legacy_names}"

    status=0
    while IFS= read -r -d '' record; do
        metadata=${record%%$'\t'*}
        path=${record#*$'\t'}
        IFS=' ' read -r mode type object <<< "$metadata"
        if [[ -z $path || $path =~ [[:cntrl:]] || $path == /* || \
            $path == ../* || $path == */../* || $path == */.. ]]; then
            warn 'The candidate contains an unsafe tracked path.'
            status=65
            break
        fi
        if _maintenance_git_sensitive_filename "$path"; then
            warn 'The candidate contains a sensitive filename class.'
            status=65
            break
        fi
        if [[ $type != blob || ! $object =~ ^[0-9a-f]{40,64}$ || \
            ! $mode =~ ^100(644|755)$|^120000$ ]]; then
            warn 'The candidate contains an unsupported tracked object.'
            status=65
            break
        fi
        if [[ $mode == 120000 ]]; then
            target=$(_maintenance_git_command -C "$repo_root" cat-file blob \
                "$object") || {
                status=74
                break
            }
            if [[ -z $target || $target == /* || $target =~ [[:cntrl:]] || \
                /$target/ == *'/../'* || /$target/ == *'/./'* ]]; then
                warn 'The candidate contains an unsafe symbolic-link target.'
                status=65
                break
            fi
        fi
        size=$(_maintenance_git_command -C "$repo_root" cat-file -s "$object") || {
            status=74
            break
        }
        if ((size > 10 * 1024 * 1024)) && \
            [[ ${reviewed_blobs[$path]-} != "$object" ]]; then
            warn 'The candidate contains an unreviewed large file.'
            status=65
            break
        fi
        # The active commit is the trusted baseline for this transaction.
        # Re-scan every new or changed blob while allowing byte-identical
        # documentation and fixtures whose safety wording names a banned
        # pattern. Paths, object types, modes, links, and sizes remain checked
        # for the complete candidate tree above.
        if [[ ${reviewed_blobs[$path]-} == "$object" ]]; then
            continue
        fi

        if _maintenance_git_blob_matches "$repo_root" "$object" \
            "$high_confidence_pattern"; then
            warn 'The candidate contains a high-confidence secret signature.'
            status=65
            break
        else
            case $? in 1) ;; *) status=74; break ;; esac
        fi
        if _maintenance_git_blob_has_generic_secret "$repo_root" "$object" \
            "$generic_secret_pattern" "$placeholder_pattern"; then
            warn 'The candidate contains an unredacted credential pattern.'
            status=65
            break
        else
            case $? in 1) ;; *) status=74; break ;; esac
        fi
        if _maintenance_git_blob_matches "$repo_root" "$object" "$home_pattern"; then
            warn 'The candidate contains a machine-specific home path.'
            status=65
            break
        else
            case $? in 1) ;; *) status=74; break ;; esac
        fi
        if _maintenance_git_active_content_path "$path" "$mode"; then
            if _maintenance_git_blob_matches "$repo_root" "$object" \
                "$unsafe_pattern"; then
                warn 'The candidate contains an unsafe privilege or bootstrap pattern.'
                status=65
                break
            else
                case $? in 1) ;; *) status=74; break ;; esac
            fi
            if _maintenance_git_blob_matches "$repo_root" "$object" \
                "$legacy_fetch_pattern"; then
                warn 'The candidate contains an active legacy dependency fetch.'
                status=65
                break
            else
                case $? in 1) ;; *) status=74; break ;; esac
            fi
        fi
    done < "$candidate_tree"

    rm -f -- "$current_tree" "$candidate_tree"
    if [[ $status -eq 74 ]]; then
        warn 'The trusted candidate content scan could not be completed.'
    fi
    return "$status"
}

_maintenance_git_prepare_environment() {
    local tx_dir=$1 root directory

    root="$tx_dir/candidate-environment"

    [[ ! -e $root && ! -L $root ]] || return 1
    mkdir -m 0700 -- "$root" || return 1
    for directory in home config state cache run; do
        mkdir -m 0700 -- "$root/$directory" || return 1
    done
    _MAINTENANCE_GIT_ENV_ROOT=$root
}

_maintenance_git_sandbox_parent_dirs() {
    local requested=$1 args_name=$2 seen_name=$3 parent
    local -a parents=()
    local -n _sandbox_args_ref=$args_name _seen_paths_ref=$seen_name

    parent=$(dirname -- "$requested")
    while [[ $parent != / ]]; do
        parents=("$parent" "${parents[@]}")
        parent=$(dirname -- "$parent")
    done
    for parent in "${parents[@]}"; do
        case $parent in
            /usr|/etc|/proc|/dev|/tmp|/run) continue ;;
        esac
        [[ -z ${_seen_paths_ref[$parent]+x} ]] || continue
        _sandbox_args_ref+=(--dir "$parent")
        # shellcheck disable=SC2004  # Associative path key, not arithmetic.
        _seen_paths_ref["$parent"]=1
    done
}

_maintenance_git_run_candidate() {
    local candidate_root=$1 environment_root=$2 command_name=$3
    shift 3
    local entrypoint="$candidate_root/scripts/$command_name"
    local bwrap_bin env_bin setpriv_bin timeout_bin common_git
    local candidate_canonical env_canonical
    local parent_net_ns
    local -a sandbox_args=()
    # shellcheck disable=SC2034  # Passed by nameref to the path de-duplicator.
    declare -A sandbox_paths=()

    ((EUID != 0)) || return 77
    [[ -f $entrypoint && ! -L $entrypoint && -x $entrypoint ]] || return 126
    bwrap_bin=$(_maintenance_git_trusted_binary bwrap) || return 69
    env_bin=$(_maintenance_git_trusted_binary env) || return 69
    setpriv_bin=$(_maintenance_git_trusted_binary setpriv) || return 69
    timeout_bin=$(_maintenance_git_trusted_binary timeout) || return 69
    candidate_canonical=$(realpath -e -- "$candidate_root" 2>/dev/null) || return 74
    env_canonical=$(realpath -e -- "$environment_root" 2>/dev/null) || return 74
    [[ $candidate_canonical == "$candidate_root" && \
        $env_canonical == "$environment_root" ]] || return 74
    common_git=$(_maintenance_git_command -C "$candidate_root" \
        rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 74
    common_git=$(realpath -e -- "$common_git" 2>/dev/null) || return 74
    [[ -d $common_git && ! -L $common_git && $common_git != / ]] || return 74
    parent_net_ns=$(readlink /proc/self/ns/net 2>/dev/null) || return 74
    [[ $parent_net_ns =~ ^net:\[[0-9]+\]$ ]] || return 74

    sandbox_args=(
        --unshare-pid
        --unshare-ipc
        --unshare-uts
        --unshare-net
        --die-with-parent
        --new-session
        --ro-bind /usr /usr
        --symlink usr/bin /bin
        --symlink usr/bin /sbin
        --symlink usr/lib /lib
        --symlink usr/lib /lib64
        --ro-bind /etc /etc
        --proc /proc
        --dev /dev
        --tmpfs /tmp
        --tmpfs /run
        # Keep host user and package state hidden while presenting the empty
        # standard paths expected by clean-machine validation fixtures.
        --dir /home
        --dir /boot
        --dir /var
        --dir /var/lib
        --dir /var/lib/pacman
    )
    _maintenance_git_sandbox_parent_dirs "$candidate_root" sandbox_args sandbox_paths
    _maintenance_git_sandbox_parent_dirs "$environment_root" sandbox_args sandbox_paths
    _maintenance_git_sandbox_parent_dirs "$common_git" sandbox_args sandbox_paths
    sandbox_args+=(
        --ro-bind "$candidate_root" "$candidate_root"
        --ro-bind "$common_git" "$common_git"
        --bind "$environment_root" "$environment_root"
        --chdir "$candidate_root"
    )

    "$timeout_bin" --kill-after=5 300 "$bwrap_bin" "${sandbox_args[@]}" \
        "$setpriv_bin" --no-new-privs \
        "$env_bin" -i \
            HOME="$environment_root/home" \
            XDG_CONFIG_HOME="$environment_root/config" \
            XDG_STATE_HOME="$environment_root/state" \
            XDG_CACHE_HOME="$environment_root/cache" \
            XDG_RUNTIME_DIR="$environment_root/run" \
            PATH=/usr/bin:/bin \
            LANG=C.UTF-8 LC_ALL=C.UTF-8 \
            GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
            GIT_TERMINAL_PROMPT=0 \
            MYHYPR_PARENT_NET_NS="$parent_net_ns" \
            "$entrypoint" "$@" \
        </dev/null >/dev/null 2>&1
}

_maintenance_git_load_passed_evidence() {
    local tx_dir=$1 journal evidence
    local id current candidate journal_candidate

    journal="$tx_dir/journal.json"
    evidence="$tx_dir/git.json"

    _maintenance_validate_owned_file "$evidence" || return 1
    id=${tx_dir##*/}
    jq -e --arg id "$id" '
        .version == 1 and .transaction_id == $id and
        (.candidate_commit | type == "string" and test("^[0-9a-f]{40}$")) and
        .checks == {trusted_scan: 0, audit: 0, quick: 0} and
        (keys | sort) == (["candidate_commit","checks","transaction_id","version"] | sort)
    ' "$evidence" >/dev/null 2>&1 || return 1
    current=$(jq -er '.current_commit | select(type == "string")' "$journal") || return 1
    journal_candidate=$(jq -er '.candidate_commit | select(type == "string")' \
        "$journal") || return 1
    candidate=$(jq -er '.candidate_commit' "$evidence") || return 1
    _maintenance_commit_value_valid "$current" && [[ -n $current ]] || return 1
    [[ $candidate == "$journal_candidate" ]] || return 1
    _MAINTENANCE_GIT_CURRENT=$current
    _MAINTENANCE_GIT_CANDIDATE=$candidate
}

_maintenance_git_validate_candidate_worktree() {
    local tx_dir=$1 candidate=$2 path canonical top head

    path="$tx_dir/candidate"

    [[ -d $path && ! -L $path ]] || return 1
    canonical=$(realpath -e -- "$path" 2>/dev/null) || return 1
    [[ $canonical == "$tx_dir/candidate" ]] || return 1
    top=$(_maintenance_git_command -C "$canonical" rev-parse --show-toplevel \
        2>/dev/null) || return 1
    top=$(realpath -e -- "$top" 2>/dev/null) || return 1
    [[ $top == "$canonical" ]] || return 1
    head=$(_maintenance_git_command -C "$canonical" rev-parse HEAD 2>/dev/null) || return 1
    [[ $head == "$candidate" ]] || return 1
    _maintenance_git_clean "$canonical"
}

maintenance_git_prepare() {
    local tx_dir=${1:-} repo_root=${2:-} current candidate candidate_path
    local recorded_current scan_status audit_status=null quick_status=null

    _maintenance_git_context "$tx_dir" "$repo_root" || return 1
    tx_dir=$_MAINTENANCE_GIT_TX_DIR
    repo_root=$_MAINTENANCE_GIT_REPO
    _maintenance_git_clean "$repo_root" || {
        warn 'The active Git worktree is not clean.'
        return 1
    }
    GIT_TERMINAL_PROMPT=0 _maintenance_git_command -C "$repo_root" \
        fetch --prune --no-tags || {
        warn 'The configured Git upstream could not be fetched.'
        return 1
    }
    current=$(_maintenance_git_command -C "$repo_root" rev-parse HEAD \
        2>/dev/null) || return 1
    candidate=$(_maintenance_git_command -C "$repo_root" rev-parse '@{upstream}' \
        2>/dev/null) || {
        warn 'The active Git branch has no configured upstream.'
        return 1
    }
    _maintenance_commit_value_valid "$current" && [[ -n $current ]] || return 1
    _maintenance_commit_value_valid "$candidate" && [[ -n $candidate ]] || return 1
    [[ $(_maintenance_git_command -C "$repo_root" cat-file -t "$candidate" \
        2>/dev/null) == commit ]] || return 1
    _maintenance_git_verify_candidate_signature \
        "$repo_root" "$current" "$candidate" "$tx_dir" || return $?
    recorded_current=$(jq -er '.current_commit | select(type == "string")' \
        "$tx_dir/journal.json" 2>/dev/null) || return 1
    [[ $recorded_current == "$current" ]] || {
        warn 'The active Git object differs from the transaction plan.'
        return 1
    }
    _maintenance_git_command -C "$repo_root" merge-base --is-ancestor \
        "$current" "$candidate" || {
        warn 'The configured Git upstream is not a fast-forward update.'
        return 1
    }
    candidate_path="$tx_dir/candidate"
    [[ ! -e $candidate_path && ! -L $candidate_path ]] || {
        warn 'The transaction candidate path already exists.'
        return 1
    }
    _maintenance_git_command -C "$repo_root" worktree add --detach \
        "$candidate_path" "$candidate" >/dev/null || return 1
    if ! _maintenance_git_record_candidate "$tx_dir" "$candidate"; then
        _maintenance_git_command -C "$repo_root" worktree remove --force \
            "$candidate_path" >/dev/null 2>&1 || true
        return 1
    fi

    if _maintenance_git_trusted_scan "$tx_dir" "$repo_root" "$current" \
        "$candidate"; then
        scan_status=0
    else
        scan_status=$?
        _maintenance_git_write_evidence "$tx_dir" "$candidate" \
            "$scan_status" null null || return 74
        return "$scan_status"
    fi
    _maintenance_git_prepare_environment "$tx_dir" || {
        _maintenance_git_write_evidence "$tx_dir" "$candidate" 0 74 null || return 74
        return 74
    }
    if _maintenance_git_run_candidate "$candidate_path" \
        "$_MAINTENANCE_GIT_ENV_ROOT" audit.sh --history; then
        audit_status=0
    else
        audit_status=$?
        _maintenance_git_write_evidence "$tx_dir" "$candidate" 0 \
            "$audit_status" null || return 74
        warn 'Incoming candidate publication audit failed.'
        return "$audit_status"
    fi
    if _maintenance_git_run_candidate "$candidate_path" \
        "$_MAINTENANCE_GIT_ENV_ROOT" check.sh --quick; then
        quick_status=0
    else
        quick_status=$?
        _maintenance_git_write_evidence "$tx_dir" "$candidate" 0 0 \
            "$quick_status" || return 74
        warn 'Incoming candidate quick validation failed.'
        return "$quick_status"
    fi
    _maintenance_git_write_evidence "$tx_dir" "$candidate" 0 0 0
}

maintenance_git_promote() {
    local tx_dir=${1:-} repo_root=${2:-} active upstream

    _maintenance_git_context "$tx_dir" "$repo_root" || return 1
    tx_dir=$_MAINTENANCE_GIT_TX_DIR
    repo_root=$_MAINTENANCE_GIT_REPO
    _maintenance_git_load_passed_evidence "$tx_dir" || {
        warn 'The transaction has no passed Git candidate evidence.'
        return 1
    }
    _maintenance_git_clean "$repo_root" || {
        warn 'The active Git worktree changed after candidate validation.'
        return 1
    }
    active=$(_maintenance_git_command -C "$repo_root" rev-parse HEAD \
        2>/dev/null) || return 1
    [[ $active == "$_MAINTENANCE_GIT_CURRENT" ]] || {
        warn 'The active Git object changed after candidate validation.'
        return 1
    }
    upstream=$(_maintenance_git_command -C "$repo_root" rev-parse '@{upstream}' \
        2>/dev/null) || return 1
    [[ $upstream == "$_MAINTENANCE_GIT_CANDIDATE" ]] || {
        warn 'The configured Git upstream changed after candidate validation.'
        return 1
    }
    _maintenance_git_command -C "$repo_root" merge-base --is-ancestor \
        "$_MAINTENANCE_GIT_CURRENT" "$_MAINTENANCE_GIT_CANDIDATE" || return 1
    _maintenance_git_validate_candidate_worktree "$tx_dir" \
        "$_MAINTENANCE_GIT_CANDIDATE" || {
        warn 'The validated candidate worktree changed before promotion.'
        return 1
    }
    _maintenance_git_command -C "$repo_root" merge --ff-only \
        "$_MAINTENANCE_GIT_CANDIDATE" >/dev/null || return 1
    [[ $(_maintenance_git_command -C "$repo_root" rev-parse HEAD) == \
        "$_MAINTENANCE_GIT_CANDIDATE" ]]
}

maintenance_git_restore_previous() {
    local tx_dir=${1:-} repo_root=${2:-} active

    _maintenance_git_context "$tx_dir" "$repo_root" || return 1
    tx_dir=$_MAINTENANCE_GIT_TX_DIR
    repo_root=$_MAINTENANCE_GIT_REPO
    _maintenance_git_load_passed_evidence "$tx_dir" || return 1
    active=$(_maintenance_git_command -C "$repo_root" rev-parse HEAD \
        2>/dev/null) || return 1
    [[ $active == "$_MAINTENANCE_GIT_CANDIDATE" ]] || {
        warn 'Git restore needs attention because active HEAD is no longer transaction-owned.'
        return 1
    }
    if ! _maintenance_git_command -C "$repo_root" reset --keep \
        "$_MAINTENANCE_GIT_CURRENT" >/dev/null 2>&1; then
        warn 'Git restore needs attention because local files collide.'
        return 1
    fi
    [[ $(_maintenance_git_command -C "$repo_root" rev-parse HEAD) == \
        "$_MAINTENANCE_GIT_CURRENT" ]]
}

_maintenance_git_worktree_registration_state() {
    local tx_dir=$1 repo_root=$2 requested=$3 inventory line state=1

    inventory=$(mktemp "$tx_dir/.git-worktrees.XXXXXXXX") || return 2
    if ! _maintenance_git_command -C "$repo_root" worktree list --porcelain \
        > "$inventory"; then
        rm -f -- "$inventory"
        return 2
    fi
    while IFS= read -r line; do
        if [[ $line == "worktree $requested" ]]; then
            state=0
            break
        fi
    done < "$inventory"
    rm -f -- "$inventory"
    return "$state"
}

maintenance_git_cleanup() {
    local tx_dir=${1:-} repo_root=${2:-} candidate_path canonical registration_status

    _maintenance_git_context "$tx_dir" "$repo_root" || return 1
    tx_dir=$_MAINTENANCE_GIT_TX_DIR
    repo_root=$_MAINTENANCE_GIT_REPO
    candidate_path="$tx_dir/candidate"
    if [[ ! -e $candidate_path && ! -L $candidate_path ]]; then
        if _maintenance_git_worktree_registration_state "$tx_dir" "$repo_root" \
            "$candidate_path"; then
            _maintenance_git_command -C "$repo_root" worktree remove --force \
                "$candidate_path" >/dev/null || return 1
            if _maintenance_git_worktree_registration_state "$tx_dir" "$repo_root" \
                "$candidate_path"; then
                return 1
            else
                registration_status=$?
                [[ $registration_status -eq 1 ]]
                return
            fi
        else
            registration_status=$?
            [[ $registration_status -eq 1 ]]
            return
        fi
    fi
    [[ -d $candidate_path && ! -L $candidate_path ]] || {
        warn 'Candidate cleanup refused a non-directory or symlink path.'
        return 1
    }
    canonical=$(realpath -e -- "$candidate_path" 2>/dev/null) || return 1
    [[ $canonical == "$tx_dir/candidate" ]] || {
        warn 'Candidate cleanup refused a path outside its transaction.'
        return 1
    }
    [[ $(realpath -e -- "$tx_dir" 2>/dev/null) == "${canonical%/candidate}" ]] || \
        return 1
    _maintenance_git_command -C "$canonical" rev-parse --is-inside-work-tree \
        >/dev/null 2>&1 || return 1
    _maintenance_git_command -C "$repo_root" worktree remove --force \
        "$canonical" >/dev/null || return 1
    [[ ! -e $candidate_path && ! -L $candidate_path ]] || return 1
    if _maintenance_git_worktree_registration_state "$tx_dir" "$repo_root" \
        "$candidate_path"; then
        return 1
    else
        registration_status=$?
    fi
    [[ $registration_status -eq 1 ]]
}
