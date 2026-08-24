# Publication Readiness Hardening Design

Status: approved in chat on 2026-08-24; implementation awaits review of this written specification.

## Context

MyHyprlandRice is functionally independent from ML4W and currently runs the user's Hyprland desktop, Waybar, dock, QuickShell, notifications, wallpaper system, and local settings. The local `main` branch is 35 commits ahead of the public `origin/main`, and the working tree is clean. Local validation currently reports all checks passing, including 56 generated Hyprland configurations.

A release review found that the local green result does not yet reproduce the clean GitHub Actions environment. It also found one broken default screenshot shortcut path, an incomplete Stow rollback path, and gaps in the publication audit. These are release blockers because a fresh-machine bootstrap, a staged commit, or the first remote CI run could fail even though the current desktop appears healthy.

This change hardens those boundaries without changing the visible desktop. Wallpapers, colors, themes, Waybar layout, dock appearance, shortcuts, and normal interaction semantics remain as they are now.

## Goals

- Make the checked-in GitHub Actions workflow pass in its exact Arch Linux container environment.
- Make all 56 Hyprland configuration checks independent of the caller's host runtime environment.
- Restore the no-argument screenshot flow used by the configured interactive shortcut.
- Make Stow conflict replacement transactional when the real Stow operation fails after a successful simulation.
- Make pre-commit validation inspect the staged snapshot rather than unrelated worktree content.
- Apply privacy and unsafe-pattern policy consistently to current content and reachable Git history, and apply large-file policy to the complete index being published.
- Document the provenance and license status of every tracked visual asset before public release.
- Preserve the current visual result, including every wallpaper. Lossless optimization is allowed; visible replacement or removal is not.
- Finish with audited logical commits on local `main`, a rollback point, an independent review, and a copyable push command. Do not push without a separate explicit request.

## Non-goals

- Redesigning the desktop, changing its color palette, or choosing different wallpapers.
- Reassigning shortcuts or changing the Waybar and dock interaction model.
- Reintroducing an ML4W runtime, update, package, Flatpak, or GitHub dependency.
- Rewriting already-public Git history unless a confirmed secret or private value makes that necessary.
- Adding a general-purpose release framework, package manager abstraction, or asset-management service.
- Exercising logout, suspend, hibernate, reboot, shutdown, DPMS-off, or other disruptive actions during live verification.
- Pushing to GitHub or repairing GitHub credentials as part of repository hardening.

## Release blockers

The implementation addresses these verified findings as one publication-readiness project:

1. `qt6-declarative` installs Qt 6's `qmllint` at `/usr/lib/qt6/bin/qmllint` in the Arch CI image, while `scripts/check.sh` only searches `PATH`. The required-tools run can therefore reject a correctly installed dependency.
2. `scripts/check-hyprland.sh` does not provide `XDG_RUNTIME_DIR`. A clean environment aborts Hyprland before any configuration is checked.
3. `dotfiles/.config/hypr/scripts/screenshot.sh` reads bare `$1` under `set -u` when invoked without arguments. The configured interactive screenshot shortcut therefore exits before opening its menu.
4. `scripts/link-dotfiles.sh` restores backed-up conflicts after simulation failure but not after failure of the real Stow operation. A failed fresh-machine link can leave user files only in the backup and retain partial links.
5. `scripts/audit.sh --staged` scans staged blobs for secrets but runs quick validation against the worktree. A staged defect can be hidden by an unstaged fix, and a valid staged snapshot can be rejected by unrelated worktree edits.
6. Large-file policy only checks staged additions. The repository already contains an 11,633,376-byte wallpaper, so the stated 10 MiB policy is neither complete nor consistently enforced.
7. The reachable-history scan checks secret signatures but omits machine-specific home paths and the repository's unsafe-pattern rules.
8. The repository has project-level licensing and derivative attribution, but no path-level provenance and license manifest for its 27 tracked visual assets.

## Chosen architecture

Keep the existing shell-based validation and bootstrap structure, but strengthen each boundary in place. Small helpers will isolate tool discovery, temporary runtime setup, snapshot materialization, and rollback bookkeeping so they can be tested independently. Existing public command interfaces remain stable:

- `./scripts/check.sh [--quick] [--require-tools]`
- `./scripts/audit.sh [--staged] [--history]`
- `./scripts/link-dotfiles.sh [options]`
- the existing screenshot script and keybindings

