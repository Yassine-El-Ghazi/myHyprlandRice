# Hyprland Lua Runtime Compatibility Design

Status: approved for specification on 2026-08-23; implementation awaits review of this document.

## Context

MyHyprlandRice now uses Hyprland's Lua configuration provider. Hyprland 0.56.2 still exposes read-only `hyprctl` queries and the `reload`, `notify`, and `eval` commands, but legacy `hyprctl keyword ...`, token-based `hyprctl dispatch ...`, and `hyprctl --batch` actions are not compatible with the Lua provider. The old `workspaceopt` dispatcher is explicitly deprecated and unavailable.

The active configuration loads `hyprland.lua` and registers 111 Lua keybindings without configuration errors, but several bound shell helpers still issue legacy runtime commands. Those helpers can therefore appear registered while doing nothing or returning an error when invoked.

This change migrates every active legacy runtime action to Hyprland's typed Lua API while preserving the existing keys, appearance, notifications, and user-visible behavior.

## Goals

- Make every currently configured shortcut work on Hyprland 0.56.2's Lua provider.
- Preserve the current key combinations and action semantics.
- Preserve the existing wallpaper, colors, Waybar layout, dock appearance, and application choices.
- Replace legacy runtime mutations with official typed Lua configuration and dispatcher APIs.
- Keep all dynamic values constrained so `hyprctl eval` never becomes a generic code-execution interface.
- Cover stateful and destructive actions without logging out, suspending, or disrupting the user's live session during tests.
- Add a compatibility guard so deprecated runtime syntax cannot silently return in a later change.

## Non-goals

- Reassigning shortcuts or redesigning the keybinding scheme.
- Replacing shell helpers whose work is not a Hyprland runtime mutation.
- Removing the legacy `.conf` selector files used by the settings UI as portable variation metadata.
- Changing desktop theming, wallpaper selection, Waybar styling, or dock styling.
- Supporting the retired Hyprlang configuration provider.
- Running logout, DPMS-off, suspend, hibernate, reboot, or shutdown as part of verification.

## Chosen architecture

Use the official typed API at each action's existing boundary:

1. Shell helpers continue to query Hyprland with JSON where they need external selection or arithmetic.
2. A fixed `hyprctl dispatch "hl.dsp..."` expression performs typed dispatcher actions.
3. A fixed `hyprctl eval "hl.config(...)"` or `hyprctl eval "hl.monitor(...)"` expression performs runtime configuration changes.
4. Dynamic shell values are validated with narrow allowlists before interpolation. No helper accepts an arbitrary Lua expression.
5. The removed `workspaceopt allfloat` behavior is implemented once in a small native Lua module and bound directly as a Lua function. It is not emulated through a generic legacy-dispatch wrapper.

This keeps the implementation close to Hyprland's supported interface and limits custom compatibility code to the one behavior Hyprland removed.

## Runtime action mapping

