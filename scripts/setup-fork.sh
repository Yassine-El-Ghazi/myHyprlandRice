#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

DRY_RUN=0
PUBLIC_KEY=''
PRINCIPAL=''

usage() {
    cat <<'EOF'
Usage: scripts/setup-fork.sh --public-key FILE [--principal EMAIL] [--dry-run]

Authorize your public SSH signing key for this fork and enable repository-local
commit signing. Existing trusted upstream keys are retained. The principal
defaults to your configured Git user.email. Commit the allow-list change before
using automatic updates. This command never generates or copies private keys.
EOF
}

while (($#)); do
    case $1 in
        --public-key)
            (($# >= 2)) || die '--public-key requires a public key file'
            PUBLIC_KEY=$2
            shift 2
            ;;
        --principal)
            (($# >= 2)) || die '--principal requires an identity'
            PRINCIPAL=$2
            shift 2
            ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ -n $PUBLIC_KEY ]] || die 'Choose your public signing key with --public-key FILE.'
require_command git
require_command ssh-keygen
require_command realpath
git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
    die 'Fork setup requires a Git checkout.'
PUBLIC_KEY=$(realpath -e -- "$PUBLIC_KEY") || die 'Public key file does not exist.'
[[ -f $PUBLIC_KEY ]] || die 'The public key must be a regular file.'
[[ $(stat -c %s -- "$PUBLIC_KEY") -le 16384 ]] || die 'Public key file is too large.'
mapfile -t key_lines < "$PUBLIC_KEY"
[[ ${#key_lines[@]} -eq 1 ]] || die 'Supply exactly one public SSH key.'
IFS=$' \t' read -r key_type key_data _ <<< "${key_lines[0]}"
case $key_type in
    ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|\
        sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ;;
    *) die 'Supply a public SSH key, not a private key or an authorized-keys rule.' ;;
esac
if [[ ! $key_data =~ ^[A-Za-z0-9+/]+={0,2}$ ]] ||
    ! ssh-keygen -lf "$PUBLIC_KEY" >/dev/null 2>&1; then
    die 'Invalid public SSH key.'
fi
[[ -n $PRINCIPAL ]] || PRINCIPAL=$(git -C "$REPO_ROOT" config --get user.email || true)
[[ $PRINCIPAL =~ ^[A-Za-z0-9][A-Za-z0-9@._+-]{0,253}$ ]] || \
    die 'Set Git user.email or pass --principal with a single literal identity.'

signers_dir="$REPO_ROOT/.config/git"
signers="$signers_dir/allowed_signers"
for path in "$REPO_ROOT/.config" "$signers_dir"; do
    [[ ! -L $path && ( ! -e $path || ( -d $path && -O $path ) ) ]] || \
        die 'The fork trust directory must be an owned directory, not a link.'
done
[[ ! -L $signers && ( ! -e $signers || ( -f $signers && -O $signers ) ) ]] || \
    die 'The fork allow-list must be an owned regular file, not a link.'

already_trusted=0
if [[ -f $signers ]] && awk -v principal="$PRINCIPAL" -v type="$key_type" -v key="$key_data" '
    $1 == principal && (($2 == type && $3 == key) ||
        ($2 == "namespaces=\"git\"" && $3 == type && $4 == key)) { found = 1 }
    END { exit !found }
' "$signers"; then
    already_trusted=1
fi

if [[ $already_trusted -eq 0 ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
        info "Would authorize your public signing key for $PRINCIPAL (Git namespace)."
    else
        temporary=''
        trap '[[ -z $temporary ]] || rm -f -- "$temporary"' EXIT
        mkdir -p -- "$signers_dir"
        temporary=$(mktemp "$signers_dir/.allowed-signers.XXXXXXXX")
        if [[ -s $signers ]]; then
            cat -- "$signers" > "$temporary"
            printf '\n' >> "$temporary"
        fi
        # Strip the key's comment: it may identify a private machine hostname.
        printf '%s namespaces="git" %s %s\n' "$PRINCIPAL" "$key_type" "$key_data" >> "$temporary"
        if [[ -f $signers ]]; then
            chmod --reference="$signers" "$temporary"
        else
            chmod 0644 -- "$temporary"
        fi
        mv -T -- "$temporary" "$signers"
        temporary=''
    fi
else
    info "Your public key is already authorized for $PRINCIPAL."
fi

run git -C "$REPO_ROOT" config --local gpg.format ssh
run git -C "$REPO_ROOT" config --local user.signingkey "$PUBLIC_KEY"
run git -C "$REPO_ROOT" config --local commit.gpgsign true
run git -C "$REPO_ROOT" config --local gpg.ssh.allowedSignersFile "$signers"
run git -C "$REPO_ROOT" config --local merge.verifySignatures true
run git -C "$REPO_ROOT" config --local pull.ff only

if [[ $DRY_RUN -eq 0 ]]; then
    success 'Fork signing configured locally; review and commit .config/git/allowed_signers.'
else
    success 'Fork setup dry run complete; no files or Git settings changed.'
fi