The work is divided into six cohesive units: deterministic CI tools, isolated Hyprland validation, screenshot argument handling, transactional Stow rollback, snapshot/history audit hardening, and asset publication policy. Each unit receives a failing regression test before its implementation change.

## Deterministic CI tool resolution

`scripts/check.sh` will resolve Qt 6's QML linter once and use the resolved executable for the QuickShell check. Resolution order is:

1. `qmllint` found through `command -v`.
2. The canonical Arch Qt 6 path `/usr/lib/qt6/bin/qmllint` when it is executable.
3. Unavailable, which keeps the current skip behavior unless `--require-tools` turns skips into failures.

The check label and CLI remain unchanged. The workflow continues installing `qt6-declarative`; it does not install Qt 5 merely to place a second `qmllint` on `PATH`. A small resolver helper accepts a command name followed by explicit fallback paths. A focused test runs with a constrained `PATH` and passes a temporary executable as the fallback, proving the same path-selection logic without writing to `/usr/lib` or depending on the developer machine.

The final container verification uses the same `archlinux:base-devel` image and the exact dependency list from `.github/workflows/validate.yml`. A local `/usr/bin/qmllint` owned by Qt 5 is not accepted as evidence for this criterion.

## Isolated Hyprland verification

`scripts/check-hyprland.sh` will create both an audit home and a private runtime directory inside that temporary tree. The runtime directory will:

- be created before the first Hyprland invocation;
- have mode `0700`;
- be supplied as `XDG_RUNTIME_DIR` together with the existing isolated `HOME` and `XDG_CONFIG_HOME` values;
- be removed by the existing guarded cleanup when validation exits.

Every one of the 56 generated variants uses the same isolated runtime environment. The script will not borrow the live session's runtime directory or socket state. A regression test clears the caller's `XDG_RUNTIME_DIR`, supplies a fake Hyprland executable, and asserts that every invocation receives an existing private directory with the required mode. A clean-environment invocation of the real `Hyprland --verify-config` then proves the original abort is gone.

## Screenshot argument safety

The screenshot script will normalize the optional first argument once, then dispatch instant modes with a nounset-safe `case` statement. Supported behavior remains:

- `--instant` captures the full screen immediately;
- `--instant-area` starts area capture;
- no argument opens the existing interactive Rofi sequence;
- an unrecognized argument follows the existing interactive behavior.

The regression test uses a temporary configuration home and fake external commands. It invokes the script with no arguments and proves the first Rofi selection is reached without performing a real capture. Separate assertions retain both instant-mode paths. Cancellation is treated as a successful no-op, matching normal interactive use.

## Transactional Stow rollback

Conflict backup and Stow linking will be treated as one transaction. Before moving any conflict, the linker records the managed target links that already exist for tracked package paths. The dry run and simulation behavior remain unchanged.

If the real `stow --restow --no-folding` operation succeeds, the transaction is committed and normal runtime-state migration continues. If it fails after a successful simulation, rollback executes in this order:

1. Inspect only target paths corresponding to tracked package files; do not recursively delete arbitrary target content.
2. Remove links newly created by this transaction only when they resolve into this repository's `dotfiles` package and were not in the pre-transaction managed-link record.
3. Remove only empty parent directories created along those managed paths, stopping at the target root and preserving shared directories such as `.config`.
4. Restore every moved conflict from the timestamped backup to its original path.
5. Preserve all valid managed links that existed before the transaction.
6. Exit nonzero with the real Stow failure clearly reported.

Rollback tolerates a missing partial link or an already-created parent directory. It never overwrites an unexpected path during restoration; such a condition produces a precise error and leaves the recoverable backup intact.

The Stow fixture will include a fake executable whose simulation succeeds and whose real invocation creates one partial managed link before exiting with code 42. The test asserts that the original conflict is restored, the partial link is removed, an existing valid managed link is unchanged, unrelated target files are unchanged, and the command remains unsuccessful. Existing tests for simulation failure, successful backup, dry-run behavior, stale links, and runtime-state migration continue to pass.

## Staged-snapshot audit

In staged mode, every validation decision must describe the Git index. Secret and filename checks continue reading index blobs with `git show ":$file"`. For quick repository validation, the audit creates a temporary snapshot with this flow:

1. Create a guarded temporary directory.
2. Materialize the complete index with `git checkout-index --all --prefix="$snapshot/"`.
3. Initialize temporary Git metadata and stage the snapshot so checks that use `git ls-files` see the same file set.
4. Run the snapshot's own `scripts/check.sh --quick` from inside the snapshot.
5. Remove the temporary tree through a guarded trap on success, failure, or interruption.

