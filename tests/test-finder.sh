#!/usr/bin/env bash
# shellcheck disable=SC2016  # Mock scripts deliberately retain their variables.
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-finder.XXXXXXXX")
cleanup() {
    case $TEST_ROOT in
    "${TMPDIR:-/tmp}"/myhypr-finder.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/work/folder"
mkdir -p "$TEST_ROOT/user-root/.config/myhypr/bin"
printf 'content\n' >"$TEST_ROOT/work/file with spaces.txt"
ln -s "$REPO_ROOT/dotfiles/.config/myhypr/bin/myhypr-finder.sh" \
    "$TEST_ROOT/user-root/.config/myhypr/bin/myhypr-finder.sh"

printf '%s\n' '#!/usr/bin/env bash' \
    'awk -F "\\t" -v pick="$FINDER_PICK" '\''$2 ~ pick { print; exit }'\''' \
    >"$TEST_ROOT/bin/fzf"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" "$*"' >"$TEST_ROOT/bin/test-editor"
chmod +x "$TEST_ROOT/bin/fzf" "$TEST_ROOT/bin/test-editor"

cd "$TEST_ROOT/work"
directory_result=$(FINDER_PICK='folder$' PATH="$TEST_ROOT/bin:/usr/bin:/bin" \
    "$REPO_ROOT/dotfiles/.config/myhypr/bin/myhypr-finder.sh")
[[ $directory_result == 'TYPE_DIR:./folder' ]]

: >"$TEST_ROOT/captured"
captured_stdout=$(FINDER_PICK='file with spaces.txt$' EDITOR=test-editor \
    PATH="$TEST_ROOT/bin:/usr/bin:/bin" \
    "$REPO_ROOT/dotfiles/.config/myhypr/bin/myhypr-finder.sh" 3>"$TEST_ROOT/captured")
[[ -z $captured_stdout ]]
[[ $(<"$TEST_ROOT/captured") == './file with spaces.txt' ]]

for shell_name in bash zsh; do
    command -v "$shell_name" >/dev/null 2>&1 || {
        printf 'Required shell is unavailable: %s\n' "$shell_name" >&2
        exit 1
    }

    case $shell_name in
    bash) wrapper="$REPO_ROOT/dotfiles/.config/bashrc/30-autostart" ;;
    zsh) wrapper="$REPO_ROOT/dotfiles/.config/zshrc/30-autostart" ;;
    esac

    : >"$TEST_ROOT/${shell_name}-wrapper-output"
    (
        cd "$TEST_ROOT/work"
        HOME="$TEST_ROOT/user-root" FINDER_PICK='file with spaces.txt$' \
            EDITOR=test-editor PATH="$TEST_ROOT/bin:/usr/bin:/bin" \
            "$shell_name" -f -c 'source "$1"; finder' finder-test "$wrapper"
    ) >"$TEST_ROOT/${shell_name}-wrapper-output"
    [[ $(<"$TEST_ROOT/${shell_name}-wrapper-output") == './file with spaces.txt' ]]
done

printf 'Finder preserves its directory protocol and terminal output through Bash and Zsh.\n'
