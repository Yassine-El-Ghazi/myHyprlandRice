#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

MODE=worktree
RUN_HISTORY=0
audit_snapshot=''
audit_workspace=''
cleanup() {
    case $audit_snapshot in
        "${TMPDIR:-/tmp}"/myhypr-audit-index.*) rm -rf -- "$audit_snapshot" ;;
    esac
    case $audit_workspace in
        "${TMPDIR:-/tmp}"/myhypr-audit-scan.*) rm -rf -- "$audit_workspace" ;;
    esac
}
trap cleanup EXIT

while (($#)); do
    case $1 in
        --staged)
            MODE=staged
            shift
            ;;
        --history)
            RUN_HISTORY=1
            shift
            ;;
        -h|--help)
            printf 'Usage: scripts/audit.sh [--staged] [--history]\n'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

cd -- "$REPO_ROOT"
require_command rg
require_command gitleaks
umask 077
audit_workspace=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-audit-scan.XXXXXXXX")
scan_file="$audit_workspace/content"

if [[ $MODE == staged ]]; then
    git diff --cached --name-only -z --diff-filter=ACMR > "$audit_workspace/files" || \
        die 'Unable to inventory staged files.'
else
    git ls-files -z --cached --others --exclude-standard > "$audit_workspace/files" || \
        die 'Unable to inventory worktree files.'
fi
mapfile -d '' files < "$audit_workspace/files"
if [[ $MODE != staged ]]; then
    existing_files=()
    for file in "${files[@]}"; do
        [[ -e $file || -L $file ]] && existing_files+=("$file")
    done
    files=("${existing_files[@]}")
fi

failures=0

read_file() {
    local file=$1
    if [[ $MODE == staged ]]; then
        git show ":$file"
    else
        command cat -- "$file"
    fi
}

# Do not use quiet/early-exit pipelines: consume the complete input and
# distinguish no matches (1) from an incomplete scan (any other failure).
scan_matches() {
    local status
    if rg -I --pcre2 -e "$1" -- "$scan_file" >/dev/null 2>&1; then
        return 0
    else
        status=$?
    fi
    [[ $status -eq 1 ]] || die 'Built-in content scanner failed.'
    return 1
}

scan_generic_secret() {
    local status
    local -a statuses=()
    if rg -I --pcre2 -e "$generic_secret_pattern" -- "$scan_file" 2>/dev/null | \
        rg -I -v --pcre2 -e "$placeholder_pattern" >/dev/null 2>&1; then
        statuses=("${PIPESTATUS[@]}")
    else
        statuses=("${PIPESTATUS[@]}")
    fi
    for status in "${statuses[@]}"; do
        [[ $status -eq 0 || $status -eq 1 ]] || die 'Built-in content scanner failed.'
    done
    [[ ${statuses[1]} -eq 0 ]]
}

run_quick_validation() {
    local git_local_env_output git_variable
    local -a git_local_env=()

    if [[ $MODE != staged ]]; then
        "$SCRIPT_DIR/check.sh" --quick
        return
    fi

    git_local_env_output=$(git rev-parse --local-env-vars) || return 1
    mapfile -t git_local_env <<< "$git_local_env_output" || return 1
    audit_snapshot=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-audit-index.XXXXXXXX") || \
        return 1
    case $audit_snapshot in
        "${TMPDIR:-/tmp}"/myhypr-audit-index.*) ;;
        *) return 1 ;;
    esac
    git checkout-index --all --prefix="$audit_snapshot/" || return 1
    (
        for git_variable in "${git_local_env[@]}"; do
            unset "$git_variable" || exit 1
        done
        cd -- "$audit_snapshot" || exit 1
        git init -q || exit 1
        git -c core.hooksPath=/dev/null add -A || exit 1
        "$audit_snapshot/scripts/check.sh" --quick || exit 1
    )
}