| Existing consumer | Legacy operation | Typed replacement | Behavior preserved |
| --- | --- | --- | --- |
| `~/.config/myhypr/scripts/focus.sh` | `dispatch focuswindow` | `hl.dsp.focus({ window = "address:..." })` | Focus the exact menu-selected window. |
| `~/.config/hypr/scripts/moveTo.sh` | `movetoworkspacesilent`, then `workspace` | `hl.dsp.window.move({ workspace = N, follow = false, window = ... })`, then `hl.dsp.focus({ workspace = N })` | Move every window from the active workspace without following each one, then switch once. |
| `~/.config/hypr/scripts/cursor-zoom.sh` | `keyword cursor:zoom_factor` | `hl.config({ cursor = { zoom_factor = N } })` | Keep the current 1.0–5.0 range and 0.5 steps. |
| `~/.config/hypr/scripts/toggle-animations.sh` | `keyword animations:enabled` | `hl.config({ animations = { enabled = BOOL } })` | Preserve the selector override and cache marker. |
| `~/.config/hypr/scripts/gamemode.sh` | batched `keyword` calls | One typed `hl.config({...})` table | Preserve animation, blur, shadow, gaps, border, opacity, and rounding changes. |
| `~/.config/hypr/scripts/load-gamemode.sh` | batched `keyword` calls | One typed `hl.config({...})` table | Reapply the persisted gamemode subset after startup. |
| `~/.config/hypr/scripts/toggle-refresh.sh` | `keyword monitor` | `hl.monitor({ output = NAME, mode = MODE, position = POSITION, scale = SCALE, transform = TRANSFORM })` | Preserve low/high refresh selection on the focused monitor. |
| `~/.config/hypr/scripts/toggleallfloat.sh` and the `SUPER+SHIFT+T` binds | deprecated `workspaceopt allfloat` | `conf.runtime_actions.toggle_all_float` | Toggle only the active workspace, retain intentionally floating windows, and float new tiled windows while the mode is enabled. |
| `~/.config/hypr/scripts/power.sh exit` | `dispatch exit` | `hl.dsp.exit()` | Preserve graceful client termination before compositor exit. |
| `~/.config/hypr/hypridle.conf` | `dispatch dpms on/off` | `hl.dsp.dpms({ action = "on"|"off" })` | Preserve wake, timeout, and resume behavior. |
| `~/.config/waybar/modules.json` | `dispatch workspace r-1/r+1` | `hl.dsp.focus({ workspace = "r-1"|"r+1" })` | Preserve workspace scrolling from Waybar. |
| `~/.config/sidepad/sidepad` | batched pixel resize/move dispatchers | `hl.dsp.window.resize({... relative = true ...})` followed by `hl.dsp.window.move({... relative = true ...})` | Preserve hide, show, and width-toggle geometry. |
| `~/.config/wlogout/README.txt` | documented token-based exit command | documented `hl.dsp.exit()` expression | Keep copied examples valid. |

Read-only commands such as `hyprctl -j clients`, `hyprctl -j monitors`, and `hyprctl -j getoption`, plus `hyprctl reload` and `hyprctl notify`, remain unchanged.

## Stateful all-float compatibility

Hyprland removed `workspaceopt`, so there is no one-line typed replacement. A new `conf/runtime_actions.lua` module will provide the missing behavior through supported Lua objects and dispatchers.

The module will:

- Keep enabled state by workspace ID.
- On enable, inspect `active_workspace:get_windows()` and float only mapped, visible, currently tiled windows.
- Mark every window participating in the enabled workspace mode with a private `myhypr-allfloat-mode` tag, including windows that were already floating.
- Mark only windows actually converted by this action with a second private `myhypr-allfloat-converted` tag.
- Listen for `window.open` and apply the same mode/conversion marking to new windows opened on an enabled workspace.
- On disable, tile only `myhypr-allfloat-converted` windows, remove both private tags, and leave intentionally floating windows floating.
- Listen for `window.move_to_workspace`: apply mode and conversion tags when entering an enabled workspace; remove mode, undo a prior conversion, and remove conversion state when entering a normal workspace.
- Clear state for removed workspaces.
- Check every `hl.dispatch(...)` result and report a failure without announcing success.
- Send the existing success notification only after the transition completes.

The default and French Lua keybinding variants will bind `SUPER+SHIFT+T` directly to the module function, avoiding a shell process for the normal path. `toggleallfloat.sh` remains as a fixed-expression command-line compatibility entry point for menus or manual use.

State is session-local by design. Configuration reload handling will reconstruct enabled workspaces from `myhypr-allfloat-mode` tags on existing windows, including workspaces whose existing windows were all floating before the mode was enabled. No state or window identifiers are written to the Git repository. An empty workspace has no windows to affect; after a reload it returns to the normal default tiling mode.

## Input validation and security

Every shell-generated Lua value must pass validation before `hyprctl` is called:

- Window addresses: `^0x[0-9A-Fa-f]+$`.
- Shortcut workspace targets: integers 1 through 10.
- Monitor names: letters, digits, dot, underscore, colon, and hyphen only.
- Width, height, and transform: bounded integers; transform is 0 through 7.
- Refresh rate, scale, and cursor zoom: positive decimal numbers in their action-specific bounds.
- Monitor position: two signed integers separated by `x`.

Expressions use fixed field names and fixed control flow. There will be no `eval` helper that accepts caller-provided code, no interpolation of window titles or application classes, and no shell `eval`.

State markers are updated only after the corresponding Hyprland action succeeds. Temporary files retain the existing narrow path checks. The repository privacy/security audit runs before every commit.

## Error handling

