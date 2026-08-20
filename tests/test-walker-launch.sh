#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single quotes write literal mock-script variables.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-walker-test.XXXXXXXX")
FAKE_BIN="$TEST_ROOT/bin"
TEST_HOME="$TEST_ROOT/user-root"
export WALKER_TEST_STATE="$TEST_ROOT/elephant-ready"
export WALKER_TEST_LOG="$TEST_ROOT/commands.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-walker-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

mkdir -p -- \
    "$FAKE_BIN" \
    "$TEST_HOME/.config/myhypr/settings" \
    "$TEST_HOME/.config/walker/themes/myhypr" \
    "$TEST_HOME/.config/walker/themes/glass"
printf 'style\n' > "$TEST_HOME/.config/walker/themes/myhypr/style.css"
printf 'style\n' > "$TEST_HOME/.config/walker/themes/glass/style.css"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ ${1:-} == listproviders ]]; then' \
    '  [[ -f $WALKER_TEST_STATE ]] || exit 1' \
    '  printf "desktopapplications\ncalc\n"' \
    '  exit 0' \
    'fi' \
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
    "$REPO_ROOT/dotfiles/.config/walker/launch.sh" --keep-open
rg -q '^elephant daemon$' "$WALKER_TEST_LOG"
rg -q '^walker <-t> <myhypr> <--keep-open>$' "$WALKER_TEST_LOG"

# A declared local theme is accepted without restarting an available service.
printf 'glass\n' > "$TEST_HOME/.config/myhypr/settings/walker-theme"
HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" \
    "$REPO_ROOT/dotfiles/.config/walker/launch.sh"
[[ $(rg -c '^elephant daemon$' "$WALKER_TEST_LOG") -eq 1 ]]
rg -q '^walker <-t> <glass>$' "$WALKER_TEST_LOG"

printf 'Walker validates themes and waits for its local data service.\n'
