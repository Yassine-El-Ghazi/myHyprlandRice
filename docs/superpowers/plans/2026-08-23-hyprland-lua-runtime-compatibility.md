# Hyprland Lua Runtime Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every active MyHyprlandRice shortcut and desktop runtime action work with Hyprland 0.56.2's Lua configuration provider without changing the desktop's keys or appearance.

**Architecture:** Keep JSON queries and user-facing shell helpers at their current boundaries, but replace every runtime mutation with Hyprland's typed Lua API. Use fixed `hl.config`, `hl.monitor`, and `hl.dsp` expressions with strict validation, plus one focused Lua module for the removed all-float workspace behavior. Protect the result with mock behavior tests, a Lua state-machine test, a keybinding inventory, and a repository-wide legacy-action guard.

**Tech Stack:** Bash 5, Lua 5.5, Hyprland 0.56.2 Lua API, `hyprctl`, jq, ripgrep, ShellCheck, Git, Gitleaks.

**Spec:** `docs/superpowers/specs/2026-08-23-hyprland-lua-runtime-compatibility-design.md`

## Global Constraints

- Target Hyprland 0.56.2 and its Lua configuration provider; do not restore the retired Hyprlang provider.
- Preserve all current key combinations, wallpaper selection, generated colors, Waybar layout, dock style, and application choices.
- Permit only fixed `hyprctl eval` templates containing validated numeric or allow-listed identifier values; never add shell `eval` or an arbitrary-expression helper.
- Keep read-only `hyprctl -j` queries, `hyprctl reload`, and `hyprctl notify` where they remain valid.
- Do not trigger compositor exit, DPMS off, suspend, hibernate, reboot, or shutdown during live verification.
- Run the focused test before and after each implementation slice, then `./scripts/check.sh --quick`.
- Before every commit, review `git diff --cached`, run `./scripts/audit.sh --staged`, and verify that only the intended paths are staged.
- Do not push. Merge verified work back to local `main` only after the execution workflow's final review.
- Use `apply_patch` for source edits and preserve unrelated user changes.

---

### Task 0: Establish the rollback point and clean baseline

**Files:**
- Read: `docs/superpowers/specs/2026-08-23-hyprland-lua-runtime-compatibility-design.md`
- Read: `docs/superpowers/plans/2026-08-23-hyprland-lua-runtime-compatibility.md`
- No source files change in this task.

**Interfaces:**
- Consumes: committed design `bfd890b`, this committed plan, and a clean local `main`.
- Produces: annotated tag `pre-hyprland-lua-actions-2026-08-23` pointing at the pre-implementation baseline.

- [ ] **Step 1: Confirm the exact baseline**

Run:

```bash
git status --short --branch
baseline_commit=$(git rev-parse HEAD)
git merge-base --is-ancestor bfd890b "$baseline_commit"
git tag -l 'pre-hyprland-lua-actions-2026-08-23'
```

Expected: the tree is clean, the approved design is an ancestor of the plan commit, and the tag query prints nothing.

- [ ] **Step 2: Run the baseline validation and security audit**

Run:

```bash
./scripts/check.sh
./scripts/audit.sh
```

Expected: every validation group passes, all 56 Hyprland configurations pass, and the privacy/security audit reports no leaks.

- [ ] **Step 3: Create and verify the rollback tag**

Run:

```bash
baseline_commit=$(git rev-parse HEAD)
git tag -a pre-hyprland-lua-actions-2026-08-23 -m 'Rollback point before Hyprland Lua runtime action migration' "$baseline_commit"
git rev-parse pre-hyprland-lua-actions-2026-08-23^{}
printf '%s\n' "$baseline_commit"
```

Expected: the two full commit IDs are identical.

---

### Task 1: Migrate cursor zoom and animation toggling

**Files:**
- Modify: `dotfiles/.config/hypr/scripts/cursor-zoom.sh:30`
- Modify: `dotfiles/.config/hypr/scripts/toggle-animations.sh:11-18`
- Modify: `tests/test-cursor-zoom.sh:24-32`
- Create: `tests/test-toggle-animations.sh`
- Modify: `tests/test-standalone.sh:11-15`
- Modify: `scripts/check.sh:133-136`

**Interfaces:**
- Consumes: validated zoom value `next` in the inclusive range 1.0–5.0 and the existing animation cache marker.
- Produces: fixed calls `hl.config({ cursor = { zoom_factor = N } })` and `hl.config({ animations = { enabled = BOOL } })`.

- [ ] **Step 1: Change the cursor test to require the typed API**

Replace the three command assertions in `tests/test-cursor-zoom.sh` with:

```bash
rg -Fqx 'hyprctl eval hl.config({ cursor = { zoom_factor = 2.5 } })' "$ZOOM_TEST_LOG"
rg -Fqx 'hyprctl eval hl.config({ cursor = { zoom_factor = 1.5 } })' "$ZOOM_TEST_LOG"
rg -Fqx 'hyprctl eval hl.config({ cursor = { zoom_factor = 1 } })' "$ZOOM_TEST_LOG"
```

- [ ] **Step 2: Add a behavior test for animation state and failure ordering**

Create `tests/test-toggle-animations.sh` with a temporary home, a fake `hyprctl`, and these assertions:

```bash
#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-animation-test.XXXXXXXX")
FAKE_BIN="$TEST_ROOT/bin"
TEST_HOME="$TEST_ROOT/home"
export ANIMATION_TEST_LOG="$TEST_ROOT/hyprctl.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-animation-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

mkdir -p -- "$FAKE_BIN" "$TEST_HOME/.config/hypr/conf"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    '[[ ${ANIMATION_TEST_FAIL:-0} -eq 0 ]] || exit 9' \
    'printf "hyprctl %s\n" "$*" >> "$ANIMATION_TEST_LOG"' \
    > "$FAKE_BIN/hyprctl"
chmod +x -- "$FAKE_BIN/hyprctl"
printf 'source = ~/.config/hypr/conf/animations/default.conf\n' \
    > "$TEST_HOME/.config/hypr/conf/animation.conf"

helper="$REPO_ROOT/dotfiles/.config/hypr/scripts/toggle-animations.sh"
HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" "$helper"
rg -Fqx 'hyprctl eval hl.config({ animations = { enabled = false } })' "$ANIMATION_TEST_LOG"
[[ -f $TEST_HOME/.cache/myhypr/animations-disabled ]]

HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" "$helper"
rg -Fqx 'hyprctl eval hl.config({ animations = { enabled = true } })' "$ANIMATION_TEST_LOG"
[[ ! -e $TEST_HOME/.cache/myhypr/animations-disabled ]]

if HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" ANIMATION_TEST_FAIL=1 "$helper"; then
    printf 'Animation helper accepted a failed Hyprland update.\n' >&2
    exit 1
fi
[[ ! -e $TEST_HOME/.cache/myhypr/animations-disabled ]]

printf 'Animation toggling commits state only after typed config succeeds.\n'
```

- [ ] **Step 3: Register and run the focused tests to observe failure**

Add this line after the cursor test in `scripts/check.sh`:

```bash
run_check 'Animation toggle behavior' "$REPO_ROOT/tests/test-toggle-animations.sh"
```

Run:

```bash
chmod +x tests/test-toggle-animations.sh
./tests/test-cursor-zoom.sh
./tests/test-toggle-animations.sh
```

Expected: both tests fail because the helpers still emit `hyprctl keyword`.

- [ ] **Step 4: Implement the two fixed typed configuration calls**

Replace the final line of `cursor-zoom.sh` with:

```bash
exec hyprctl eval "hl.config({ cursor = { zoom_factor = $next } })"
```