This makes staged script changes test themselves and prevents unstaged content from influencing the result. It does not mutate the caller's index or worktree.

Regression fixtures cover both directions: invalid staged content with a valid unstaged repair must fail, while a valid staged snapshot with an invalid unstaged edit must pass its staged validation. The normal worktree and history modes continue validating the current checkout directly.

## Privacy and history policy

The current high-confidence and generic secret patterns remain in place. Reachable-history scanning will apply the same machine-specific home-path rule and unsafe-pattern rule used for current files, while preserving the deliberate exception that prevents `scripts/audit.sh` from matching its own pattern definitions. Each unique reachable blob is still scanned once, and findings report only paths and categories rather than secret contents.

Tests build disposable Git repositories containing historical-only examples. They verify detection of a non-placeholder absolute home path and an unsafe command after those values have been removed from the current tip. Placeholder homes such as `/home/user` and the audit implementation's own pattern text remain accepted.

No history rewrite is automatic. If the strengthened scan finds a real private value, implementation stops and reports the affected paths and commits before any rewrite decision. This preserves reviewability and avoids changing published commit identities without explicit approval.

## Large-file and asset policy

Large-file enforcement will inspect the complete content being published, not only newly added paths. Files over 10 MiB fail unless they have a narrow entry in a root-level `.audit-large-files` file. Each tab-separated entry contains the exact SHA-256 digest, byte size, repository path, and single-line rationale. The audit rejects malformed, stale, digest-mismatched, or unnecessary entries. The exception file is created only if at least one verified asset cannot meet the threshold. Renaming or copying a file cannot bypass the policy.

The 11,633,376-byte `fall-echo-tries.png` will first receive deterministic lossless PNG optimization. Pixel dimensions, decoded pixel data, color profile behavior, and visible appearance must remain unchanged. Before and after files will be decoded and compared by pixel hash in addition to normal visual inspection. If lossless optimization brings it below 10 MiB, no exception is added. If it remains above the threshold, the implementation may add a digest-bound exception only when its provenance and redistribution terms are verified and the size is justified. It will not silently recompress lossily, replace, or remove the wallpaper.

An `ASSETS.md` manifest will cover all 27 tracked PNG, JPEG, GIF, WebP, and SVG assets. Grouped entries are allowed when paths share one verified source and license. Each entry records:

- repository path or explicit path group;
- purpose in the desktop;
- original project or source URL;
- author or project attribution when available;
- license or redistribution terms;
- local modifications, including lossless optimization.

Provenance will be traced from repository history, embedded metadata, and authoritative upstream project files. Search-engine guesses or visual similarity are insufficient. If any asset's redistribution status cannot be verified, implementation stops before removing or replacing it and reports the exact unresolved paths for the user to decide. Existing `LICENSE` and `NOTICE` remain the project-level source and derivative attribution; the asset manifest supplements rather than replaces them.

## ML4W independence

Publication hardening must not reintroduce ML4W as an operational dependency. CI, bootstrap, runtime services, settings, themes, wallpapers, and update helpers must work from this repository and standard package sources alone. Historical migration checks and attribution in `NOTICE` may mention ML4W because they document origin and compatibility, but no active command may clone, source, update from, or require an ML4W repository or Flatpak remote.

The existing dependency guard remains part of full validation. A final targeted search classifies every remaining `ml4w` reference as attribution, migration compatibility, test data, or an error.

## Test-first implementation

Each blocker follows a red-green-refactor cycle:

1. Add the smallest focused regression test and run it against the current code to observe the expected failure.
2. Make the minimum production change that satisfies the test.
3. Run the focused test and `./scripts/check.sh --quick`.
4. Inspect the staged diff and run `./scripts/audit.sh --staged` before committing the cohesive slice.

The full test matrix includes:

- Qt 6 `qmllint` resolution with a restricted `PATH`.
- Hyprland verification with the caller's `XDG_RUNTIME_DIR` unset.
- No-argument and instant screenshot behavior with fake dependencies.
- Successful-simulation/failed-real-Stow rollback with a partial link and a pre-existing managed link.
- Staged-index versus worktree divergence in both directions.
- Historical personal-home and unsafe-pattern detection.
- Complete-index large-file enforcement and digest-bound exception behavior if an exception is necessary.
- Asset manifest completeness against every tracked raster and SVG path.
- The existing bootstrap, standalone dependency, keybinding, Waybar, dock, wallpaper, and Hyprland configuration tests.

