#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes write literal mock-script variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-walker-test.XXXXXXXX")
FAKE_BIN="$TEST_ROOT/bin"
# Keep private storage fixtures away from foreign-owned CI mount ancestors.
TEST_HOME=$(mktemp -d "/tmp/myhypr-walker-home.XXXXXXXX")
export XDG_CACHE_HOME="$TEST_HOME/.cache"
export XDG_STATE_HOME="$TEST_HOME/.local/state"
export WALKER_TEST_STATE="$TEST_ROOT/elephant-ready"
export WALKER_TEST_LOG="$TEST_ROOT/commands.log"

cleanup() {
    case $TEST_HOME in
        /tmp/myhypr-walker-home.*) rm -rf -- "$TEST_HOME" ;;
    esac
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-walker-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

mkdir -p -- \
    "$FAKE_BIN" \
    "$TEST_HOME/.config/myhypr/bin" \
    "$TEST_HOME/.config/myhypr/settings" \
    "$TEST_HOME/.config/walker/themes/myhypr" \
    "$TEST_HOME/.config/walker/themes/glass"
printf 'style\n' > "$TEST_HOME/.config/walker/themes/myhypr/style.css"
printf 'style\n' > "$TEST_HOME/.config/walker/themes/glass/style.css"
cp -- "$REPO_ROOT/dotfiles/.config/myhypr/bin/elephant-storage.py" \
    "$TEST_HOME/.config/myhypr/bin/elephant-storage.py"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ ${1:-} == listproviders ]]; then' \
    '  printf "%s\ncalc\n" "${WALKER_TEST_PROVIDER:-desktopapplications}"' \
    '  exit 0' \
    'fi' \
    'if [[ ${1:-} == state ]]; then' \
    '  [[ -f $WALKER_TEST_STATE ]]' \
    '  exit $?' \
    'fi' \
    '[[ ${WALKER_TEST_START_FAIL:-0} == 0 ]] || exit 1' \
    ': > "$WALKER_TEST_STATE"' \
    'printf "elephant daemon\n" >> "$WALKER_TEST_LOG"' > "$FAKE_BIN/elephant"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "walker" >> "$WALKER_TEST_LOG"' \
    'printf " <%s>" "$@" >> "$WALKER_TEST_LOG"' \
    'printf "\n" >> "$WALKER_TEST_LOG"' > "$FAKE_BIN/walker"
chmod +x -- "$FAKE_BIN/elephant" "$FAKE_BIN/walker"

# A path-like setting must be rejected and fall back to the local MyHypr theme.
printf '../../outside\n' > "$TEST_HOME/.config/myhypr/settings/walker-theme"
HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" \
    XDG_CONFIG_HOME="$TEST_HOME/.config" \
    "$REPO_ROOT/dotfiles/.config/walker/launch.sh" --keep-open
rg -q '^elephant daemon$' "$WALKER_TEST_LOG"
rg -q '^walker <-t> <myhypr> <--keep-open>$' "$WALKER_TEST_LOG"

# A declared local theme is accepted without restarting an available service.
printf 'glass\n' > "$TEST_HOME/.config/myhypr/settings/walker-theme"
HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" \
    XDG_CONFIG_HOME="$TEST_HOME/.config" \
    "$REPO_ROOT/dotfiles/.config/walker/launch.sh"
[[ $(rg -c '^elephant daemon$' "$WALKER_TEST_LOG") -eq 1 ]]
rg -q '^walker <-t> <glass>$' "$WALKER_TEST_LOG"

# Installed providers alone must not open Walker when daemon startup fails.
rm -- "$WALKER_TEST_STATE"
before=$(rg -c '^walker ' "$WALKER_TEST_LOG")
if HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" \
    XDG_CONFIG_HOME="$TEST_HOME/.config" WALKER_TEST_START_FAIL=1 \
    "$REPO_ROOT/dotfiles/.config/walker/launch.sh" 2> "$TEST_ROOT/error"; then
    printf 'Walker opened despite an unavailable Elephant daemon.\n' >&2
    exit 1
fi
[[ $(rg -c '^walker ' "$WALKER_TEST_LOG") -eq $before ]]
rg -q 'Elephant is not responding' "$TEST_ROOT/error"

# A missing provider should fail before attempting to start the daemon.
if HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" \
    XDG_CONFIG_HOME="$TEST_HOME/.config" WALKER_TEST_PROVIDER=calc \
    "$REPO_ROOT/dotfiles/.config/walker/launch.sh" 2> "$TEST_ROOT/error"; then
    printf 'Walker opened despite a missing desktop provider.\n' >&2
    exit 1
fi
[[ $(rg -c '^elephant daemon$' "$WALKER_TEST_LOG") -eq 1 ]]
rg -q 'desktop providers are unavailable' "$TEST_ROOT/error"

printf 'Walker validates themes and waits for its local data service.\n'