Replace the two animation mutations with:

```bash
if [[ -f $cache_file ]]; then
    hyprctl eval 'hl.config({ animations = { enabled = true } })'
    rm -f -- "$cache_file"
else
    hyprctl eval 'hl.config({ animations = { enabled = false } })'
    : > "$cache_file"
fi
```

- [ ] **Step 5: Narrow the shell-eval guard without weakening it**

Replace the broad `eval` expression in `tests/test-standalone.sh` with:

```bash
shell_eval_pattern='(^|[;&|][[:space:]]*)[[:space:]]*(builtin[[:space:]]+|command[[:space:]]+)?eval[[:space:]]'
if rg -n "$shell_eval_pattern" \
    dotfiles/.config/myhypr dotfiles/.config/sidepad dotfiles/.config/hypr/scripts; then
    printf 'Tracked desktop helpers still evaluate runtime text as shell code.\n' >&2
    exit 1
fi
```

This still rejects an `eval "$value"` shell command while allowing the fixed `hyprctl eval 'hl.config(...)'` subcommand.

- [ ] **Step 6: Run focused and quick validation**

Run:

```bash
./tests/test-cursor-zoom.sh
./tests/test-toggle-animations.sh
./tests/test-standalone.sh
./scripts/check.sh --quick
```

Expected: all commands pass.

- [ ] **Step 7: Audit the staged slice and commit**

Run:

```bash
git add dotfiles/.config/hypr/scripts/cursor-zoom.sh \
  dotfiles/.config/hypr/scripts/toggle-animations.sh \
  tests/test-cursor-zoom.sh tests/test-toggle-animations.sh \
  tests/test-standalone.sh scripts/check.sh
git diff --cached --check
git diff --cached
./scripts/audit.sh --staged
git commit -m 'fix(hyprland): migrate display runtime config actions'
```

Expected: the staged audit passes and the commit contains only these six paths.

---

### Task 2: Migrate persistent gamemode configuration

**Files:**
- Modify: `dotfiles/.config/hypr/scripts/gamemode.sh:4-42`
- Modify: `dotfiles/.config/hypr/scripts/load-gamemode.sh:9-24`
- Create: `tests/test-gamemode.sh`
- Modify: `scripts/check.sh` immediately after the animation test registration.

**Interfaces:**
- Consumes: `~/.config/myhypr/settings/gamemode-enabled` and the existing monitor/wallpaper cache files.
- Produces: one fixed typed config table for activation and one fixed typed config table for persisted startup restoration.

- [ ] **Step 1: Add the gamemode behavior test**

Create `tests/test-gamemode.sh` with this complete fixture:

```bash
#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-gamemode-test.XXXXXXXX")
FAKE_BIN="$TEST_ROOT/bin"
TEST_HOME="$TEST_ROOT/home"
CONFIG_ROOT="$TEST_HOME/.config"
CACHE_ROOT="$TEST_HOME/.cache"
export GAMEMODE_TEST_LOG="$TEST_ROOT/hyprctl.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-gamemode-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

mkdir -p -- "$FAKE_BIN" "$CONFIG_ROOT/myhypr/settings" "$CACHE_ROOT"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ ${GAMEMODE_TEST_FAIL:-0} -eq 1 && ${1:-} == eval ]]; then exit 9; fi' \
    'printf "hyprctl %s\n" "$*" >> "$GAMEMODE_TEST_LOG"' \
    > "$FAKE_BIN/hyprctl"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$FAKE_BIN/notify-send"
chmod +x -- "$FAKE_BIN/hyprctl" "$FAKE_BIN/notify-send"

gamemode="$REPO_ROOT/dotfiles/.config/hypr/scripts/gamemode.sh"
loader="$REPO_ROOT/dotfiles/.config/hypr/scripts/load-gamemode.sh"
marker="$CONFIG_ROOT/myhypr/settings/gamemode-enabled"
activation='hyprctl eval hl.config({ animations = { enabled = false }, decoration = { shadow = { enabled = false }, blur = { enabled = false }, active_opacity = 1, inactive_opacity = 1, fullscreen_opacity = 1, rounding = 0 }, general = { gaps_in = 0, gaps_out = 0, border_size = 1 } })'
startup='hyprctl eval hl.config({ animations = { enabled = false }, decoration = { shadow = { enabled = false }, blur = { enabled = false }, rounding = 0 }, general = { gaps_in = 0, gaps_out = 0, border_size = 1 } })'

HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" XDG_CACHE_HOME="$CACHE_ROOT" \
    PATH="$FAKE_BIN:/usr/bin:/bin" "$gamemode"
rg -Fqx "$activation" "$GAMEMODE_TEST_LOG"
[[ -f $marker ]]

HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" XDG_CACHE_HOME="$CACHE_ROOT" \
    PATH="$FAKE_BIN:/usr/bin:/bin" "$gamemode"
rg -Fqx 'hyprctl reload' "$GAMEMODE_TEST_LOG"
[[ ! -e $marker ]]

: > "$marker"
: > "$GAMEMODE_TEST_LOG"
HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" XDG_CACHE_HOME="$CACHE_ROOT" \
    PATH="$FAKE_BIN:/usr/bin:/bin" "$loader"
rg -Fqx "$startup" "$GAMEMODE_TEST_LOG"

rm -f -- "$marker"
if HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" XDG_CACHE_HOME="$CACHE_ROOT" \
    PATH="$FAKE_BIN:/usr/bin:/bin" GAMEMODE_TEST_FAIL=1 "$gamemode"; then
    printf 'Gamemode persisted state after a rejected config update.\n' >&2
    exit 1
fi
[[ ! -e $marker ]]

printf 'Gamemode uses typed config and persists only accepted state.\n'
```

- [ ] **Step 2: Register and run the red test**

Add to `scripts/check.sh`:

```bash
run_check 'Gamemode runtime configuration' "$REPO_ROOT/tests/test-gamemode.sh"
```

Run:

```bash
chmod +x tests/test-gamemode.sh
./tests/test-gamemode.sh
```

Expected: FAIL because both scripts still use `hyprctl --batch` and `keyword`.

- [ ] **Step 3: Replace gamemode activation with the full typed table**

Replace the batched command in `gamemode.sh` with:

```bash
hyprctl eval 'hl.config({ animations = { enabled = false }, decoration = { shadow = { enabled = false }, blur = { enabled = false }, active_opacity = 1, inactive_opacity = 1, fullscreen_opacity = 1, rounding = 0 }, general = { gaps_in = 0, gaps_out = 0, border_size = 1 } })'
: > "$ENABLED_MARKER"
```

Keep the marker after the `hyprctl` call so `set -e` prevents false persisted state.

- [ ] **Step 4: Replace startup restoration with its typed table**

Use this `_loadGameMode` body in `load-gamemode.sh`:

```bash
_loadGameMode() {
    hyprctl eval 'hl.config({ animations = { enabled = false }, decoration = { shadow = { enabled = false }, blur = { enabled = false }, rounding = 0 }, general = { gaps_in = 0, gaps_out = 0, border_size = 1 } })'
}
```

- [ ] **Step 5: Verify and commit the gamemode slice**

Run:

```bash
./tests/test-gamemode.sh
./scripts/check.sh --quick
git add dotfiles/.config/hypr/scripts/gamemode.sh \
  dotfiles/.config/hypr/scripts/load-gamemode.sh \
  tests/test-gamemode.sh scripts/check.sh
git diff --cached --check
git diff --cached
./scripts/audit.sh --staged
git commit -m 'fix(hyprland): migrate gamemode to typed Lua config'
```

