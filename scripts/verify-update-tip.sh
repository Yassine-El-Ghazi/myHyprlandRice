#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/lib/maintenance-git.sh
source "$SCRIPT_DIR/lib/maintenance-git.sh"

if (($# != 2)); then
    printf 'Usage: %s TRUSTED_REVISION CANDIDATE_REVISION\n' "${0##*/}" >&2
    exit 2
fi

repo=$(git rev-parse --show-toplevel)
trusted=$(git -C "$repo" rev-parse --verify --end-of-options "$1^{commit}")
candidate=$(git -C "$repo" rev-parse --verify --end-of-options "$2^{commit}")
git -C "$repo" merge-base --is-ancestor "$trusted" "$candidate" || \
    die 'The update tip must descend from the trusted revision.'

umask 077
verification_dir=$(mktemp -d)
trap 'rm -f -- "$verification_dir/allowed-signers"; rmdir -- "$verification_dir"' EXIT
_maintenance_git_verify_candidate_signature "$repo" "$trusted" "$candidate" "$verification_dir" tag-only
success 'The update tag passes the maintenance SSH trust check.'