for file in "${files[@]}"; do
    lower_file=${file,,}
    case $lower_file in
        *.env.example|*.example) ;;
        */.env|*/.env.*|.env|.env.*|*/id_rsa|*/id_ed25519|*.pem|*.key|*.p12|*.pfx|*.kdbx|*/credentials|*/credentials.*|*/secrets/*|*/.config/fish/config.local.fish|*/.config/bashrc/custom/*|*/.config/zshrc/custom/*)
            warn "Sensitive filename must not be tracked: $file"
            failures=$((failures + 1))
            ;;
    esac
done

high_confidence_pattern='(BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})'
generic_secret_pattern='(?i:(api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|password|passwd))[[:space:]]*[:=][[:space:]]*[\x22\x27]?[^$<{[:space:]\x22\x27][^\x22\x27[:space:]]{7,}'
placeholder_pattern='(?i:(example|placeholder|change.?me|replace|redacted|dummy|your.{0,16}(api.?key|key)))'
home_pattern='/home/(?!(?:user|example|username)\b)[A-Za-z0-9._-]+'
unsafe_pattern='credential\.helper[[:space:]]+store|CYBENCH_ACKNOWLEDGE_RISKS[[:space:]]*=|chmod[[:space:]]+777'

for file in "${files[@]}"; do
    read_file "$file" > "$scan_file" 2>/dev/null || die 'Unable to read audit input.'
    if scan_matches "$high_confidence_pattern" || scan_generic_secret; then
        warn "Potential secret content detected in: $file"
        failures=$((failures + 1))
    fi
    if scan_matches "$home_pattern"; then
        warn "Machine-specific absolute home path detected in: $file"
        failures=$((failures + 1))
    fi
    if [[ $file != scripts/audit.sh ]] && scan_matches "$unsafe_pattern"; then
        warn "Unsafe dotfiles pattern detected in: $file"
        failures=$((failures + 1))
    fi
done

large_file_args=()
[[ $MODE != staged ]] || large_file_args+=(--staged)
if ! "$SCRIPT_DIR/audit-large-files.sh" "${large_file_args[@]}"; then
    failures=$((failures + 1))
fi

gitleaks_works() {
    local synthetic_token result
    # Build a deterministic fake AWS-shaped value at runtime so this file does
    # not contain a literal secret signature while still exercising Gitleaks.
    synthetic_token="AKIA$(printf '%s' QWERTYUIOPASDFGH)"
    set +e
    printf '%s\n' "$synthetic_token" | \
        gitleaks stdin --redact --no-banner >/dev/null 2>&1
    result=$?
    set -e
    [[ $result -eq 1 ]]
}

gitleaks_ready=0
if command -v gitleaks >/dev/null 2>&1; then
    if gitleaks_works; then
        gitleaks_ready=1
    else
        die 'Gitleaks failed its synthetic-secret self-test; audit incomplete.'
    fi
else
    die 'Gitleaks is unavailable; audit incomplete.'
fi

if [[ $gitleaks_ready -eq 1 ]]; then
    if [[ $MODE == staged ]]; then
        if ! gitleaks git --pre-commit --staged --redact --no-banner .; then
            warn 'Gitleaks reported a staged secret.'
            failures=$((failures + 1))
        fi
    elif ! gitleaks dir --redact --no-banner .; then
        warn 'Gitleaks reported a secret in the working tree.'
        failures=$((failures + 1))
    fi
fi

if [[ $RUN_HISTORY -eq 1 ]]; then
    info 'Scanning unique reachable Git blobs without printing their contents'
    declare -A scanned_blobs=()
    history_findings=0
    git rev-list --objects --all > "$audit_workspace/history" || \
        die 'Unable to inventory Git history.'
    while read -r object path; do
        [[ -n ${path:-} ]] || continue
        [[ -z ${scanned_blobs[$object]+x} ]] || continue
        object_type=$(git cat-file -t "$object" 2>/dev/null) || \
            die 'Unable to inspect Git history object.'
        [[ $object_type == blob ]] || continue
        scanned_blobs[$object]=1

        lower_path=${path,,}
        case $lower_path in
            *.env.example|*.example) ;;
            */.env|*/.env.*|.env|.env.*|*/id_rsa|*/id_ed25519|*.pem|*.key|*.p12|*.pfx|*.kdbx|*/credentials|*/credentials.*|*/secrets/*|*/.config/fish/config.local.fish|*/.config/bashrc/custom/*|*/.config/zshrc/custom/*)
                warn "Sensitive filename exists in Git history: $path"
                history_findings=$((history_findings + 1))
                ;;
        esac

        git cat-file blob "$object" > "$scan_file" 2>/dev/null || \
            die 'Unable to read Git history blob.'
        if scan_matches "$high_confidence_pattern" || scan_generic_secret; then
            warn "Potential secret content exists in Git history: $path"
            history_findings=$((history_findings + 1))
        fi
        if scan_matches "$home_pattern"; then
            warn "Machine-specific absolute home path exists in Git history: $path"
            history_findings=$((history_findings + 1))
        fi
        if [[ $path != scripts/audit.sh ]] && \
            scan_matches "$unsafe_pattern"; then
            warn "Unsafe dotfiles pattern exists in Git history: $path"
            history_findings=$((history_findings + 1))
        fi
    done < "$audit_workspace/history"
    failures=$((failures + history_findings))

    if [[ $gitleaks_ready -eq 1 ]]; then
        if ! gitleaks git --redact --no-banner --log-opts='--all' .; then
            warn 'Gitleaks reported a secret in Git history.'
            failures=$((failures + 1))
        fi
    fi
fi

if [[ $MODE == staged ]]; then
    git diff --cached --check || failures=$((failures + 1))
else
    git diff --check || failures=$((failures + 1))
fi

run_quick_validation

if [[ $failures -gt 0 ]]; then
    die "$failures audit finding(s) must be resolved before committing."
fi
success "Privacy and security audit passed for ${#files[@]} file(s)."