Expected: tests and staged audit pass; no runtime marker or generated color file is staged.

---

### Task 3: Migrate focus, workspace movement, and monitor refresh actions

**Files:**
- Modify: `dotfiles/.config/myhypr/scripts/focus.sh:40`
- Rewrite: `dotfiles/.config/hypr/scripts/moveTo.sh`
- Modify: `dotfiles/.config/hypr/scripts/toggle-refresh.sh:15-81`
- Modify: `tests/test-window-focus.sh:33`
- Create: `tests/test-workspace-move.sh`
- Modify: `tests/helpers/hyprctl:4-17`
- Modify: `tests/test-toggle-refresh.sh:18-29`
- Modify: `scripts/check.sh` near the existing focus/monitor groups.

**Interfaces:**
- Consumes: a validated Hyprland address, a workspace integer 1–10, and validated monitor JSON.
- Produces: typed focus, silent per-window workspace move, workspace focus, and `hl.monitor` actions.

- [ ] **Step 1: Change the focus test expectation**

Replace its final assertion with:

```bash
rg -Fqx "hyprctl dispatch hl.dsp.focus({ window = 'address:0xbbb' })" "$FOCUS_TEST_LOG"
```

- [ ] **Step 2: Add a workspace movement behavior test**

Create `tests/test-workspace-move.sh`:

```bash
#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-workspace-move.XXXXXXXX")
FAKE_BIN="$TEST_ROOT/bin"
export WORKSPACE_MOVE_LOG="$TEST_ROOT/hyprctl.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-workspace-move.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

mkdir -p -- "$FAKE_BIN"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "$*" in' \
    '  "-j activeworkspace") printf "%s\n" '\''{"id":2}'\'' ;;' \
    '  "-j clients") printf "%s\n" '\''[{"address":"0xaaa","workspace":{"id":2}},{"address":"0xbbb","workspace":{"id":2}},{"address":"0xccc","workspace":{"id":4}}]'\'' ;;' \
    '  *) printf "hyprctl %s\n" "$*" >> "$WORKSPACE_MOVE_LOG" ;;' \
    'esac' \
    > "$FAKE_BIN/hyprctl"
chmod +x -- "$FAKE_BIN/hyprctl"

helper="$REPO_ROOT/dotfiles/.config/hypr/scripts/moveTo.sh"
PATH="$FAKE_BIN:/usr/bin:/bin" "$helper" 7
mapfile -t calls < "$WORKSPACE_MOVE_LOG"
[[ ${calls[0]:-} == "hyprctl dispatch hl.dsp.window.move({ workspace = 7, follow = false, window = 'address:0xaaa' })" ]]
[[ ${calls[1]:-} == "hyprctl dispatch hl.dsp.window.move({ workspace = 7, follow = false, window = 'address:0xbbb' })" ]]
[[ ${calls[2]:-} == 'hyprctl dispatch hl.dsp.focus({ workspace = 7 })' ]]
[[ ${#calls[@]} -eq 3 ]]

before=$(wc -l < "$WORKSPACE_MOVE_LOG")
if PATH="$FAKE_BIN:/usr/bin:/bin" "$helper" '7); os.execute("touch /tmp/bad")'; then
    printf 'Workspace helper accepted an unsafe destination.\n' >&2
    exit 1
fi
after=$(wc -l < "$WORKSPACE_MOVE_LOG")
[[ $before -eq $after ]]

printf 'Workspace movement validates input and uses typed dispatchers.\n'
```

- [ ] **Step 3: Update the monitor fake and expectations**

Allow `tests/helpers/hyprctl` to log `eval` alongside `notify`:

```bash
    eval|notify)
        printf '%s\n' "$*" >> "${TEST_HYPRCTL_LOG:?}"
        ;;
```

Change its monitor fixture line to:

```bash
command cat -- "${TEST_HYPRCTL_FIXTURE:-$SCRIPT_DIR/../fixtures/hypr-monitors.json}"
```

Change the low-refresh assertion to:

```bash
rg -Fqx "eval hl.monitor({ output = 'eDP-test', mode = '1920x1080@60.00', position = '0x0', scale = 1, transform = 0 })" "$TEST_HYPRCTL_LOG"
```

Keep the high-refresh no-op assertion and require that no `eval hl.monitor` line appears in that case.

Add an injection regression at the end of `tests/test-toggle-refresh.sh`:

```bash
bad_fixture=''
cleanup_bad_fixture() {
    case $bad_fixture in
        "${TMPDIR:-/tmp}"/myhypr-bad-monitor.*) rm -f -- "$bad_fixture" ;;
    esac
}
trap 'cleanup; cleanup_bad_fixture' EXIT
bad_fixture=$(mktemp "${TMPDIR:-/tmp}/myhypr-bad-monitor.XXXXXXXX")
jq '.[0].name = "eDP-test\u0027); os.execute(\u0022touch /tmp/bad\u0022); --"' \
    "$REPO_ROOT/tests/fixtures/hypr-monitors.json" > "$bad_fixture"
: > "$TEST_HYPRCTL_LOG"
if TEST_HYPRCTL_FIXTURE="$bad_fixture" PATH="$REPO_ROOT/tests/helpers:$PATH" \
    "$REPO_ROOT/dotfiles/.config/hypr/scripts/toggle-refresh.sh" low; then
    printf 'Unsafe monitor name was accepted.\n' >&2
    exit 1
fi
! rg -q '^eval hl\.monitor' "$TEST_HYPRCTL_LOG"
rm -f -- "$bad_fixture"
```

- [ ] **Step 4: Run all three tests to observe failure**

Register the new workspace test in `scripts/check.sh`, then run:

```bash
chmod +x tests/test-workspace-move.sh
./tests/test-window-focus.sh
./tests/test-workspace-move.sh
./tests/test-toggle-refresh.sh
```

Expected: each test fails on its old token-based or keyword action.

- [ ] **Step 5: Implement typed window focus**

Replace the final line of `focus.sh` with:

```bash
exec hyprctl dispatch "hl.dsp.focus({ window = 'address:$selected_address' })"
```

- [ ] **Step 6: Rewrite `moveTo.sh` with strict validation and typed dispatchers**

Use this control flow:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

target_workspace=${1:-}
[[ $target_workspace =~ ^([1-9]|10)$ ]] || {
    printf 'Usage: %s {1..10}\n' "${0##*/}" >&2
    exit 2
}
for command_name in hyprctl jq; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf '%s: command not found\n' "$command_name" >&2
        exit 127
    }
done

current_workspace=$(hyprctl -j activeworkspace | jq -er '.id | numbers')
[[ $current_workspace =~ ^-?[0-9]+$ ]] || {
    printf 'Hyprland returned an invalid active workspace.\n' >&2
    exit 1
}
mapfile -t window_addresses < <(
    hyprctl -j clients | jq -er --argjson workspace "$current_workspace" \
        '.[] | select(.workspace.id == $workspace) | .address'
)

for address in "${window_addresses[@]}"; do
    [[ $address =~ ^0x[0-9A-Fa-f]+$ ]] || {
        printf 'Hyprland returned an invalid window address.\n' >&2
        exit 1
    }
    hyprctl dispatch "hl.dsp.window.move({ workspace = $target_workspace, follow = false, window = 'address:$address' })"
