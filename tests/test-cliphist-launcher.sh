#!/usr/bin/env bash
# shellcheck disable=SC2016  # Literal variables in synthetic tools.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-clipboard-test.XXXXXXXX")
TEST_HOME="$TEST_ROOT/home"
FAKE_BIN="$TEST_ROOT/bin"
export CLIPBOARD_TEST_LOG="$TEST_ROOT/commands.log"
export CLIPBOARD_NOTIFY_LOG="$TEST_ROOT/notifications.log"
export CLIPBOARD_QUERY_FIXTURE="$TEST_ROOT/clipboard.jsonl"
export CLIPBOARD_ROFI_INPUT="$TEST_ROOT/rofi-input"
cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-clipboard-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT
fail() { printf 'Clipboard test failed: %s\n' "$*" >&2; exit 1; }
mkdir -p -- "$FAKE_BIN" "$TEST_HOME/.config/walker" "$TEST_HOME/.config/myhypr/settings" \
    "$TEST_HOME/.config/myhypr/bin"
cp -- "$REPO_ROOT/dotfiles/.config/myhypr/bin/clipboard-rofi.py" \
    "$TEST_HOME/.config/myhypr/bin/clipboard-rofi.py"
cat > "$CLIPBOARD_QUERY_FIXTURE" <<'EOF'
{"item":{"identifier":"first-id","provider":"clipboard","text":"first\nline"}}
{"item":{"identifier":"second-id","provider":"clipboard","text":"$(touch /tmp/do-not-run)\u0000test"}}
{"item":{"identifier":"wrong-provider","provider":"runner","text":"ignored"}}
{"item":{"identifier":"unsafe;copy","provider":"clipboard","text":"ignored"}}
EOF
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "walker <%s>\n" "$*" >> "$CLIPBOARD_TEST_LOG"' \
    > "$TEST_HOME/.config/walker/launch.sh"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "elephant <%s>\n" "$*" >> "$CLIPBOARD_TEST_LOG"' \
    'if [[ ${1:-} == query ]]; then cat "$CLIPBOARD_QUERY_FIXTURE"; fi' \
    'exit "${ELEPHANT_TEST_FAIL:-0}"' > "$FAKE_BIN/elephant"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "rofi <%s>\n" "$*" >> "$CLIPBOARD_TEST_LOG"' \
    'cat > "$CLIPBOARD_ROFI_INPUT"' \
    'printf "%s\n" "${CLIPBOARD_ROFI_SELECTION-0}"' \
    'exit "${CLIPBOARD_ROFI_FAIL:-0}"' > "$FAKE_BIN/rofi"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "cliphist <%s>\n" "$*" >> "$CLIPBOARD_TEST_LOG"' \
    'exit "${CLIPHIST_TEST_FAIL:-0}"' > "$FAKE_BIN/cliphist"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >> "$CLIPBOARD_NOTIFY_LOG"' > "$FAKE_BIN/notify-send"
chmod +x -- "$FAKE_BIN/elephant" "$FAKE_BIN/cliphist" "$FAKE_BIN/notify-send" \
    "$FAKE_BIN/rofi" "$TEST_HOME/.config/walker/launch.sh"
export HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin"
export XDG_CONFIG_HOME="$TEST_HOME/.config" XDG_CACHE_HOME="$TEST_HOME/.cache"
script="$REPO_ROOT/dotfiles/.config/myhypr/scripts/cliphist.sh"
for launcher in rofi walker; do
    printf '%s' "$launcher" > "$TEST_HOME/.config/myhypr/settings/launcher"
    : > "$CLIPBOARD_TEST_LOG"
    "$script"
    if [[ $launcher == walker ]]; then
        [[ $(<"$CLIPBOARD_TEST_LOG") == 'walker <-m clipboard -N -H>' ]] || fail 'Walker copy view changed'
    else
        rg -Fxq 'walker <--ensure-elephant>' "$CLIPBOARD_TEST_LOG"
        rg -Fxq 'elephant <query --json clipboard;;500>' "$CLIPBOARD_TEST_LOG"
        rg -Fxq 'elephant <activate clipboard;first-id;copy;;>' "$CLIPBOARD_TEST_LOG"
        rg -Fq 'rofi <-dmenu -replace -no-custom -no-markup-rows -format i -p Search -config' "$CLIPBOARD_TEST_LOG"
        [[ $(wc -l < "$CLIPBOARD_ROFI_INPUT") -eq 2 ]] || fail 'Rofi preview was not flattened or unsafe items remained'
        rg -Fxq 'first line' "$CLIPBOARD_ROFI_INPUT"
        rg -Fxq '$(touch /tmp/do-not-run)test' "$CLIPBOARD_ROFI_INPUT"
    fi
    : > "$CLIPBOARD_TEST_LOG"
    "$script" d
    if [[ $launcher == walker ]]; then
        [[ $(<"$CLIPBOARD_TEST_LOG") == 'walker <-m clipboard -H -p Delete entry: Ctrl+D>' ]] || fail 'Walker delete view changed'
    else
        rg -Fxq 'elephant <activate clipboard;first-id;remove;;>' "$CLIPBOARD_TEST_LOG"
        rg -Fq -- '-p Delete -config' "$CLIPBOARD_TEST_LOG"
    fi
    : > "$CLIPBOARD_TEST_LOG"
    "$script" w
    rg -Fxq 'elephant <activate clipboard;;remove_all;;>' "$CLIPBOARD_TEST_LOG"
    rg -Fxq 'cliphist <wipe>' "$CLIPBOARD_TEST_LOG"