- Shell helpers use `set -Eeuo pipefail` and explicit dependency checks.
- A failed typed dispatcher or configuration call produces a nonzero helper exit and suppresses the success notification.
- `moveTo.sh` validates the destination before moving any window and stops before switching workspaces if a move fails.
- Gamemode and animation marker files change only after Hyprland accepts the new configuration.
- Monitor changes retain the current retry logic and report malformed monitor data before constructing Lua.
- Sidepad reports a failed resize or move instead of claiming completion.
- The all-float module retains enough marking information to avoid tiling windows it did not convert.

## Test-first implementation

Each migration is implemented as a red-green-refactor cycle:

1. Update or add a focused test that expects the typed API and observe it fail against the current code.
2. Make the smallest action migration that passes that test.
3. Run the focused test, then the quick repository validation.
4. Commit a cohesive, audited slice before moving to the next action family.

The test suite will include:

- Updated mock assertions for window focus, cursor zoom, and monitor refresh.
- New mock tests for workspace-content moves, animation/gamemode configuration, sidepad geometry, Waybar scrolling, Hypridle DPMS, and compositor exit syntax.
- A Lua unit test with fake workspace/window objects for all-float enable, new-window handling, disable, intentional-float preservation, and failure reporting.
- A repository guard that rejects active `hyprctl keyword`, `hyprctl --batch`, token-based dispatcher calls, and the deprecated `workspaceopt` action.
- A required-shortcut inventory that verifies both keybinding variants retain their expected keys and that every script-backed bind resolves to an installed or repository-managed command.

## Live verification

After all automated tests pass:

1. Run `./scripts/check.sh` and require all validation groups and all 56 generated Hyprland configurations to pass.
2. Run `./scripts/audit.sh` and require privacy, secret, and insecure-pattern scans to pass.
3. Reload Hyprland and require `hyprctl configerrors` to remain empty.
4. Confirm the expected binding count and required key combinations through `hyprctl -j binds`.
5. Exercise safe actions with controlled scratch windows: focus, all-float on/off, move-to-workspace, and sidepad geometry.
6. Exercise non-destructive configuration actions and restore their starting values: cursor zoom, animations, gamemode settings, and refresh rate where the current monitor exposes both modes.
7. Verify Waybar, the dock, QuickShell, notifications, wallpaper color, and the graphical session target remain healthy after the reload.
8. Validate power exit, DPMS off, suspend, hibernate, reboot, and shutdown through unit/static checks only; do not trigger them in the live session.

## Rollout and rollback

- Start from a clean, fully audited commit on `main`.
- Create a named pre-migration rollback tag before implementation.
- Commit each independently verified compatibility slice with only its tests and implementation.
- Review `git diff --cached`, run the full privacy/security audit, and inspect staged paths before every commit.
- Do not push without an explicit user request.
- Roll back a faulty slice with `git revert <commit>`; restore the entire pre-migration state from the named tag if needed.

## Acceptance criteria

- No active runtime file contains `hyprctl keyword`, `hyprctl --batch`, `workspaceopt`, or a token-based Hyprland dispatcher call.
- All current key combinations remain present in both the default and French variants.
- Stateful all-float behavior preserves pre-existing floating windows and handles newly opened tiled windows.
- `./scripts/check.sh` passes, including 56 Hyprland configuration variants.
- `./scripts/audit.sh` passes with no private data or secret finding.
- The live compositor reports no configuration errors after reload.
- Waybar, dock, QuickShell, wallpaper, notifications, session services, and safe shortcuts are verified healthy.
- All changes are committed on local `main`, with a documented rollback point and no unrequested push.

## Authoritative references

- Hyprland 0.56.2 `hyprctl` manual source: <https://github.com/hyprwm/Hyprland/blob/v0.56.2/docs/hyprctl.1.rst>
- Hyprland 0.56.2 typed Lua dispatcher bindings: <https://github.com/hyprwm/Hyprland/blob/v0.56.2/src/config/lua/bindings/LuaBindingsDispatchers.cpp>
- Hyprland dispatcher concepts: <https://wiki.hypr.land/Configuring/Basics/Dispatchers/>
- Hyprland source showing `workspaceopt` is deprecated: <https://github.com/hyprwm/Hyprland/blob/v0.56.2/src/config/legacy/DispatcherTranslator.cpp>
