#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

MODE=worktree
RUN_HISTORY=0

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

if [[ $MODE == staged ]]; then
    mapfile -d '' files < <(git diff --cached --name-only -z --diff-filter=ACMR)
else
    mapfile -d '' files < <(git ls-files -z --cached --others --exclude-standard)
    existing_files=()
    for file in "${files[@]}"; do
        [[ -e $file || -L $file ]] && existing_files+=("$file")
    done
    files=("${existing_files[@]}")
fi

if ((${#files[@]} == 0)); then
    success 'Nothing to audit.'
    exit 0
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

for file in "${files[@]}"; do
    lower_file=${file,,}
    case $lower_file in
        *.env.example|*.example) ;;
        */.env|*/.env.*|.env|.env.*|*/id_rsa|*/id_ed25519|*.pem|*.key|*.p12|*.pfx|*.kdbx|*/credentials|*/credentials.*|*/secrets/*)
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
    if read_file "$file" | rg -I -q --pcre2 "$high_confidence_pattern" || \
        read_file "$file" | rg -I --pcre2 "$generic_secret_pattern" | \
            rg -I -v -q --pcre2 "$placeholder_pattern"; then
        warn "Potential secret content detected in: $file"
        failures=$((failures + 1))
    fi
    if read_file "$file" | rg -I -q --pcre2 "$home_pattern"; then
        warn "Machine-specific absolute home path detected in: $file"
        failures=$((failures + 1))
    fi
    if [[ $file != scripts/audit.sh ]] && read_file "$file" | rg -I -q -e "$unsafe_pattern"; then
        warn "Unsafe dotfiles pattern detected in: $file"
        failures=$((failures + 1))
    fi
done

if [[ $MODE == staged ]]; then
    while IFS= read -r -d '' file; do
        size=$(git cat-file -s ":$file")
        if ((size > 10 * 1024 * 1024)); then
            warn "New file exceeds 10 MiB; use Git LFS or document an exception: $file"
            failures=$((failures + 1))
        fi
    done < <(git diff --cached --name-only -z --diff-filter=A)
fi

gitleaks_works() {
    local synthetic_token result
    synthetic_token="github_pat_$(printf 'A%.0s' {1..82})"
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
        warn 'Gitleaks failed its synthetic-secret self-test; using the built-in scanner only.'
    fi
else
    warn 'Gitleaks is unavailable; the built-in signature scan was used.'
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
    while read -r object path; do
        [[ -n ${path:-} ]] || continue
        [[ -z ${scanned_blobs[$object]+x} ]] || continue
        [[ $(git cat-file -t "$object" 2>/dev/null) == blob ]] || continue
        scanned_blobs[$object]=1

        lower_path=${path,,}
        case $lower_path in
            *.env.example|*.example) ;;
            */.env|*/.env.*|.env|.env.*|*/id_rsa|*/id_ed25519|*.pem|*.key|*.p12|*.pfx|*.kdbx|*/credentials|*/credentials.*|*/secrets/*)
                warn "Sensitive filename exists in Git history: $path"
                history_findings=$((history_findings + 1))
                ;;
        esac

        if git cat-file blob "$object" | rg -I -q --pcre2 "$high_confidence_pattern" || \
            git cat-file blob "$object" | rg -I --pcre2 "$generic_secret_pattern" | \
                rg -I -v -q --pcre2 "$placeholder_pattern"; then
            warn "Potential secret content exists in Git history: $path"
            history_findings=$((history_findings + 1))
        fi
    done < <(git rev-list --objects --all)
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

if ! "$SCRIPT_DIR/check.sh" --quick; then
    failures=$((failures + 1))
fi

if [[ $failures -gt 0 ]]; then
    die "$failures audit finding(s) must be resolved before committing."
fi
success "Privacy and security audit passed for ${#files[@]} file(s)."