done

# Cancellation and invalid output must never copy or delete clipboard entries.
printf '%s' rofi > "$TEST_HOME/.config/myhypr/settings/launcher"
: > "$CLIPBOARD_TEST_LOG"
CLIPBOARD_ROFI_SELECTION=1 "$script"
rg -Fxq 'elephant <activate clipboard;second-id;copy;;>' "$CLIPBOARD_TEST_LOG"
for selection in '' 99 -1 first-id; do
    : > "$CLIPBOARD_TEST_LOG"
    if CLIPBOARD_ROFI_SELECTION="$selection" "$script" 2>/dev/null; then
        [[ -z $selection ]] || fail 'invalid Rofi selection reported success'
    fi
    if rg -q 'elephant <activate' "$CLIPBOARD_TEST_LOG"; then fail 'invalid selection activated an entry'; fi
done
: > "$CLIPBOARD_TEST_LOG"
CLIPBOARD_ROFI_FAIL=1 "$script"
if rg -q 'elephant <activate' "$CLIPBOARD_TEST_LOG"; then fail 'cancelled popup activated an entry'; fi
: > "$CLIPBOARD_TEST_LOG"
if ELEPHANT_TEST_FAIL=9 "$script" 2>/dev/null; then fail 'query failure reported success'; fi
if rg -q '^rofi |elephant <activate' "$CLIPBOARD_TEST_LOG"; then fail 'query failure reached selection'; fi

for failing in elephant cliphist; do
    : > "$CLIPBOARD_TEST_LOG"
    : > "$CLIPBOARD_NOTIFY_LOG"
    if [[ $failing == elephant ]]; then
        if ELEPHANT_TEST_FAIL=9 "$script" w 2>/dev/null; then fail 'primary failure reported success'; fi
    else
        if CLIPHIST_TEST_FAIL=9 "$script" w 2>/dev/null; then fail 'legacy failure reported success'; fi
    fi
    [[ $(wc -l < "$CLIPBOARD_TEST_LOG") -eq 2 ]] || fail 'partial failure prevented the other clear'
    rg -Fq 'Clipboard history clear failed' "$CLIPBOARD_NOTIFY_LOG" || fail 'desktop clear failure stayed invisible'
done
: > "$CLIPBOARD_TEST_LOG"
if "$script" invalid 2>/dev/null; then fail 'invalid argument accepted'; fi
if "$script" w extra 2>/dev/null; then fail 'extra argument accepted'; fi
[[ ! -s $CLIPBOARD_TEST_LOG ]] || fail 'invalid request reached clipboard services'
# A fresh installation needs no retired CLI. Existing data must not be hidden
# by reporting a successful clear when that CLI is unavailable.
mv -- "$FAKE_BIN/cliphist" "$FAKE_BIN/cliphist-retired"
ln -s /usr/bin/bash "$FAKE_BIN/bash"
: > "$CLIPBOARD_TEST_LOG"
PATH="$FAKE_BIN" "$script" w
[[ $(wc -l < "$CLIPBOARD_TEST_LOG") -eq 1 ]] || fail 'fresh install used a retired store'
mkdir -p -- "$XDG_CACHE_HOME/cliphist"
printf 'synthetic legacy data\n' > "$XDG_CACHE_HOME/cliphist/db"
if PATH="$FAKE_BIN" "$script" w 2>/dev/null; then fail 'unclearable legacy data reported success'; fi
[[ -s $XDG_CACHE_HOME/cliphist/db ]] || fail 'missing CLI caused direct legacy deletion'
rm -- "$XDG_CACHE_HOME/cliphist/db"
mkdir -p -- "$XDG_CONFIG_HOME/cliphist"
printf 'db-path custom-fixture\n' > "$XDG_CONFIG_HOME/cliphist/config"
if PATH="$FAKE_BIN" "$script" w 2>/dev/null; then fail 'unknown configured legacy store reported success'; fi
# Both maintained compositor formats must have only the session-owned collector.
if rg -q 'wl-paste.*--watch|cliphist[[:space:]]+store' \
    "$REPO_ROOT/dotfiles/.config/hypr/conf/autostart.lua" \
    "$REPO_ROOT/dotfiles/.config/hypr/conf/autostart.conf"; then
    fail 'second clipboard collector remains enabled'
fi
printf 'Clipboard respects both launchers, uses one store, and reports partial clearing failures.\n'