Tests never capture the real screen, overwrite live dotfiles, invoke a disruptive power action, or mutate the live Hyprland session.

## Verification and release gate

The branch is ready to merge locally only after all of these fresh checks succeed:

1. Focused regression tests for every changed unit.
2. `./scripts/check.sh` with zero failed groups and all 56 Hyprland configurations accepted.
3. `./scripts/audit.sh --history` with no privacy, secret, unsafe-pattern, or policy finding.
4. The exact GitHub Actions dependency installation and `./scripts/check.sh --require-tools` inside a fresh `archlinux:base-devel` container, followed by `./scripts/audit.sh --history` in that container.
5. Fresh-machine bootstrap and package-install dry runs using repository fixtures.
6. `git diff --check`, strict Git object verification, and review of every commit relative to `origin/main`.
7. Live, non-disruptive desktop verification: no `hyprctl configerrors`; expected bindings present; Waybar, dock, QuickShell, notifications, wallpaper service, and graphical session services healthy; safe representative shortcuts exercised.
8. Independent code review of the complete publication-hardening range, with all critical and important findings resolved and reverified.
9. Final clean worktree, local `main` containing the reviewed commits, and no unrequested remote push.

The exact Arch container run is a release requirement, not an optional cross-check. If local and container results differ, the container failure remains blocking until the difference is explained and fixed.

## Commit and rollback strategy

Implementation starts from a named rollback tag at the current audited commit and uses an isolated feature worktree. Commits remain small enough to review and revert, organized approximately as:

1. CI tool and Hyprland runtime isolation tests and fixes.
2. Screenshot regression test and argument fix.
3. Stow transaction rollback test and fix.
4. Staged snapshot, history, and large-file audit tests and fixes.
5. Asset provenance manifest and lossless optimization, if verification permits it.
6. Final documentation or workflow adjustments required by exact-container verification.

Before every commit, inspect staged paths and `git diff --cached`, scan for private or insecure content, and run the strongest audit available at that point. The corrected staged-snapshot audit becomes mandatory as soon as its slice lands. No generated backup, local setting, hardware identifier, username-specific path, credential, or runtime state may enter a commit.

After the complete range passes verification and independent review, merge it into local `main` with history preserved. A faulty logical slice can be rolled back with `git revert COMMIT_SHA`; the named pre-hardening tag restores the entire previous state. No remote branch, tag, or commit is created without explicit user authorization.

## Error handling

- Missing required CI tools produce one clear failed validation group under `--require-tools`.
- Temporary home, runtime, and staged-snapshot directories use narrow name prefixes, guarded cleanup, and traps.
- Real Stow failure reports the original failure after attempting safe rollback; it never reports success merely because restoration succeeded.
- Audit findings name the path and finding class without printing matched secrets.
- Asset uncertainty is a hard publication stop, not permission to delete or substitute the user's visuals.
- Exact-container failure blocks merge even when host checks pass.
- Live verification avoids destructive actions and restores any safe temporary state it changes.

## Acceptance criteria

- The exact GitHub Actions container workflow passes from a fresh image.
- Qt 6's canonical Arch `qmllint` is found without Qt 5 or host-specific `PATH` state.
- All 56 Hyprland variants verify when the caller has no `XDG_RUNTIME_DIR`.
- The configured no-argument screenshot shortcut reaches its interactive selector without a nounset error.
- A real Stow failure after successful simulation restores conflicts, removes only transaction-created links, and preserves pre-existing and unrelated content.
- `audit.sh --staged` validates the index snapshot and is unaffected by divergent unstaged edits.
- Current and reachable historical content receive equivalent secret, private-home, and unsafe-pattern coverage.
- Every tracked visual asset is represented in `ASSETS.md`, and its provenance and redistribution terms are verified; any unresolved asset blocks release.
- No published file over 10 MiB lacks a digest-bound, reviewed exception.
- Pixel and visual comparison prove that wallpaper optimization did not alter appearance.
- Existing desktop validation, bootstrap tests, keybinding inventory, Waybar actions, dock behavior, wallpaper behavior, and standalone dependency guards pass.
- No active dependency on ML4W or its GitHub repository exists.
- The final local `main` is clean, audited, independently reviewed, and ready for the user to push with a standard `git push origin main` command.