done
hyprctl dispatch "hl.dsp.focus({ workspace = $target_workspace })"
```

- [ ] **Step 7: Validate monitor fields and call `hl.monitor`**

Before constructing the action in `toggle-refresh.sh`, add:

```bash
[[ $name =~ ^[[:alnum:]_.:-]+$ ]] || { printf 'Invalid monitor name.\n' >&2; exit 1; }
[[ $width =~ ^[1-9][0-9]*$ && $height =~ ^[1-9][0-9]*$ ]] || { printf 'Invalid monitor dimensions.\n' >&2; exit 1; }
[[ $position =~ ^-?[0-9]+x-?[0-9]+$ ]] || { printf 'Invalid monitor position.\n' >&2; exit 1; }
[[ $scale =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf 'Invalid monitor scale.\n' >&2; exit 1; }
[[ $transform =~ ^[0-7]$ ]] || { printf 'Invalid monitor transform.\n' >&2; exit 1; }
[[ $target_rate =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf 'Invalid refresh rate.\n' >&2; exit 1; }
((width <= 16384 && height <= 16384 && ${#name} <= 128)) || { printf 'Monitor data exceeds supported bounds.\n' >&2; exit 1; }
awk -v scale="$scale" -v rate="$target_rate" 'BEGIN { exit !(scale > 0 && rate > 0) }' || {
    printf 'Monitor scale and refresh rate must be positive.\n' >&2
    exit 1
}
```

Replace the keyword rule with:

```bash
hyprctl eval "hl.monitor({ output = '$name', mode = '${width}x${height}@${target_rate}', position = '$position', scale = $scale, transform = $transform })"
```

- [ ] **Step 8: Verify and commit the action slice**

Run:

```bash
./tests/test-window-focus.sh
./tests/test-workspace-move.sh
./tests/test-toggle-refresh.sh
./scripts/check.sh --quick
git add dotfiles/.config/myhypr/scripts/focus.sh \
  dotfiles/.config/hypr/scripts/moveTo.sh \
  dotfiles/.config/hypr/scripts/toggle-refresh.sh \
  tests/test-window-focus.sh tests/test-workspace-move.sh \
  tests/helpers/hyprctl tests/test-toggle-refresh.sh scripts/check.sh
git diff --cached --check
git diff --cached
./scripts/audit.sh --staged
git commit -m 'fix(hyprland): migrate window and monitor actions'
```

Expected: all focused tests and the quick suite pass.

---

### Task 4: Rebuild all-float as a native stateful Lua action

**Files:**
- Create: `dotfiles/.config/hypr/conf/runtime_actions.lua`
- Modify: `dotfiles/.config/hypr/conf/keybindings/default.lua:7-34`
- Modify: `dotfiles/.config/hypr/conf/keybindings/fr.lua:7-31`
- Rewrite: `dotfiles/.config/hypr/scripts/toggleallfloat.sh`
- Create: `tests/test-runtime-actions.lua`
- Modify: `scripts/check.sh` after Lua syntax validation or near other behavior tests.

**Interfaces:**
- Consumes: `hl.get_active_workspace()`, `workspace:get_windows()`, window properties, and `window.open`, `window.move_to_workspace`, and `workspace.removed` events.
- Produces: `runtime_actions.toggle_all_float() -> { ok: boolean, error?: string }`, private tags `myhypr-allfloat-mode` and `myhypr-allfloat-converted`, and a direct Lua keybind.

- [ ] **Step 1: Create a Lua state-machine test with a fake Hyprland API**

Create `tests/test-runtime-actions.lua` with this deterministic fake and transition sequence:

```lua
local source = debug.getinfo(1, "S").source:sub(2)
local repo_root = assert(source:match("^(.*)/tests/test%-runtime%-actions%.lua$"))
package.path = repo_root .. "/dotfiles/.config/hypr/?.lua;" .. package.path

local callbacks = {}
local notifications = {}
local all_windows = {}
local active_workspace = nil
local forced_failure = nil
local MODE_TAG = "myhypr-allfloat-mode"
local CONVERTED_TAG = "myhypr-allfloat-converted"

local function tag_index(window, wanted)
    for index, tag in ipairs(window.tags or {}) do
        if tag == wanted then return index end
    end
    return nil
end

local function has_tag(window, wanted)
    return tag_index(window, wanted) ~= nil
end

local function dispatcher(kind, opts)
    return { kind = kind, opts = opts or {} }
end

hl = {
    dsp = {
        window = {
            float = function(opts) return dispatcher("float", opts) end,
            tag = function(opts) return dispatcher("tag", opts) end,
        },
    },
    dispatch = function(action)
        if forced_failure == action.kind then
            return { ok = false, error = "forced " .. action.kind .. " failure" }
        end
        local window = action.opts.window
        if action.kind == "float" then
            window.floating = action.opts.action == "set"
        elseif action.kind == "tag" then
            local prefix = action.opts.tag:sub(1, 1)
            local tag = action.opts.tag:sub(2)
            window.tags = window.tags or {}
            local index = tag_index(window, tag)
            if prefix == "+" and not index then
                table.insert(window.tags, tag)
            elseif prefix == "-" and index then
                table.remove(window.tags, index)
            end
        end
        return { ok = true }
    end,
    exec_cmd = function(command) notifications[#notifications + 1] = command end,
    get_active_workspace = function() return active_workspace end,
    get_windows = function() return all_windows end,
    on = function(name, callback) callbacks[name] = callback; return { name = name } end,
}

local function make_workspace(id, windows)
    local workspace = { id = id }
    function workspace:get_windows() return windows end
    for _, window in ipairs(windows) do
        window.workspace = workspace
        all_windows[#all_windows + 1] = window
    end
    return workspace
end

local function success_notifications()
    local count = 0
    for _, command in ipairs(notifications) do
        if command:find("Windows on this workspace toggled", 1, true) then count = count + 1 end
    end
    return count
end

local tiled = { mapped = true, hidden = false, floating = false, tags = {} }
local intentional_float = { mapped = true, hidden = false, floating = true, tags = {} }
local workspace_one = make_workspace(1, { tiled, intentional_float })
active_workspace = workspace_one

package.loaded["conf.runtime_actions"] = nil
local runtime_actions = require("conf.runtime_actions")
local result = runtime_actions.toggle_all_float()
assert(result.ok)
assert(tiled.floating and has_tag(tiled, MODE_TAG) and has_tag(tiled, CONVERTED_TAG))
assert(intentional_float.floating and has_tag(intentional_float, MODE_TAG))
assert(not has_tag(intentional_float, CONVERTED_TAG))

local opened = { mapped = true, hidden = false, floating = false, tags = {}, workspace = workspace_one }
all_windows[#all_windows + 1] = opened
callbacks["window.open"](opened)
assert(opened.floating and has_tag(opened, MODE_TAG) and has_tag(opened, CONVERTED_TAG))

result = runtime_actions.toggle_all_float()
assert(result.ok)
assert(not tiled.floating and not has_tag(tiled, MODE_TAG) and not has_tag(tiled, CONVERTED_TAG))
assert(intentional_float.floating and not has_tag(intentional_float, MODE_TAG))
assert(not opened.floating and not has_tag(opened, MODE_TAG) and not has_tag(opened, CONVERTED_TAG))

assert(runtime_actions.toggle_all_float().ok)
local workspace_two = make_workspace(2, {})
tiled.workspace = workspace_two
callbacks["window.move_to_workspace"](tiled, workspace_two)
assert(not tiled.floating and not has_tag(tiled, MODE_TAG) and not has_tag(tiled, CONVERTED_TAG))

package.loaded["conf.runtime_actions"] = nil
callbacks = {}
runtime_actions = require("conf.runtime_actions")
local after_reload = { mapped = true, hidden = false, floating = false, tags = {}, workspace = workspace_one }
all_windows[#all_windows + 1] = after_reload
callbacks["window.open"](after_reload)
assert(after_reload.floating and has_tag(after_reload, MODE_TAG) and has_tag(after_reload, CONVERTED_TAG))

local failing = { mapped = true, hidden = false, floating = false, tags = {} }
local workspace_three = make_workspace(3, { failing })
active_workspace = workspace_three
local successes_before = success_notifications()
forced_failure = "float"
result = runtime_actions.toggle_all_float()
forced_failure = nil
assert(result.ok == false)
assert(success_notifications() == successes_before)

print("Stateful all-float preserves intentional windows and survives reload markers.")
```

- [ ] **Step 2: Register and run the red Lua test**

Add to `scripts/check.sh`:

```bash
run_check 'Stateful all-float runtime action' lua "$REPO_ROOT/tests/test-runtime-actions.lua"
```

Run:

```bash
lua tests/test-runtime-actions.lua
```

Expected: FAIL because `conf/runtime_actions.lua` does not exist.

- [ ] **Step 3: Implement `conf/runtime_actions.lua`**

Use this module structure:

```lua
local M = {}
local enabled = {}
local subscriptions = {}
local MODE_TAG = "myhypr-allfloat-mode"
local CONVERTED_TAG = "myhypr-allfloat-converted"

local function has_tag(window, wanted)
    for _, tag in ipairs(window.tags or {}) do
        if tag == wanted then return true end
    end
    return false
end

local function dispatch_or_error(action)
    local result = hl.dispatch(action)
    if type(result) == "table" and result.ok == false then
        error(result.error or "Hyprland rejected an all-float action", 0)
    end
end

local function add_tag(window, tag)
    if not has_tag(window, tag) then
        dispatch_or_error(hl.dsp.window.tag({ tag = "+" .. tag, window = window }))
    end
end

local function remove_tag(window, tag)
    if has_tag(window, tag) then
        dispatch_or_error(hl.dsp.window.tag({ tag = "-" .. tag, window = window }))
    end
end

local function enable_window(window)
    if not window.mapped or window.hidden then return end
    if not window.floating then
        dispatch_or_error(hl.dsp.window.float({ action = "set", window = window }))
        add_tag(window, CONVERTED_TAG)
    end
    add_tag(window, MODE_TAG)
end

local function disable_window(window)
    if has_tag(window, CONVERTED_TAG) then
        dispatch_or_error(hl.dsp.window.float({ action = "unset", window = window }))
        remove_tag(window, CONVERTED_TAG)
    end
    remove_tag(window, MODE_TAG)
end

local function notify_failure()
    hl.exec_cmd("notify-send -u critical 'All-float action failed' 'Hyprland rejected the workspace transition'")
end

for _, window in ipairs(hl.get_windows()) do
    if window.workspace and has_tag(window, MODE_TAG) then
        enabled[window.workspace.id] = true
    end
end

function M.toggle_all_float()
    local workspace = hl.get_active_workspace()
    if not workspace then
        notify_failure()
        return { ok = false, error = "No active workspace" }
    end

    local turn_on = not enabled[workspace.id]
    local ok, err = pcall(function()
        for _, window in ipairs(workspace:get_windows()) do
            if turn_on then enable_window(window) else disable_window(window) end
        end
    end)
    if not ok then
        notify_failure()
        return { ok = false, error = tostring(err) }
    end

    enabled[workspace.id] = turn_on or nil
    hl.exec_cmd("notify-send 'Windows on this workspace toggled to floating/tiling'")
    return { ok = true }
end

subscriptions[#subscriptions + 1] = hl.on("window.open", function(window)
    if window.workspace and enabled[window.workspace.id] then
        local ok = pcall(enable_window, window)
        if not ok then notify_failure() end
    end
end)

subscriptions[#subscriptions + 1] = hl.on("window.move_to_workspace", function(window, workspace)
    local ok = pcall(function()
        if workspace and enabled[workspace.id] then enable_window(window) else disable_window(window) end
    end)
    if not ok then notify_failure() end
end)

subscriptions[#subscriptions + 1] = hl.on("workspace.removed", function(workspace)
    if workspace and workspace.id then enabled[workspace.id] = nil end
end)

return M
```

During implementation, make the mock's `window.tags` representation match the real list property while preserving the transition assertions above.

- [ ] **Step 4: Bind the action directly in both variants**

Near the constants at the top of both keybinding modules, add:

```lua
local runtime_actions = require("conf.runtime_actions")
```

Replace the all-float bind in both files with:

```lua
hl.bind(mainMod .. " + SHIFT + T", runtime_actions.toggle_all_float)
```

- [ ] **Step 5: Keep the command-line compatibility entry point fixed and safe**

Replace `toggleallfloat.sh` with:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

exec hyprctl eval "require('conf.runtime_actions').toggle_all_float()"
```

- [ ] **Step 6: Run module, config, and repository validation**

Run:

```bash
lua tests/test-runtime-actions.lua
luac -p dotfiles/.config/hypr/conf/runtime_actions.lua
./scripts/check-hyprland.sh
./scripts/check.sh --quick
```

Expected: the state-machine test passes and all 56 configuration variants remain valid.

- [ ] **Step 7: Audit and commit the stateful action**

Run:

```bash
git add dotfiles/.config/hypr/conf/runtime_actions.lua \
  dotfiles/.config/hypr/conf/keybindings/default.lua \
  dotfiles/.config/hypr/conf/keybindings/fr.lua \
  dotfiles/.config/hypr/scripts/toggleallfloat.sh \
  tests/test-runtime-actions.lua scripts/check.sh
git diff --cached --check
git diff --cached
./scripts/audit.sh --staged
git commit -m 'feat(hyprland): restore stateful workspace all-float'
```

Expected: only the module, two bindings, compatibility script, test, and test registration are committed.

---

### Task 5: Migrate sidepad geometry actions

**Files:**
- Modify: `dotfiles/.config/sidepad/sidepad:224-276`
- Create: `tests/test-sidepad-runtime.sh`
- Modify: `scripts/check.sh` near the desktop action tests.

**Interfaces:**
- Consumes: validated integer geometry and `WINDOW_ADDRESS` matching `^0x[0-9A-Fa-f]+$`.
- Produces: `apply_geometry WIDTH_DELTA HEIGHT_DELTA X_DELTA Y_DELTA`, which dispatches typed relative resize and move actions in that order.

- [ ] **Step 1: Add a focused sidepad geometry test**

Create `tests/test-sidepad-runtime.sh`:

```bash
#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-sidepad-runtime.XXXXXXXX")
FAKE_BIN="$TEST_ROOT/bin"
export SIDEPAD_TEST_LOG="$TEST_ROOT/hyprctl.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-sidepad-runtime.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

mkdir -p -- "$FAKE_BIN"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "$*" in' \
    '  "-j clients") printf "%s\n" '\''[{"class":"myhypr-sidepad-test","address":"0xabc","size":[700,880],"at":[10,100],"pid":1234}]'\'' ;;' \
    '  "-j monitors") printf "%s\n" '\''[{"focused":true,"height":1080}]'\'' ;;' \
    '  *)' \
    '    printf "hyprctl %s\n" "$*" >> "$SIDEPAD_TEST_LOG"' \
    '    if [[ ${SIDEPAD_FAIL_MOVE:-0} -eq 1 && $* == *"hl.dsp.window.move"* ]]; then exit 9; fi' \
    '    ;;' \
    'esac' \
    > "$FAKE_BIN/hyprctl"
chmod +x -- "$FAKE_BIN/hyprctl"

sidepad="$REPO_ROOT/dotfiles/.config/sidepad/sidepad"
PATH="$FAKE_BIN:/usr/bin:/bin" "$sidepad" --class myhypr-sidepad-test \
    > "$TEST_ROOT/success.out"
mapfile -t calls < "$SIDEPAD_TEST_LOG"
[[ ${calls[0]:-} == "hyprctl dispatch hl.dsp.window.resize({ x = 300, y = 0, relative = true, window = 'address:0xabc' })" ]]
[[ ${calls[1]:-} == "hyprctl dispatch hl.dsp.window.move({ x = 0, y = 0, relative = true, window = 'address:0xabc' })" ]]
[[ ${#calls[@]} -eq 2 ]]
rg -Fq 'Operation completed.' "$TEST_ROOT/success.out"

: > "$SIDEPAD_TEST_LOG"
if SIDEPAD_FAIL_MOVE=1 PATH="$FAKE_BIN:/usr/bin:/bin" \
    "$sidepad" --class myhypr-sidepad-test > "$TEST_ROOT/failure.out" 2>&1; then
    printf 'Sidepad accepted a failed move.\n' >&2
    exit 1
fi
! rg -Fq 'Operation completed.' "$TEST_ROOT/failure.out"

printf 'Sidepad geometry uses ordered typed dispatchers.\n'
```

- [ ] **Step 2: Register and run the red test**

Add to `scripts/check.sh`:

```bash
run_check 'Sidepad typed geometry behavior' "$REPO_ROOT/tests/test-sidepad-runtime.sh"
```

Run:

```bash
chmod +x tests/test-sidepad-runtime.sh
./tests/test-sidepad-runtime.sh
```

Expected: FAIL because the helper still emits a token-based `--batch` command.

- [ ] **Step 3: Add the focused geometry dispatcher helper**

After numeric/address validation in `sidepad`, add:

```bash
apply_geometry() {
    local width_delta=$1
    local height_delta=$2
    local x_delta=$3
    local y_delta=$4

    hyprctl dispatch "hl.dsp.window.resize({ x = $width_delta, y = $height_delta, relative = true, window = 'address:$WINDOW_ADDRESS' })"
    hyprctl dispatch "hl.dsp.window.move({ x = $x_delta, y = $y_delta, relative = true, window = 'address:$WINDOW_ADDRESS' })"
}
```

Replace all three repeated batches with:

```bash
apply_geometry "$WIDTH_CHANGE" "$HEIGHT_CHANGE" "$PIXELS_TO_MOVE_X" "$PIXELS_TO_MOVE_Y"
echo "Operation completed."
```

- [ ] **Step 4: Verify and commit sidepad behavior**

Run:

```bash
./tests/test-sidepad-runtime.sh
./scripts/check.sh --quick
git add dotfiles/.config/sidepad/sidepad tests/test-sidepad-runtime.sh scripts/check.sh
git diff --cached --check
git diff --cached
./scripts/audit.sh --staged
git commit -m 'fix(sidepad): use typed Hyprland geometry actions'
```

Expected: the test proves resize-before-move ordering and truthful failure output.

---

### Task 6: Migrate passive desktop integrations and lock in compatibility guards

**Files:**
- Modify: `dotfiles/.config/hypr/hypridle.conf:5,28-29`
- Modify: `dotfiles/.config/waybar/modules.json:11-12`
- Modify: `dotfiles/.config/hypr/scripts/power.sh:43`
- Modify: `dotfiles/.config/wlogout/README.txt:4`
- Modify: `tests/test-waybar-actions.sh`
- Create: `tests/test-hyprland-runtime-api.sh`
- Create: `tests/test-keybindings.lua`
- Modify: `scripts/check.sh`
- Modify: `scripts/doctor.sh` after the Lua entrypoint check.

**Interfaces:**
- Consumes: static on/off, relative workspace, and exit actions; both keybinding variants.
- Produces: typed DPMS/workspace/exit expressions, a zero-legacy-action guard, and verified keybinding counts of 111 default and 107 French binds.

- [ ] **Step 1: Extend Waybar assertions before implementation**

Add to `tests/test-waybar-actions.sh`:

```bash
rg -Fq "\"on-scroll-up\": \"hyprctl dispatch \\\"hl.dsp.focus({ workspace = 'r-1' })\\\"\"" "$modules" || \
    fail 'workspace scroll-up does not use typed focus'
rg -Fq "\"on-scroll-down\": \"hyprctl dispatch \\\"hl.dsp.focus({ workspace = 'r+1' })\\\"\"" "$modules" || \
    fail 'workspace scroll-down does not use typed focus'
```

- [ ] **Step 2: Add the active-runtime compatibility guard**

Create `tests/test-hyprland-runtime-api.sh` with the exact active file list from the design and these checks:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd -- "$REPO_ROOT"
runtime_files=(
    dotfiles/.config/myhypr/scripts/focus.sh
    dotfiles/.config/hypr/scripts/moveTo.sh
    dotfiles/.config/hypr/scripts/cursor-zoom.sh
    dotfiles/.config/hypr/scripts/toggle-animations.sh
    dotfiles/.config/hypr/scripts/gamemode.sh
    dotfiles/.config/hypr/scripts/load-gamemode.sh
    dotfiles/.config/hypr/scripts/toggle-refresh.sh
    dotfiles/.config/hypr/scripts/toggleallfloat.sh
    dotfiles/.config/hypr/scripts/power.sh
    dotfiles/.config/hypr/hypridle.conf
    dotfiles/.config/waybar/modules.json
    dotfiles/.config/sidepad/sidepad
    dotfiles/.config/wlogout/README.txt
)

if rg -n 'hyprctl[[:space:]]+(--batch|keyword)|workspaceopt' "${runtime_files[@]}"; then
    printf 'A deprecated Hyprland runtime action remains.\n' >&2
    exit 1
fi

while IFS= read -r line; do
    [[ $line == *'hl.dsp.'* ]] || {
        printf 'Token-based dispatcher remains: %s\n' "$line" >&2
        exit 1
    }
done < <(rg 'hyprctl[[:space:]]+dispatch' "${runtime_files[@]}")

while IFS= read -r line; do
    [[ $line == *'hl.config('* || $line == *'hl.monitor('* || $line == *"require('conf.runtime_actions')"* ]] || {
        printf 'Unapproved hyprctl eval expression: %s\n' "$line" >&2
        exit 1
    }
done < <(rg 'hyprctl[[:space:]]+eval' "${runtime_files[@]}")

printf 'All active Hyprland runtime mutations use approved typed Lua APIs.\n'
```

- [ ] **Step 3: Add the Lua keybinding inventory**

Create `tests/test-keybindings.lua` with this loader and validator:

```lua
local source = debug.getinfo(1, "S").source:sub(2)
local repo_root = assert(source:match("^(.*)/tests/test%-keybindings%.lua$"))
local expected_counts = { default = 111, fr = 107 }
local required = {
    default = { "SUPER + SHIFT + T", "SUPER + SHIFT + A", "SUPER + ALT + G", "CTRL + Tab", "SUPER + CTRL + 0", "XF86AudioRaiseVolume" },
    fr = { "SUPER + SHIFT + T", "SUPER + SHIFT + A", "SUPER + ALT + G", "CTRL + Tab", "SUPER + CTRL + agrave", "XF86AudioRaiseVolume" },
}
local approved_external = {
    brightnessctl = true, hyprctl = true, hyprlock = true, hyprshot = true,
    pactl = true, playerctl = true, wpctl = true,
}

local doctor_file = assert(io.open(repo_root .. "/scripts/doctor.sh", "r"))
local doctor_source = doctor_file:read("*a")
doctor_file:close()

local function namespace(prefix)
    return setmetatable({}, {
        __index = function(table_value, name)
            local factory = function(...)
                return { kind = prefix .. name, args = { ... } }
            end
            rawset(table_value, name, factory)
            return factory
        end,
    })
end

local runtime_actions = {
    toggle_all_float = function() return { ok = true } end,
}

local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function load_variant(name)
    local bindings = {}
    local dsp = namespace("hl.dsp.")
    dsp.window = namespace("hl.dsp.window.")
    dsp.group = namespace("hl.dsp.group.")
    dsp.cursor = namespace("hl.dsp.cursor.")
    dsp.workspace = namespace("hl.dsp.workspace.")
    local mock_hl = {
        dsp = dsp,
        bind = function(key, action)
            assert(type(key) == "string" and action ~= nil)
            bindings[#bindings + 1] = { key = key, action = action }
        end,
    }
    local environment = setmetatable({
        hl = mock_hl,
        require = function(module)
            assert(module == "conf.runtime_actions")
            return runtime_actions
        end,
    }, { __index = _G })
    local path = repo_root .. "/dotfiles/.config/hypr/conf/keybindings/" .. name .. ".lua"
    assert(loadfile(path, "t", environment))()
    return bindings
end

for _, name in ipairs({ "default", "fr" }) do
    local bindings = load_variant(name)
    assert(#bindings == expected_counts[name], name .. " binding count changed")
    local keys = {}
    local direct_all_float = false
    for _, binding in ipairs(bindings) do
        keys[binding.key] = true
        if binding.key == "SUPER + SHIFT + T" then
            direct_all_float = binding.action == runtime_actions.toggle_all_float
        end
        if type(binding.action) == "table" and binding.action.kind == "hl.dsp.exec_cmd" then
            local command = assert(binding.action.args[1])
            local executable = assert(command:match("^([^%s]+)"))
            if executable:sub(1, 10) == "~/.config/" then
                local managed = repo_root .. "/dotfiles" .. executable:sub(2)
                local file = assert(io.open(managed, "r"), "missing managed command: " .. managed)
                file:close()
                assert(os.execute("test -x " .. shell_quote(managed)), "managed command is not executable: " .. managed)
            else
                assert(approved_external[executable], "unapproved external command: " .. executable)
                assert(doctor_source:find(executable, 1, true), "doctor does not check: " .. executable)
            end
        end
    end
    for _, key in ipairs(required[name]) do
        assert(keys[key], name .. " lost required key " .. key)
    end
    assert(direct_all_float, name .. " all-float bind still spawns a shell helper")
end

print("Both keybinding variants preserve counts and resolve every command.")
```

- [ ] **Step 4: Register the guards and observe the remaining failures**

Add to `scripts/check.sh`:

```bash
run_check 'Hyprland typed runtime API guard' "$REPO_ROOT/tests/test-hyprland-runtime-api.sh"
run_check 'Keybinding inventory and command resolution' lua "$REPO_ROOT/tests/test-keybindings.lua"
```

Run:

```bash
chmod +x tests/test-hyprland-runtime-api.sh
./tests/test-waybar-actions.sh
./tests/test-hyprland-runtime-api.sh
lua tests/test-keybindings.lua
```

Expected: Waybar and runtime guard fail on the remaining workspace, DPMS, and exit calls; keybinding inventory passes after Task 4's direct bind.

- [ ] **Step 5: Replace the passive integrations with typed expressions**

Use these exact commands:

```text
hyprctl dispatch "hl.dsp.dpms({ action = 'on' })"
hyprctl dispatch "hl.dsp.dpms({ action = 'off' })"
hyprctl dispatch "hl.dsp.focus({ workspace = 'r-1' })"
hyprctl dispatch "hl.dsp.focus({ workspace = 'r+1' })"
hyprctl dispatch 'hl.dsp.exit()'
```

In JSON, escape the outer double quotes around the Waybar dispatcher expression. Keep `brightnessctl -r` chained only after a successful typed DPMS-on action. Update the wlogout README example to the same `hl.dsp.exit()` syntax.

- [ ] **Step 6: Add a safe runtime capability check to doctor**

After confirming `hyprland.lua` exists, add:

```bash
if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
    if hyprctl dispatch 'hl.dsp.no_op()' >/dev/null 2>&1 && \
        hyprctl eval 'assert(type(hl.config) == "function" and type(hl.monitor) == "function" and type(hl.dsp.window.move) == "function")' >/dev/null 2>&1; then
        ok 'Hyprland typed Lua runtime API is available'
    else
        problem 'Hyprland typed Lua runtime API is unavailable'
    fi
fi
```

These checks are non-destructive: one no-op dispatcher and capability assertions only.

- [ ] **Step 7: Run every compatibility guard and full static validation**

Run:

```bash
./tests/test-waybar-actions.sh
./tests/test-hyprland-runtime-api.sh
lua tests/test-keybindings.lua
./scripts/check.sh
```

Expected: the guard finds no deprecated runtime action and all 56 Hyprland variants pass.

- [ ] **Step 8: Audit and commit the integration guard slice**

Run:

```bash
git add dotfiles/.config/hypr/hypridle.conf \
  dotfiles/.config/waybar/modules.json \
  dotfiles/.config/hypr/scripts/power.sh \
  dotfiles/.config/wlogout/README.txt \
  tests/test-waybar-actions.sh tests/test-hyprland-runtime-api.sh \
  tests/test-keybindings.lua scripts/check.sh scripts/doctor.sh
git diff --cached --check
git diff --cached
./scripts/audit.sh --staged
git commit -m 'test(hyprland): enforce typed runtime actions'
```

Expected: the staged audit passes and no private runtime data is present.

---

### Task 7: Perform controlled live verification and local-main integration

**Files:**
- Verify: all files changed in Tasks 1–6.
- No new source file is required unless a live check exposes a reproducible defect; any defect returns to the relevant task's red-green cycle.

**Interfaces:**
- Consumes: all committed migration slices, the rollback tag, and the running graphical session.
- Produces: a clean local `main`, active `myhypr-session.target`, zero Hyprland config errors, healthy desktop components, and evidence for safe shortcut behavior.

- [ ] **Step 1: Run final repository and history-aware security gates**

Run:

```bash
./scripts/check.sh
./scripts/audit.sh
git diff pre-hyprland-lua-actions-2026-08-23..HEAD --check
git status --short --branch
```

Expected: all tests and 56 configurations pass, the audit reports no leak, the range has no whitespace error, and the implementation branch is clean.

- [ ] **Step 2: Review the complete migration range**

Run:

```bash
git log --oneline --decorate pre-hyprland-lua-actions-2026-08-23..HEAD
git diff --stat pre-hyprland-lua-actions-2026-08-23..HEAD
git diff pre-hyprland-lua-actions-2026-08-23..HEAD -- \
  dotfiles/.config/hypr dotfiles/.config/myhypr \
  dotfiles/.config/waybar dotfiles/.config/sidepad \
  dotfiles/.config/wlogout scripts tests
```

Expected: only the designed runtime migration, tests, and doctor/check registrations appear; no colors, wallpaper paths, credentials, or generated private files appear.

- [ ] **Step 3: Merge the reviewed branch to local `main`**

Use the execution workflow's required finishing skill. Perform a local fast-forward or reviewed merge, then verify:

```bash
git branch --show-current
git status --short --branch
git log -8 --oneline --decorate
```

Expected: current branch is `main`, the tree is clean, and all migration commits are reachable from `main`. Do not push.

- [ ] **Step 4: Reload Hyprland and verify the selected binding variant**

Run in the real graphical session:

```bash
hyprctl reload
hyprctl configerrors
selector=$(<"$HOME/.config/hypr/conf/keybinding.conf")
case $selector in
    *'/fr.conf') expected_binds=107 ;;
    *) expected_binds=111 ;;
esac
actual_binds=$(hyprctl -j binds | jq 'length')
[[ $actual_binds -eq $expected_binds ]]
```

Expected: `configerrors` is empty and the bind count matches the selected variation.

- [ ] **Step 5: Reactivate the graphical session target without sudo**

Run:

```bash
systemctl --user start myhypr-session.target
systemctl --user is-active myhypr-session.target elephant.service walker.service
systemctl --user --failed --no-legend
```

Expected: all three named units are active and no MyHypr user unit is failed. This is a user-session operation and must not request repeated sudo authentication.

- [ ] **Step 6: Exercise safe actions with disposable windows**

Use a unique class and a cleanup trap so every exit path restores the original workspace and closes the disposable window:

```bash
original_workspace=$(hyprctl -j activeworkspace | jq -er '.id')
scratch_workspace=98
[[ $original_workspace -eq 98 ]] && scratch_workspace=97
test_class="myhypr-runtime-test-$$"
test_pid=''
cleanup_live_test() {
    [[ -z $test_pid ]] || kill "$test_pid" 2>/dev/null || true
    hyprctl dispatch "hl.dsp.focus({ workspace = $original_workspace })" >/dev/null 2>&1 || true
}
trap cleanup_live_test EXIT

hyprctl dispatch "hl.dsp.focus({ workspace = $scratch_workspace })"
kitty --class "$test_class" --title "$test_class" &
test_pid=$!
for attempt in $(seq 1 50); do
    test_address=$(hyprctl -j clients | jq -er --arg class "$test_class" \
        '.[] | select(.class == $class) | .address' 2>/dev/null || true)
    [[ $test_address =~ ^0x[0-9A-Fa-f]+$ ]] && break
    sleep 0.1
done
[[ $test_address =~ ^0x[0-9A-Fa-f]+$ ]]
hyprctl dispatch "hl.dsp.focus({ window = 'address:$test_address' })"
~/.config/hypr/scripts/toggleallfloat.sh
hyprctl -j clients | jq -e --arg address "$test_address" '.[] | select(.address == $address and .floating == true)'
~/.config/hypr/scripts/toggleallfloat.sh
hyprctl -j clients | jq -e --arg address "$test_address" '.[] | select(.address == $address and .floating == false)'

target_workspace=''
for candidate in $(seq 1 10); do
    count=$(hyprctl -j clients | jq --argjson workspace "$candidate" \
        '[.[] | select(.workspace.id == $workspace)] | length')
    if [[ $count -eq 0 ]]; then target_workspace=$candidate; break; fi
done
if [[ -n $target_workspace ]]; then
    ~/.config/hypr/scripts/moveTo.sh "$target_workspace"
    hyprctl -j clients | jq -e --arg address "$test_address" --argjson workspace "$target_workspace" \
        '.[] | select(.address == $address and .workspace.id == $workspace)'
    hyprctl dispatch "hl.dsp.window.move({ workspace = $scratch_workspace, follow = false, window = 'address:$test_address' })"
    hyprctl dispatch "hl.dsp.focus({ workspace = $scratch_workspace })"
fi

hyprctl dispatch "hl.dsp.window.float({ action = 'set', window = 'address:$test_address' })"
~/.config/sidepad/sidepad --class "$test_class" --width 700 --width-max 800 \
    --top-gap 100 --bottom-gap 100
hyprctl -j clients | jq -e --arg address "$test_address" \
    '.[] | select(.address == $address and .floating == true and (.size[0] == 700 or .size[0] == 800))'

cleanup_live_test
trap - EXIT
```

Then run the mocked focus, workspace-move, monitor, and sidepad tests once more. If no numbered workspace is empty, the live `moveTo.sh` branch is skipped and its mock test remains the evidence for that action. Do not trigger exit, DPMS off, suspend, hibernate, reboot, or shutdown.

- [ ] **Step 7: Exercise reversible configuration actions and restore state**

Run cursor and marker-backed toggles with explicit restoration checks:

```bash
original_zoom=$(hyprctl -j getoption cursor:zoom_factor | jq -er '.float // .int')
~/.config/hypr/scripts/cursor-zoom.sh increase
hyprctl eval "hl.config({ cursor = { zoom_factor = $original_zoom } })"

animation_marker="$HOME/.cache/myhypr/animations-disabled"
animation_before=0
[[ -f $animation_marker ]] && animation_before=1
~/.config/hypr/scripts/toggle-animations.sh
~/.config/hypr/scripts/toggle-animations.sh
animation_after=0
[[ -f $animation_marker ]] && animation_after=1
[[ $animation_before -eq $animation_after ]]

gamemode_marker="$HOME/.config/myhypr/settings/gamemode-enabled"
gamemode_before=0
[[ -f $gamemode_marker ]] && gamemode_before=1
~/.config/hypr/scripts/gamemode.sh
~/.config/hypr/scripts/gamemode.sh
gamemode_after=0
[[ -f $gamemode_marker ]] && gamemode_after=1
[[ $gamemode_before -eq $gamemode_after ]]
```

For refresh rate, run the toggle twice only when the focused monitor's current rate matches its lowest or highest advertised rate:

```bash
monitor_json=$(hyprctl -j monitors | jq -ce 'map(select(.focused))[0]')
current_rate=$(jq -r '.refreshRate' <<< "$monitor_json")
mapfile -t endpoint_rates < <(jq -r '.availableModes[] | capture("@(?<rate>[0-9.]+)Hz?$") | .rate' \
    <<< "$monitor_json" | sort -n -u)
low_rate=${endpoint_rates[0]}
high_rate=${endpoint_rates[${#endpoint_rates[@]} - 1]}
if awk -v current="$current_rate" -v low="$low_rate" -v high="$high_rate" \
    'BEGIN { dl=current-low; if(dl<0)dl=-dl; dh=current-high; if(dh<0)dh=-dh; exit !(dl<0.1 || dh<0.1) }'; then
    ~/.config/hypr/scripts/toggle-refresh.sh toggle
    ~/.config/hypr/scripts/toggle-refresh.sh toggle
    restored_rate=$(hyprctl -j monitors | jq -r 'map(select(.focused))[0].refreshRate')
    awk -v before="$current_rate" -v after="$restored_rate" \
        'BEGIN { d=before-after; if(d<0)d=-d; exit !(d<0.1) }'
fi
```

Expected: zoom, animation marker, gamemode marker, and eligible refresh rate end at their starting values.

- [ ] **Step 8: Verify desktop appearance and component health**

Run:

```bash
pgrep -a waybar
pgrep -a nwg-dock-hyprland
pgrep -a quickshell
pgrep -a swaync
awww query
rg -Fx 'off' "$HOME/.config/myhypr/settings/wallpaper-effect.sh"
./scripts/doctor.sh --profile desktop --quick
```

Expected: Waybar, themed dock, QuickShell, SwayNC, and wallpaper daemon are running; wallpaper effects remain off; doctor reports zero errors. Confirm visually that wallpaper colors, Waybar colors, and dock styling match the pre-migration desktop.

- [ ] **Step 9: Run the final audit on local `main` and record completion**

Run:

```bash
./scripts/check.sh
./scripts/audit.sh --history
git status --short --branch
git describe --tags --always
```

Expected: validation and full history-aware audit pass, local `main` is clean, and the rollback tag remains reachable. Report commit IDs, test evidence, live checks, and that no push occurred.
