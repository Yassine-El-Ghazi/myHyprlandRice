# Publication Readiness Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove every verified publication blocker so the independent MyHyprlandRice repository passes its exact Arch CI environment, safely reproduces on a fresh machine, preserves its current appearance, and is ready for the user to push.

**Architecture:** Keep the existing Bash automation and public commands, but harden six boundaries in place: executable discovery, isolated Hyprland validation, screenshot argument handling, Stow transactions, staged/history auditing, and asset publication policy. Every behavioral change starts with a focused failing fixture, lands as a small audited commit, and is followed by exact-container and live non-disruptive verification.

**Tech Stack:** Bash 5, GNU Stow, Git, GitHub Actions, Arch Linux, Hyprland 0.56.x Lua configuration provider, Qt 6 `qmllint`, Gitleaks, ripgrep, ShellCheck, ImageMagick, Docker.

**Spec:** `docs/superpowers/specs/2026-08-24-publication-readiness-hardening-design.md`

## Global Constraints

- Preserve every wallpaper, decoded wallpaper pixel, color palette, generated theme, Waybar layout, dock appearance, shortcut, and user-visible interaction.
- Do not add an ML4W runtime, update, package, Flatpak, service, or GitHub dependency. Attribution and migration-only references remain allowed.
- Keep `check.sh`, `audit.sh`, `link-dotfiles.sh`, and the screenshot script's existing public command interfaces compatible.
- Run each focused test red before implementation and green after implementation; do not accept a test that never demonstrated the original failure.
- Never test screenshot capture against the real display, mutate live dotfiles from a fixture, or trigger logout, DPMS-off, suspend, hibernate, reboot, or shutdown.
- Before every commit, stage explicit paths, inspect `git diff --cached --check`, inspect `git diff --cached`, and run `./scripts/audit.sh --staged`.
- Do not commit credentials, hardware identifiers, generated runtime state, backups, username-specific paths, or unverifiable asset claims.
- If any asset's provenance or redistribution terms cannot be verified from an authoritative source, stop Task 5 without removing or replacing the asset and ask the user to decide.
- Use an isolated Git worktree during execution, preserve unrelated user changes, and do not push.
- Merge verified work into local `main` only after independent review and final verification.

## File map

- `scripts/lib.sh`: shared executable-resolution helper.
- `scripts/check.sh`: validation registration and Qt 6 linter selection.
- `scripts/check-hyprland.sh`: isolated temporary home and runtime directory for all config variants.
- `dotfiles/.config/hypr/scripts/screenshot.sh`: nounset-safe screenshot mode dispatch.
- `scripts/link-dotfiles.sh`: Stow pre-state inventory, partial-link cleanup, and conflict restoration.
- `scripts/audit.sh`: worktree/index selection, staged snapshot validation, current/history privacy checks.
- `scripts/audit-large-files.sh`: focused 10 MiB policy and optional digest-bound exception parser.
- `tests/test-validation-environment.sh`: Qt resolver and clean-environment Hyprland fixtures.
- `tests/test-screenshot.sh`: no-argument, full-screen, and area screenshot fixtures.
- `tests/test-link-dotfiles.sh`: successful simulation followed by failed real Stow transaction fixture.
- `tests/test-audit.sh`: staged/worktree divergence, history-only privacy, and large-file fixtures.
- `tests/test-assets.sh`: exact tracked-asset manifest completeness guard.
- `ASSETS.md`: one exact row per tracked image with source, author/project, terms, and modification status.
- `README.md`, `SECURITY.md`, `CONTRIBUTING.md`, and `NOTICE`: user-facing publication and audit policy.
- `.github/workflows/validate.yml`: remains the source of truth for the exact clean Arch validation environment; change only if exact-container evidence requires it.

This remains one implementation plan because every task feeds the same publication gate and no individual task makes the repository ready to push. Tasks 1 through 6 are still independent review units with their own red-green cycle and audited commit.

| Spec requirement | Implemented and verified by |
| --- | --- |
| Qt 6 linter resolution | Tasks 1 and 7 |
| Private Hyprland runtime directory | Tasks 1 and 7 |
| No-argument screenshot flow | Tasks 2 and 8 |
| Real-Stow rollback | Tasks 3 and 8 |
| Staged snapshot validation | Tasks 4 and 6 |
| History privacy parity | Tasks 4 and 8 |
| Asset provenance and unchanged appearance | Tasks 5, 6, and 8 |
| Complete 10 MiB policy | Tasks 5, 6, and 7 |
| ML4W operational independence | Tasks 7 and 8 |
| Exact CI, review, rollback, and local integration | Tasks 0, 7, 8, and 9 |

---

### Task 0: Establish an isolated baseline and rollback point

**Files:**
- Read: `docs/superpowers/specs/2026-08-24-publication-readiness-hardening-design.md`
- Read: `docs/superpowers/plans/2026-08-24-publication-readiness-hardening.md`
- No tracked source file changes in this task.

**Interfaces:**
- Consumes: approved design commit `00f730c` and the committed implementation plan.
- Produces: isolated feature worktree and annotated tag `pre-publication-hardening-2026-08-24` at the pre-implementation baseline.

- [ ] **Step 1: Invoke the worktree workflow before editing**

Use `superpowers:using-git-worktrees`. It must confirm `GIT_DIR`, `GIT_COMMON`, and the current branch before creating or selecting an isolated worktree. Use branch name `publication-hardening-2026-08-24` unless that branch already exists.

- [ ] **Step 2: Confirm the exact committed baseline**

Run:

```bash
git status --short --branch
baseline_commit=$(git rev-parse HEAD)
git merge-base --is-ancestor 00f730c "$baseline_commit"
git log -1 --format='%H %s' -- docs/superpowers/plans/2026-08-24-publication-readiness-hardening.md
git tag -l 'pre-publication-hardening-2026-08-24'
```

Expected: the feature worktree is clean; the design is an ancestor; the plan has a commit; the tag query prints nothing.

- [ ] **Step 3: Run the host baseline gates**

Run:

```bash
./scripts/check.sh
./scripts/audit.sh --history
```

Expected: all local validation groups and 56 Hyprland variants pass; the history audit reports no existing finding. This does not waive the known clean-container blockers.

- [ ] **Step 4: Create and verify the rollback tag**

Run:

```bash
baseline_commit=$(git rev-parse HEAD)
git tag -a pre-publication-hardening-2026-08-24 \
  -m 'Rollback point before publication readiness hardening' \
  "$baseline_commit"
git rev-parse pre-publication-hardening-2026-08-24^{}
printf '%s\n' "$baseline_commit"
```

Expected: the two full commit IDs are identical. Do not push the tag.

---

### Task 1: Make CI tool discovery and Hyprland validation environment-independent

**Files:**
- Modify: `scripts/lib.sh` after `require_command()`.
- Modify: `scripts/check.sh:117-122` and the behavioral-test registrations near `scripts/check.sh:132`.
- Modify: `scripts/check-hyprland.sh:9-31`.
- Create: `tests/test-validation-environment.sh`.

**Interfaces:**
- Consumes: command name followed by zero or more explicit executable fallback paths.
- Produces: `resolve_executable NAME [FALLBACK...]`, printing exactly one executable path and returning 0, or printing nothing and returning 1.
- Produces: `XDG_RUNTIME_DIR=$audit_home/runtime` with mode `0700` for every Hyprland verification invocation.

- [ ] **Step 1: Add focused resolver and runtime tests**

Create `tests/test-validation-environment.sh` with these behaviors:

```bash
#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-validation-env.XXXXXXXX")
FAKE_BIN="$TEST_ROOT/bin"
export HYPRLAND_ENV_LOG="$TEST_ROOT/hyprland.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-validation-env.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Validation environment test failed: %s\n' "$*" >&2
    exit 1
}

test_resolver() {
    local fallback resolved
    # shellcheck source=scripts/lib.sh
    source "$REPO_ROOT/scripts/lib.sh"
    fallback="$TEST_ROOT/qt6/qmllint"
    mkdir -p -- "$(dirname -- "$fallback")" "$TEST_ROOT/empty-path"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fallback"
    chmod +x -- "$fallback"
    resolved=$(PATH="$TEST_ROOT/empty-path" resolve_executable qmllint "$fallback") || \
        fail 'explicit Qt 6 fallback was not resolved'
    [[ $resolved == "$fallback" ]] || fail "unexpected resolver result: $resolved"
    if PATH="$TEST_ROOT/empty-path" resolve_executable missing-command \
        "$TEST_ROOT/missing" >/dev/null; then
        fail 'resolver accepted a missing executable'
    fi
}

test_hyprland_runtime() {
    mkdir -p -- "$FAKE_BIN"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        ': "${XDG_RUNTIME_DIR:?missing XDG_RUNTIME_DIR}"' \
        '[[ -d $XDG_RUNTIME_DIR ]] || exit 71' \
        '[[ $(stat -c %a "$XDG_RUNTIME_DIR") == 700 ]] || exit 72' \
        '[[ $XDG_RUNTIME_DIR == "$HOME/runtime" ]] || exit 73' \
        'printf "%s\n" "$XDG_RUNTIME_DIR" >> "$HYPRLAND_ENV_LOG"' \
        'printf "config ok\n"' \
        > "$FAKE_BIN/Hyprland"
    chmod +x -- "$FAKE_BIN/Hyprland"
    env -u XDG_RUNTIME_DIR PATH="$FAKE_BIN:/usr/bin:/bin" \
        "$REPO_ROOT/scripts/check-hyprland.sh" >/dev/null
    [[ $(wc -l < "$HYPRLAND_ENV_LOG") -eq 56 ]] || \
        fail 'not every Hyprland variant received the private runtime directory'
    [[ $(sort -u "$HYPRLAND_ENV_LOG" | wc -l) -eq 1 ]] || \
        fail 'Hyprland variants used inconsistent runtime directories'
}

case ${1:-all} in
    resolver) test_resolver ;;
    runtime) test_hyprland_runtime ;;
    all)
        test_resolver
        test_hyprland_runtime
        ;;
    *) fail "unknown test case: $1" ;;
esac

printf 'Validation tools and Hyprland runtime isolation passed.\n'
```

- [ ] **Step 2: Register and run both red cases**

Add near the start of the behavioral registrations in `scripts/check.sh`:

```bash
run_check 'Validation tool and runtime isolation' \
    "$REPO_ROOT/tests/test-validation-environment.sh"
```

Run:

```bash
chmod +x tests/test-validation-environment.sh
./tests/test-validation-environment.sh resolver
./tests/test-validation-environment.sh runtime
```

Expected: resolver fails because `resolve_executable` does not exist; runtime fails because `XDG_RUNTIME_DIR` is absent.

- [ ] **Step 3: Add the executable resolver**

Add to `scripts/lib.sh`:

```bash
resolve_executable() {
    local command_name=$1
    local candidate resolved
    shift

    if resolved=$(command -v -- "$command_name" 2>/dev/null); then
        printf '%s\n' "$resolved"
        return 0
    fi
    for candidate in "$@"; do
        if [[ -x $candidate ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}
```

- [ ] **Step 4: Resolve and call Qt 6 `qmllint` once**

Replace the current `command -v qmllint` block in `scripts/check.sh` with:

```bash
qml_linter=''
if qml_linter=$(resolve_executable qmllint /usr/lib/qt6/bin/qmllint); then
    run_check 'Quickshell entrypoint syntax' \
        "$qml_linter" dotfiles/.config/quickshell/shell.qml
else
    skip 'qmllint is unavailable'
fi
```

- [ ] **Step 5: Create and pass the private runtime directory**

After `audit_home` is created in `scripts/check-hyprland.sh`, add:

```bash
runtime_dir="$audit_home/runtime"
mkdir -m 0700 -- "$runtime_dir"
```

Add this assignment to the environment for `Hyprland --verify-config`:

```bash
XDG_RUNTIME_DIR="$runtime_dir"
```

The complete invocation must set `HOME`, `XDG_CONFIG_HOME`, and `XDG_RUNTIME_DIR` on the same command.

- [ ] **Step 6: Run focused and quick validation**

Run:

```bash
./tests/test-validation-environment.sh
env -u XDG_RUNTIME_DIR ./scripts/check-hyprland.sh
./scripts/check.sh --quick
```

Expected: the fixture passes, all 56 real variants pass without caller runtime state, and quick validation passes.

- [ ] **Step 7: Audit and commit the CI/runtime slice**

Run:

```bash
git add scripts/lib.sh scripts/check.sh scripts/check-hyprland.sh \
  tests/test-validation-environment.sh
git diff --cached --check
git diff --cached
./scripts/audit.sh --staged
git commit -m 'fix(ci): isolate validation tools and runtime'
```

Expected: only the four listed files are committed.

---

### Task 2: Restore the interactive screenshot shortcut safely

**Files:**
- Modify: `dotfiles/.config/hypr/scripts/screenshot.sh:65-74`.
- Create: `tests/test-screenshot.sh`.
- Modify: `scripts/check.sh` near the desktop behavior registrations.

**Interfaces:**
- Consumes: optional first argument `--instant`, `--instant-area`, an unknown string, or no argument.
- Produces: instant full capture, instant area capture, or the existing interactive Rofi flow without nounset errors.

- [ ] **Step 1: Create the no-display screenshot fixture**

Create `tests/test-screenshot.sh`:

```bash
#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-screenshot-test.XXXXXXXX")
TEST_HOME="$TEST_ROOT/home"
FAKE_BIN="$TEST_ROOT/bin"
CONFIG_ROOT="$TEST_HOME/.config"
export SCREENSHOT_TEST_LOG="$TEST_ROOT/commands.log"

cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-screenshot-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'Screenshot test failed: %s\n' "$*" >&2
    exit 1
}

mkdir -p -- "$FAKE_BIN" "$CONFIG_ROOT/myhypr/settings"
ln -s -- "$REPO_ROOT/dotfiles/.config/myhypr/library.sh" \
    "$CONFIG_ROOT/myhypr/library.sh"
printf '%s\n' '$HOME/Screenshots' > "$CONFIG_ROOT/myhypr/settings/screenshot-folder"
printf 'shot.png\n' > "$CONFIG_ROOT/myhypr/settings/screenshot-filename"
printf 'pinta\n' > "$CONFIG_ROOT/myhypr/settings/screenshot-editor"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'cat >/dev/null' \
    'printf "rofi %s\n" "$*" >> "$SCREENSHOT_TEST_LOG"' \
    'exit 0' > "$FAKE_BIN/rofi"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "grim" >> "$SCREENSHOT_TEST_LOG"' \
    'printf " <%s>" "$@" >> "$SCREENSHOT_TEST_LOG"' \
    'printf "\n" >> "$SCREENSHOT_TEST_LOG"' \
    'destination=${!#}' \
    ': > "$destination"' > "$FAKE_BIN/grim"
printf '%s\n' '#!/usr/bin/env bash' 'printf "0,0 10x10\n"' > "$FAKE_BIN/slurp"
printf '%s\n' '#!/usr/bin/env bash' 'while :; do sleep 1; done' > "$FAKE_BIN/hyprpicker"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$FAKE_BIN/notify-send"
chmod +x -- "$FAKE_BIN"/*

helper="$REPO_ROOT/dotfiles/.config/hypr/scripts/screenshot.sh"
test_env=(HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG_ROOT" PATH="$FAKE_BIN:/usr/bin:/bin")

env "${test_env[@]}" "$helper" || fail 'no-argument flow failed'
rg -Fq 'Take screenshot' "$SCREENSHOT_TEST_LOG" || fail 'interactive selector was not reached'
[[ ! -e $TEST_HOME/Screenshots/shot.png ]] || fail 'interactive probe captured the real screen path'

env "${test_env[@]}" "$helper" --instant || fail 'instant full capture failed'
rg -Fq "grim <$TEST_HOME/Screenshots/shot.png>" "$SCREENSHOT_TEST_LOG" || \
    fail 'instant full capture used unexpected arguments'

env "${test_env[@]}" "$helper" --instant-area || fail 'instant area capture failed'
rg -Fq "grim <-g> <0,0 10x10> <$TEST_HOME/Screenshots/shot.png>" \
    "$SCREENSHOT_TEST_LOG" || fail 'instant area capture used unexpected arguments'

printf 'Screenshot optional modes are nounset-safe.\n'
```

- [ ] **Step 2: Register and prove the no-argument regression is red**

Add to `scripts/check.sh`:

```bash
run_check 'Screenshot optional-mode behavior' "$REPO_ROOT/tests/test-screenshot.sh"
```

Run:

```bash
chmod +x tests/test-screenshot.sh
./tests/test-screenshot.sh
```

Expected: FAIL at the no-argument invocation with `$1: unbound variable`.

- [ ] **Step 3: Normalize the optional mode once**

Replace the instant-mode conditional in `screenshot.sh` with:

```bash
mode=${1:-}
case $mode in
    --instant)
        take_instant_full
        exit 0
        ;;
    --instant-area)
        take_instant_area
        exit 0
        ;;
esac
```

Leave unknown and empty modes to the existing interactive flow.

- [ ] **Step 4: Run focused and quick validation**

Run:

```bash
./tests/test-screenshot.sh
lua tests/test-keybindings.lua
./scripts/check.sh --quick
```

Expected: all commands pass and both keybinding variants still resolve the screenshot command.

- [ ] **Step 5: Audit and commit the screenshot slice**

Run:

```bash
git add dotfiles/.config/hypr/scripts/screenshot.sh \
  tests/test-screenshot.sh scripts/check.sh
git diff --cached --check
git diff --cached
./scripts/audit.sh --staged
git commit -m 'fix(screenshot): restore interactive shortcut flow'
```

---

### Task 3: Make the real Stow operation transactional

**Files:**
- Modify: `scripts/link-dotfiles.sh:44-214`.
- Modify: `tests/test-link-dotfiles.sh` after the existing bootstrap ordering assertions.

**Interfaces:**
- Consumes: tracked package-relative paths and the set of valid managed links present before conflicts move.
- Produces: rollback that removes only transaction-created links, restores every moved conflict, preserves pre-existing managed links, and exits with the real Stow status.

- [ ] **Step 1: Add the failed-real-Stow fixture**

Append this isolated case to `tests/test-link-dotfiles.sh` before its final success message:

```bash
FAILURE_ROOT="$TEST_HOME/failed-real-stow"
FAILURE_HOME="$FAILURE_ROOT/home"
FAILURE_BIN="$FAILURE_ROOT/bin"
mkdir -p -- "$FAILURE_HOME/.config/keep" "$FAILURE_BIN"
printf 'restore me\n' > "$FAILURE_HOME/.zshrc"
printf 'unrelated\n' > "$FAILURE_HOME/.config/keep/state"
ln -s -- "$REPO_ROOT/dotfiles/.bashrc" "$FAILURE_HOME/.bashrc"

export STOW_PARTIAL_SOURCE="$REPO_ROOT/dotfiles/.config/kitty/kitty.conf"
export STOW_PARTIAL_TARGET="$FAILURE_HOME/.config/kitty/kitty.conf"
export STOW_EXISTING_TARGET="$FAILURE_HOME/.bashrc"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'for argument in "$@"; do' \
    '    [[ $argument == --simulate ]] && exit 0' \
    'done' \
    'rm -f -- "$STOW_EXISTING_TARGET"' \
    'mkdir -p -- "$(dirname -- "$STOW_PARTIAL_TARGET")"' \
    'ln -s -- "$STOW_PARTIAL_SOURCE" "$STOW_PARTIAL_TARGET"' \
    'exit 42' > "$FAILURE_BIN/stow"
chmod +x -- "$FAILURE_BIN/stow"

set +e
HOME="$FAILURE_HOME" XDG_STATE_HOME="$FAILURE_HOME/.local/state" \
    PATH="$FAILURE_BIN:/usr/bin:/bin" \
    "$REPO_ROOT/scripts/link-dotfiles.sh" --target "$FAILURE_HOME" \
    --backup-conflicts --yes >/dev/null 2>&1
failure_status=$?
set -e
[[ $failure_status -eq 42 ]] || {
    printf 'Failed real Stow transaction returned %s instead of 42.\n' \
        "$failure_status" >&2
    exit 1
}
[[ -f $FAILURE_HOME/.zshrc && $(<"$FAILURE_HOME/.zshrc") == 'restore me' ]]
[[ ! -e $STOW_PARTIAL_TARGET && ! -L $STOW_PARTIAL_TARGET ]]
[[ -L $FAILURE_HOME/.bashrc ]]
[[ $FAILURE_HOME/.bashrc -ef $REPO_ROOT/dotfiles/.bashrc ]]
[[ $(<"$FAILURE_HOME/.config/keep/state") == 'unrelated' ]]
```

- [ ] **Step 2: Run the Stow test red**

Run:

```bash
./tests/test-link-dotfiles.sh
```

Expected: FAIL because `.zshrc` remains in the backup and the partial Kitty link remains in the target.

- [ ] **Step 3: Record tracked paths and pre-transaction managed links**

Add these declarations before tracked-path enumeration:

```bash
declare -a tracked_relatives=()
declare -A preexisting_managed_links=()
```

During the existing `git ls-files` loop, append each retained relative path:

```bash
tracked_relatives+=("$relative")
if [[ -L $target_path ]] && same_target "$source_path" "$target_path"; then
    preexisting_managed_links["$relative"]=$(readlink -- "$target_path")
fi
```

Place the target-path check after `target_path` is assigned.

- [ ] **Step 4: Add narrow partial-link cleanup**

Add these helpers beside `restore_conflicts()`:

```bash
is_link_into_package() {
    local link_path=$1
    local link_target resolved_target
    [[ -L $link_path ]] || return 1
    link_target=$(readlink -- "$link_path")
    if [[ $link_target != /* ]]; then
        link_target="$(dirname -- "$link_path")/$link_target"
    fi
    resolved_target=$(realpath -m -- "$link_target")
    [[ $resolved_target == "$PACKAGE_ROOT/"* ]]
}

remove_transaction_links() {
    local relative target_path parent_directory
    local cleanup_failed=0
    for relative in "${tracked_relatives[@]}"; do
        [[ -z ${preexisting_managed_links[$relative]+x} ]] || continue
        target_path="$TARGET/$relative"
        is_link_into_package "$target_path" || continue
        if ! rm -- "$target_path"; then
            warn "Could not remove transaction-created link: $relative"
            cleanup_failed=1
            continue
        fi
        parent_directory=$(dirname -- "$target_path")
        while [[ $parent_directory == "$TARGET/"* && $parent_directory != "$TARGET" ]]; do
            rmdir -- "$parent_directory" 2>/dev/null || break
            parent_directory=$(dirname -- "$parent_directory")
        done
    done
    return "$cleanup_failed"
}

restore_preexisting_links() {
    local relative target_path expected_target parent_directory
    local restoration_failed=0
    for relative in "${!preexisting_managed_links[@]}"; do
        target_path="$TARGET/$relative"
        expected_target=${preexisting_managed_links[$relative]}
        if [[ -L $target_path ]] && \
            same_target "$PACKAGE_ROOT/$relative" "$target_path"; then
            continue
        fi
        if [[ -e $target_path || -L $target_path ]]; then
            warn "Pre-existing managed-link path is occupied during rollback: $relative"
            restoration_failed=1
            continue
        fi
        parent_directory=$(dirname -- "$target_path")
        mkdir -p -- "$parent_directory"
        if ! ln -s -- "$expected_target" "$target_path"; then
            warn "Could not restore pre-existing managed link: $relative"
            restoration_failed=1
        fi
    done
    return "$restoration_failed"
}
```

This loop never scans or removes unrelated target paths.

- [ ] **Step 5: Make restoration collision-aware and reverse ordered**

Replace `restore_conflicts()` with:

```bash
restore_conflicts() {
    local index relative source_path target_path
    local restoration_failed=0

    for ((index = ${#moved_conflicts[@]} - 1; index >= 0; index--)); do
        relative=${moved_conflicts[$index]}
        source_path="$backup_dir/$relative"
        target_path="$TARGET/$relative"
        [[ -e $source_path || -L $source_path ]] || continue
        if [[ -e $target_path || -L $target_path ]]; then
            warn "Rollback target is occupied; recover $relative from $backup_dir"
            restoration_failed=1
            continue
        fi
        mkdir -p -- "$(dirname -- "$target_path")"
        if ! mv -- "$source_path" "$target_path"; then
            warn "Could not restore $relative; recover it from $backup_dir"
            restoration_failed=1
        fi
    done
    return "$restoration_failed"
}
```

- [ ] **Step 6: Handle the real Stow status explicitly**

Replace `run stow "${stow_args[@]}"` with this form so the real status is preserved:

```bash
print_command stow "${stow_args[@]}"
set +e
stow "${stow_args[@]}"
stow_status=$?
set -e
if [[ $stow_status -ne 0 ]]; then
    rollback_failed=0
    remove_transaction_links || rollback_failed=1
    restore_preexisting_links || rollback_failed=1
    restore_conflicts || rollback_failed=1
    if [[ $rollback_failed -ne 0 ]]; then
        warn "Rollback was incomplete; recover remaining files from $backup_dir"
    else
        info 'Failed Stow transaction was rolled back.'
    fi
    warn "Stow transaction failed with status $stow_status."
    exit "$stow_status"
fi
```

- [ ] **Step 7: Verify all Stow paths**

Run:

```bash
./tests/test-link-dotfiles.sh
./bootstrap.sh --profile desktop --dry-run --yes
./scripts/check.sh --quick
```

Expected: failed-real-Stow rollback, simulation failure, successful backup, stale-link migration, restow, and dry-run paths all pass.

- [ ] **Step 8: Audit and commit the Stow slice**

Run:

```bash
git add scripts/link-dotfiles.sh tests/test-link-dotfiles.sh
git diff --cached --check
git diff --cached
./scripts/audit.sh --staged
git commit -m 'fix(stow): roll back failed link transactions'
```

---

### Task 4: Validate the staged snapshot and extend reachable-history privacy checks

**Files:**
- Modify: `scripts/audit.sh:25-50`, `scripts/audit.sh:131-170`, and its final quick-validation call.
- Create: `tests/test-audit.sh`.
- Modify: `scripts/check.sh` near repository automation tests.

**Interfaces:**
- Consumes: the complete Git index for `--staged`, and unique reachable blobs for `--history`.
- Produces: quick validation against a temporary index snapshot; history findings for the same secret, non-placeholder-home, and unsafe patterns used at the tip.

- [ ] **Step 1: Create a disposable-repository audit fixture**

Create `tests/test-audit.sh` with helper functions that copy the current `audit.sh` and `lib.sh` into a temporary repository. The minimal fixture checker must be:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
if rg -q '^BROKEN$' fixture.txt; then
    printf 'fixture is broken\n' >&2
    exit 9
fi
```

Use this setup function:

```bash
setup_repo() {
    local target=$1
    mkdir -p -- "$target/scripts" "$target/bin"
    cp -- "$REPO_ROOT/scripts/audit.sh" "$REPO_ROOT/scripts/lib.sh" "$target/scripts/"
    if [[ -f $REPO_ROOT/scripts/audit-large-files.sh ]]; then
        cp -- "$REPO_ROOT/scripts/audit-large-files.sh" "$target/scripts/"
        chmod +x -- "$target/scripts/audit-large-files.sh"
    fi
    printf '%s\n' '#!/usr/bin/env bash' 'exit 2' > "$target/bin/gitleaks"
    chmod +x -- "$target/bin/gitleaks"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        'if rg -q '\''^BROKEN$'\'' fixture.txt; then' \
        '    printf '\''fixture is broken\n'\'' >&2' \
        '    exit 9' \
        'fi' > "$target/scripts/check.sh"
    chmod +x -- "$target/scripts/check.sh"
    printf 'SAFE\n' > "$target/fixture.txt"
    git -C "$target" init -q
    git -C "$target" add -A
    git -C "$target" -c user.name='Audit Fixture' \
        -c user.email='audit@example.invalid' commit -qm baseline
}
```

Use this prologue and cleanup around the function:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-audit-test.XXXXXXXX")
cleanup() {
    case $TEST_ROOT in
        "${TMPDIR:-/tmp}"/myhypr-audit-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT
fail() {
    printf 'Audit behavior test failed: %s\n' "$*" >&2
    exit 1
}
```

Implement two staged-snapshot cases in separate fixture repositories:

```bash
repo_a="$TEST_ROOT/staged-invalid"
repo_b="$TEST_ROOT/staged-valid"
setup_repo "$repo_a"
setup_repo "$repo_b"

# Case A: staged BROKEN, worktree SAFE => staged audit must fail.
printf 'BROKEN\n' > "$repo_a/fixture.txt"
git -C "$repo_a" add fixture.txt
printf 'SAFE\n' > "$repo_a/fixture.txt"
if PATH="$repo_a/bin:/usr/bin:/bin" "$repo_a/scripts/audit.sh" --staged; then
    fail 'invalid staged content was hidden by a valid worktree repair'
fi

# Case B: staged SAFE, worktree BROKEN => staged audit must pass.
printf 'SAFE\n' > "$repo_b/fixture.txt"
git -C "$repo_b" add fixture.txt
printf 'BROKEN\n' > "$repo_b/fixture.txt"
PATH="$repo_b/bin:/usr/bin:/bin" "$repo_b/scripts/audit.sh" --staged || \
    fail 'valid staged content was rejected because of an unstaged edit'
```

Add one history-only case. Construct the forbidden strings across assignments so this repository's own audit does not match the test source:

```bash
repo_history="$TEST_ROOT/history"
setup_repo "$repo_history"
private_value='/home/'
private_value+='history-fixture-user'
unsafe_value='chmod 77'
unsafe_value+='7 historical-file'
printf '%s\n' "$private_value" > "$repo_history/history-private.txt"
printf '%s\n' "$unsafe_value" > "$repo_history/history-unsafe.sh"
git -C "$repo_history" add history-private.txt history-unsafe.sh
git -C "$repo_history" -c user.name='Audit Fixture' \
    -c user.email='audit@example.invalid' commit -qm 'add historical findings'
printf 'removed\n' > "$repo_history/history-private.txt"
printf 'removed\n' > "$repo_history/history-unsafe.sh"
git -C "$repo_history" add history-private.txt history-unsafe.sh
git -C "$repo_history" -c user.name='Audit Fixture' \
    -c user.email='audit@example.invalid' commit -qm 'remove historical findings'
if PATH="$repo_history/bin:/usr/bin:/bin" \
    "$repo_history/scripts/audit.sh" --history >"$TEST_ROOT/history.log" 2>&1; then
    fail 'history-only privacy findings were missed'
fi
rg -Fq 'history-private.txt' "$TEST_ROOT/history.log"
rg -Fq 'history-unsafe.sh' "$TEST_ROOT/history.log"
```

- [ ] **Step 2: Register and run the audit fixture red**

Add to `scripts/check.sh`:

```bash
run_check 'Staged snapshot and history audit behavior' \
    "$REPO_ROOT/tests/test-audit.sh"
```

Run:

```bash
chmod +x tests/test-audit.sh
./tests/test-audit.sh
```

Expected: at least the staged/worktree divergence case and both history-only categories fail against the current audit.

- [ ] **Step 3: Add guarded staged-snapshot cleanup**

Add near the top of `scripts/audit.sh`:

```bash
audit_snapshot=''
cleanup() {
    [[ -n $audit_snapshot ]] || return 0
    case $audit_snapshot in
        "${TMPDIR:-/tmp}"/myhypr-audit-index.*) rm -rf -- "$audit_snapshot" ;;
    esac
}
trap cleanup EXIT
```

- [ ] **Step 4: Validate quick checks from the index snapshot**

Add:

```bash
run_quick_validation() {
    if [[ $MODE != staged ]]; then
        "$SCRIPT_DIR/check.sh" --quick
        return
    fi

    audit_snapshot=$(mktemp -d "${TMPDIR:-/tmp}/myhypr-audit-index.XXXXXXXX")
    git checkout-index --all --prefix="$audit_snapshot/"
    (
        cd -- "$audit_snapshot"
        git init -q
        git -c core.hooksPath=/dev/null add -A
        "$audit_snapshot/scripts/check.sh" --quick
    )
}
```

Replace the final direct `check.sh --quick` call with `run_quick_validation`.

- [ ] **Step 5: Apply home and unsafe patterns to unique history blobs**

Inside the reachable-blob loop, after secret scanning, add:

```bash
if git cat-file blob "$object" | rg -I -q --pcre2 "$home_pattern"; then
    warn "Machine-specific absolute home path exists in Git history: $path"
    history_findings=$((history_findings + 1))
fi
if [[ $path != scripts/audit.sh ]] && \
    git cat-file blob "$object" | rg -I -q -e "$unsafe_pattern"; then
    warn "Unsafe dotfiles pattern exists in Git history: $path"
    history_findings=$((history_findings + 1))
fi
```

Do not print matched content.

- [ ] **Step 6: Run focused and quick validation**

Run:

```bash
./tests/test-audit.sh
./scripts/audit.sh --history
./scripts/check.sh --quick
```

Expected: fixture and repository history pass with no private value printed.

- [ ] **Step 7: Audit the audit implementation and commit**

Run:

```bash
git add scripts/audit.sh tests/test-audit.sh scripts/check.sh
git diff --cached --check
git diff --cached
./scripts/audit.sh --staged
git commit -m 'fix(audit): validate staged snapshots and history'
```

Expected: the corrected staged-snapshot implementation validates its own staged version.

---

### Task 5: Verify asset provenance and losslessly optimize the oversized wallpaper

**Files:**
- Create: `ASSETS.md` only after all 27 assets are verified.
- Modify: `README.md` security/license section to link `ASSETS.md`.
- Modify mechanically: `dotfiles/.config/myhypr/wallpapers/fall-echo-tries.png`.
- Modify if authoritative evidence requires clarification: `NOTICE`.

**Interfaces:**
- Consumes: 27 tracked PNG/JPEG/SVG assets, repository history, embedded metadata, and authoritative upstream/brand repositories.
- Produces: one exact manifest row per asset and a sub-10-MiB PNG with identical decoded pixels and display characteristics.

- [ ] **Step 1: Generate the exact local provenance inventory**

Run:

```bash
asset_work="${TMPDIR:-/tmp}/myhypr-asset-work"
if [[ -e $asset_work ]]; then
  printf 'Refusing to replace existing asset work directory: %s\n' "$asset_work" >&2
  exit 1
fi
mkdir -m 0700 -- "$asset_work"
git ls-files | rg -i '\.(png|jpe?g|webp|gif|svg)$' | sort > "$asset_work/assets.txt"
wc -l "$asset_work/assets.txt"
while IFS= read -r asset; do
  printf '%s\t%s\t%s\n' \
    "$(git hash-object "$asset")" \
    "$(sha256sum "$asset" | cut -d' ' -f1)" \
    "$asset"
done < "$asset_work/assets.txt" > "$asset_work/asset-hashes.tsv"
```

Expected: exactly 27 paths and 27 hash rows. Preserve the report outside Git.

- [ ] **Step 2: Trace inherited assets to authoritative upstream history**

Clone source repositories into guarded temporary directories, not into this repository:

```bash
asset_work="${TMPDIR:-/tmp}/myhypr-asset-work"
source_root="$asset_work/sources"
mkdir -m 0700 -- "$source_root"
git clone --filter=blob:none https://github.com/mylinuxforwork/dotfiles.git \
  "$source_root/ml4w-dotfiles"
git clone --filter=blob:none https://github.com/mylinuxforwork/wallpaper.git \
  "$source_root/ml4w-wallpaper"
```

For each inventory row, search source trees by Git blob ID first:

```bash
asset_work="${TMPDIR:-/tmp}/myhypr-asset-work"
source_root="$asset_work/sources"
while IFS=$'\t' read -r blob sha path; do
  printf '%s\n' "$path"
  git -C "$source_root/ml4w-dotfiles" rev-list --all --objects | rg "^${blob} " || true
  git -C "$source_root/ml4w-wallpaper" rev-list --all --objects | rg "^${blob} " || true
done < "$asset_work/asset-hashes.tsv"
```

Record the matching source repository, commit, path, repository license, and upstream author/project. Use exact commit URLs in the manifest. Do not infer a source from visual similarity.

- [ ] **Step 3: Verify special trademark and project assets**

Check these authorities in addition to ML4W history:

- OpenAI SVG marks: `https://openai.com/brand/`; document OpenAI ownership and that the marks are used only for direct OpenAI service quicklinks, without implying endorsement.
- Hyprland icons: `https://github.com/hyprwm/Hyprland`; verify the exact icon source and BSD-3-Clause terms or retain the more specific upstream notice found in history.
- Wlogout icons: `https://github.com/ArtsyMacaw/wlogout`; verify exact file matches and MIT terms before attributing them to Wlogout.
- Project SVG `dotfiles/.config/quickshell/shared/MyHyprLogo.svg`: inspect commit `4cdaf63` and document it as the MyHyprlandRice project mark only if repository history confirms local authorship.
- QuickShell overview image: inspect commit `004a9bc` and its source path; do not label it as locally authored without evidence.

If any exact source or redistribution term remains unresolved, stop here. Report the unresolved paths to the user; do not change, delete, optimize, or commit assets.

- [ ] **Step 4: Write one exact row per asset**

Create `ASSETS.md` with this table schema:

```markdown
# Asset provenance and licenses

Project-level licensing and derivative attribution are documented in
[`LICENSE`](LICENSE) and [`NOTICE`](NOTICE). Trademark assets remain the
property of their respective owners and are used only to identify the linked
service or project; inclusion does not imply endorsement.

| Repository path | Purpose | Source and author/project | Terms | Local changes |
| --- | --- | --- | --- | --- |
```

Add exactly one row beginning with an exact backtick-quoted repository path for each path in `$asset_work/assets.txt`. Do not use `unknown`, `unverified`, `TBD`, or a guessed author. For inherited assets, include an authoritative source commit URL and state `unchanged from source` unless Git and SHA-256 evidence prove a local modification. For `fall-echo-tries.png`, initially state the original source and defer its local-change cell until Step 6.

- [ ] **Step 5: Produce a temporary lossless candidate**

Run:

```bash
asset_work="${TMPDIR:-/tmp}/myhypr-asset-work"
asset=dotfiles/.config/myhypr/wallpapers/fall-echo-tries.png
candidate="$asset_work/fall-echo-tries-candidate.png"
before_color="$asset_work/fall-echo-before-color.txt"
after_color="$asset_work/fall-echo-after-color.txt"
before_size=$(stat -c %s "$asset")
before_signature=$(identify -format '%#' "$asset")
before_characteristics=$(identify -format '%w|%h|%[colorspace]|%z|%[channels]|%[gamma]' "$asset")
magick "$asset" -define png:compression-level=9 "$candidate"
after_size=$(stat -c %s "$candidate")
after_signature=$(identify -format '%#' "$candidate")
after_characteristics=$(identify -format '%w|%h|%[colorspace]|%z|%[channels]|%[gamma]' "$candidate")
printf '%s -> %s bytes\n' "$before_size" "$after_size"
printf '%s\n%s\n' "$before_signature" "$after_signature"
printf '%s\n%s\n' "$before_characteristics" "$after_characteristics"
identify -verbose "$asset" | sed -n \
  -e '/  Colorspace:/p' -e '/  Rendering intent:/p' -e '/  Gamma:/p' \
  -e '/  Chromaticity:/,/  Matte color:/p' > "$before_color"
identify -verbose "$candidate" | sed -n \
  -e '/  Colorspace:/p' -e '/  Rendering intent:/p' -e '/  Gamma:/p' \
  -e '/  Chromaticity:/,/  Matte color:/p' > "$after_color"
cmp -s -- "$before_color" "$after_color"
compare -metric AE "$asset" "$candidate" null:
```

Expected from the verified trial: `11633376 -> 10041278 bytes`, identical signatures and characteristics, and `0 (0)` differing pixels. Reject the candidate if any equality or the 10 MiB threshold fails.

- [ ] **Step 6: Visually inspect, then replace the binary mechanically**

Use the local image viewer tool on both the tracked original and `$candidate` at original detail. Confirm no visual difference. Then run:

```bash
asset_work="${TMPDIR:-/tmp}/myhypr-asset-work"
asset=dotfiles/.config/myhypr/wallpapers/fall-echo-tries.png
candidate="$asset_work/fall-echo-tries-candidate.png"
before_color="$asset_work/fall-echo-before-color.txt"
after_color="$asset_work/fall-echo-after-color.txt"
before_size=$(stat -c %s "$asset")
after_size=$(stat -c %s "$candidate")
before_signature=$(identify -format '%#' "$asset")
after_signature=$(identify -format '%#' "$candidate")
before_characteristics=$(identify -format '%w|%h|%[colorspace]|%z|%[channels]|%[gamma]' "$asset")
after_characteristics=$(identify -format '%w|%h|%[colorspace]|%z|%[channels]|%[gamma]' "$candidate")
[[ $after_size -lt $((10 * 1024 * 1024)) ]]
[[ $before_signature == "$after_signature" ]]
[[ $before_characteristics == "$after_characteristics" ]]
cmp -s -- "$before_color" "$after_color"
[[ $(compare -metric AE "$asset" "$candidate" null: 2>&1) == '0 (0)' ]]
cp -- "$candidate" "$asset"
chmod 0644 "$asset"
```

Update the asset's manifest row to state `Lossless PNG recompression on 2026-08-24; decoded pixels unchanged.` No `.audit-large-files` exception should be created because the verified candidate is below 10 MiB.

- [ ] **Step 7: Link the manifest from project documentation**

In `README.md`, add a sentence after the `NOTICE` attribution paragraph:

```markdown
Path-level image sources, licenses, trademark notices, and local modifications
are listed in [ASSETS.md](ASSETS.md).
```

Update `NOTICE` only when the authoritative evidence gathered above requires an additional named author or project notice.

- [ ] **Step 8: Verify asset-only changes and commit**

Run:

```bash
git diff --check
git diff --stat
git diff -- ASSETS.md README.md NOTICE
identify -format '%# %w %h %[colorspace] %z %[channels]\n' \
  dotfiles/.config/myhypr/wallpapers/fall-echo-tries.png
stat -c '%s %n' dotfiles/.config/myhypr/wallpapers/fall-echo-tries.png
git add ASSETS.md README.md \
  dotfiles/.config/myhypr/wallpapers/fall-echo-tries.png
if ! git diff --quiet -- NOTICE; then git add NOTICE; fi
git diff --cached --check
git diff --cached --stat
git diff --cached -- ASSETS.md README.md NOTICE
./scripts/audit.sh --staged
git commit -m 'docs(assets): verify provenance and optimize wallpaper'
asset_work="${TMPDIR:-/tmp}/myhypr-asset-work"
case $asset_work in
  "${TMPDIR:-/tmp}"/myhypr-asset-work) rm -rf -- "$asset_work" ;;
esac
```

Expected: only manifest/documentation and the pixel-identical PNG are committed.

---

### Task 6: Enforce complete large-file and asset-manifest policy

**Files:**
- Create: `scripts/audit-large-files.sh`.
- Modify: `scripts/audit.sh` to invoke the helper.
- Extend: `tests/test-audit.sh` with complete-index and exception cases.
- Create: `tests/test-assets.sh`.
- Modify: `scripts/check.sh` to register asset policy.
- Modify: `README.md`, `SECURITY.md`, and `CONTRIBUTING.md` policy wording.
- Create only if a future verified asset requires it: `.audit-large-files`.

**Interfaces:**
- Consumes: worktree/untracked files or the complete Git index under `--staged`.
- Consumes optional `.audit-large-files` rows with four tab-separated fields: SHA-256, byte count, repository path, and rationale.
- Produces: zero findings when every file is at most 10 MiB or has an exact necessary exception; rejects malformed, stale, mismatched, renamed, and unnecessary exceptions.

- [ ] **Step 1: Add red large-file cases to the audit fixture**

Add a new disposable fixture repository to `tests/test-audit.sh`. Create an oversized tracked blob before the baseline commit:

```bash
repo_large="$TEST_ROOT/large-files"
setup_repo "$repo_large"
truncate -s $((10 * 1024 * 1024 + 1)) "$repo_large/large.bin"
git -C "$repo_large" add large.bin
git -C "$repo_large" -c user.name='Audit Fixture' \
    -c user.email='audit@example.invalid' commit -qm 'add existing large file'
printf 'changed\n' > "$repo_large/fixture.txt"
git -C "$repo_large" add fixture.txt
if PATH="$repo_large/bin:/usr/bin:/bin" \
    "$repo_large/scripts/audit.sh" --staged >/dev/null 2>&1; then
    fail 'complete-index policy missed an existing oversized file'
fi
```

Then add a valid exception and verify it passes:

```bash
large_sha=$(sha256sum "$repo_large/large.bin" | cut -d' ' -f1)
large_size=$(stat -c %s "$repo_large/large.bin")
printf '%s\t%s\t%s\t%s\n' "$large_sha" "$large_size" 'large.bin' \
    'Deterministic audit fixture' > "$repo_large/.audit-large-files"
git -C "$repo_large" add .audit-large-files
PATH="$repo_large/bin:/usr/bin:/bin" \
    "$repo_large/scripts/audit.sh" --staged >/dev/null || \
    fail 'exact large-file exception was rejected'
```

Finally assert that a digest mismatch and an exception for a below-threshold file both fail:

```bash
if [[ ${large_sha:0:1} == 0 ]]; then
    bad_sha="1${large_sha:1}"
else
    bad_sha="0${large_sha:1}"
fi
printf '%s\t%s\t%s\t%s\n' "$bad_sha" "$large_size" 'large.bin' \
    'Deterministic audit fixture' > "$repo_large/.audit-large-files"
git -C "$repo_large" add .audit-large-files
if PATH="$repo_large/bin:/usr/bin:/bin" \
    "$repo_large/scripts/audit.sh" --staged >/dev/null 2>&1; then
    fail 'digest-mismatched large-file exception was accepted'
fi

printf 'small\n' > "$repo_large/small.bin"
small_sha=$(sha256sum "$repo_large/small.bin" | cut -d' ' -f1)
small_size=$(stat -c %s "$repo_large/small.bin")
printf '%s\t%s\t%s\t%s\n' "$large_sha" "$large_size" 'large.bin' \
    'Deterministic audit fixture' > "$repo_large/.audit-large-files"
printf '%s\t%s\t%s\t%s\n' "$small_sha" "$small_size" 'small.bin' \
    'Unnecessary audit fixture exception' >> "$repo_large/.audit-large-files"
git -C "$repo_large" add .audit-large-files small.bin
if PATH="$repo_large/bin:/usr/bin:/bin" \
    "$repo_large/scripts/audit.sh" --staged >/dev/null 2>&1; then
    fail 'unnecessary below-threshold exception was accepted'
fi
```

- [ ] **Step 2: Run the complete-index policy test red**

Run:

```bash
./tests/test-audit.sh
```

Expected: FAIL because the current audit ignores an oversized file that was committed before the small staged change.

- [ ] **Step 3: Create the focused large-file policy helper**

Create executable `scripts/audit-large-files.sh` with:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

MODE=worktree
if (($#)); then
    [[ $1 == --staged ]] || die 'Usage: scripts/audit-large-files.sh [--staged]'
    MODE=staged
    shift
fi
(($# == 0)) || die 'Usage: scripts/audit-large-files.sh [--staged]'
cd -- "$REPO_ROOT"

limit=$((10 * 1024 * 1024))
allowlist=.audit-large-files
failures=0
declare -A allowed_sha=() allowed_size=() allowed_reason=() seen=()
```

Add these policy readers. Staged mode reads the allowlist from the index and worktree mode reads the file:

```bash
policy_exists() {
    if [[ $MODE == staged ]]; then
        git cat-file -e ":$allowlist" 2>/dev/null
    else
        [[ -f $allowlist ]]
    fi
}

policy_contents() {
    if [[ $MODE == staged ]]; then
        git show ":$allowlist"
    else
        command cat -- "$allowlist"
    fi
}

load_policy() {
    local digest bytes path reason extra
    policy_exists || return 0
    while IFS=$'\t' read -r digest bytes path reason extra; do
        [[ -n $digest || -n $bytes || -n $path || -n $reason || -n $extra ]] || continue
        [[ $digest == \#* ]] && continue
        if [[ ! $digest =~ ^[0-9a-f]{64}$ || ! $bytes =~ ^[0-9]+$ ||
              -z $path || $path == /* || $path == .. || $path == ../* ||
              $path == */../* || $path == */.. || -z $reason || -n $extra ]]; then
            warn "Malformed large-file exception for path: ${path:-missing-path}"
            failures=$((failures + 1))
            continue
        fi
        if [[ -n ${allowed_sha[$path]+x} ]]; then
            warn "Duplicate large-file exception: $path"
            failures=$((failures + 1))
            continue
        fi
        allowed_sha[$path]=$digest
        allowed_size[$path]=$bytes
        allowed_reason[$path]=$reason
    done < <(policy_contents)
}
```

Call `load_policy` before enumerating files.

- [ ] **Step 4: Scan the complete selected file set**

Add these helpers for index and worktree content:

```bash
content_size() {
    local path=$1
    if [[ $MODE == staged ]]; then
        git cat-file -s ":$path"
    elif [[ -L $path ]]; then
        readlink -- "$path" | wc -c
    else
        stat -c %s -- "$path"
    fi
}

content_digest() {
    local path=$1
    if [[ $MODE == staged ]]; then
        git show ":$path" | sha256sum | cut -d' ' -f1
    elif [[ -L $path ]]; then
        readlink -- "$path" | sha256sum | cut -d' ' -f1
    else
        sha256sum -- "$path" | cut -d' ' -f1
    fi
}
```

Enumerate and enforce with:

```bash
if [[ $MODE == staged ]]; then
    mapfile -d '' files < <(git ls-files -z)
else
    mapfile -d '' files < <(git ls-files -z --cached --others --exclude-standard)
fi

for path in "${files[@]}"; do
    if [[ $MODE != staged && ! -e $path && ! -L $path ]]; then
        continue
    fi
    size=$(content_size "$path")
    ((size > limit)) || continue
    digest=$(content_digest "$path")
    if [[ -z ${allowed_sha[$path]+x} ]]; then
        warn "File exceeds 10 MiB without an exception: $path"
        failures=$((failures + 1))
        continue
    fi
    if [[ ${allowed_size[$path]} != "$size" || ${allowed_sha[$path]} != "$digest" ]]; then
        warn "Large-file exception does not match current content: $path"
        failures=$((failures + 1))
        continue
    fi
    seen[$path]=1
done

for path in "${!allowed_sha[@]}"; do
    if [[ -z ${seen[$path]+x} ]]; then
        warn "Large-file exception is stale or unnecessary: $path"
        failures=$((failures + 1))
    fi
done

if ((failures > 0)); then
    die "$failures large-file policy finding(s) must be resolved."
fi
success 'Large-file policy passed.'
```

This is the complete enforcement loop; do not add path-only exceptions.

- [ ] **Step 5: Invoke the helper from the main audit**

Remove the existing staged-additions-only size loop from `scripts/audit.sh`. Add:

```bash
large_file_args=()
[[ $MODE != staged ]] || large_file_args+=(--staged)
if ! "$SCRIPT_DIR/audit-large-files.sh" "${large_file_args[@]}"; then
    failures=$((failures + 1))
fi
```

Place it after content scanning and before Gitleaks.

- [ ] **Step 6: Add the exact asset-manifest guard**

Create `tests/test-assets.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd -- "$REPO_ROOT"
expected=$(mktemp "${TMPDIR:-/tmp}/myhypr-assets-expected.XXXXXXXX")
documented=$(mktemp "${TMPDIR:-/tmp}/myhypr-assets-documented.XXXXXXXX")
trap 'rm -f -- "$expected" "$documented"' EXIT

git ls-files | rg -i '\.(png|jpe?g|webp|gif|svg)$' | sort > "$expected"
sed -n 's/^| `\([^`]*\)` |.*/\1/p' ASSETS.md | sort > "$documented"
diff -u "$expected" "$documented"
[[ $(wc -l < "$expected") -eq 27 ]]
if rg -n -i '\b(TBD|TODO|unknown|unverified)\b' ASSETS.md; then
    printf 'Asset manifest contains an unresolved entry.\n' >&2
    exit 1
fi
printf 'Asset manifest covers every tracked image.\n'
```

Register it in `scripts/check.sh`:

```bash
run_check 'Asset provenance manifest' "$REPO_ROOT/tests/test-assets.sh"
```

- [ ] **Step 7: Run the focused tests green**

Run:

```bash
chmod +x scripts/audit-large-files.sh tests/test-assets.sh
./tests/test-audit.sh
./tests/test-assets.sh
./scripts/audit-large-files.sh
./scripts/audit-large-files.sh --staged
./scripts/check.sh --quick
```

Expected: the optimized wallpaper is below 10 MiB, so the repository passes without `.audit-large-files`; fixture exceptions pass only when exact and necessary.

- [ ] **Step 8: Update publication policy wording**

Make these exact documentation changes:

- `README.md`: change `unexpected large files` to `all files over 10 MiB unless a digest-bound exception is documented`.
- `SECURITY.md`: change `large additions` to `the complete published index for files over 10 MiB and exact digest-bound exceptions`.
- `CONTRIBUTING.md`: require updating `ASSETS.md` whenever a tracked raster or SVG is added, removed, or modified.
- Document `.audit-large-files`'s four tab-separated fields in `SECURITY.md`, while stating that the file is absent when no exception is required.

- [ ] **Step 9: Audit and commit the publication-policy slice**

Run:

```bash
git add scripts/audit-large-files.sh scripts/audit.sh tests/test-audit.sh \
  tests/test-assets.sh scripts/check.sh README.md SECURITY.md CONTRIBUTING.md
git diff --cached --check
git diff --cached
./scripts/audit.sh --staged
git commit -m 'fix(audit): enforce complete publication policy'
```

---

### Task 7: Reproduce the exact GitHub Actions environment

**Files:**
- Read: `.github/workflows/validate.yml`.
- Modify only when container evidence requires it: `.github/workflows/validate.yml`, the focused test, and the directly responsible script.

**Interfaces:**
- Consumes: fresh `archlinux:base-devel`, the workflow's exact package list, and the complete Git history.
- Produces: zero skipped required tools, 56 valid Hyprland variants, and a clean history audit in the same environment CI will use.

- [ ] **Step 1: Run the workflow commands in a fresh container**

From the feature worktree, preserve its absolute path so linked-worktree Git metadata resolves inside Docker, then run:

```bash
container_worktree=$(pwd -P)
git_common=$(cd -- "$(git rev-parse --git-common-dir)" && pwd -P)
docker run --rm \
  -e MYHYPR_CONTAINER_WORKTREE="$container_worktree" \
  -v "$container_worktree:$container_worktree:ro" \
  -v "$git_common:$git_common:ro" \
  -w "$container_worktree" \
  archlinux:base-devel \
  bash -lc '
    set -Eeuo pipefail
    pacman -Syu --noconfirm --needed \
      bash fish git gitleaks hyprland jq lua python qt6-declarative \
      ripgrep shellcheck stow zsh
    git config --global --add safe.directory "$MYHYPR_CONTAINER_WORKTREE"
    git clone --no-local "$MYHYPR_CONTAINER_WORKTREE" /tmp/myhypr-ci
    cd /tmp/myhypr-ci
    ./scripts/check.sh --require-tools
    ./scripts/audit.sh --history
  '
```

Expected: `qmllint` resolves from `/usr/lib/qt6/bin`, all required groups run with zero skips, all 56 configurations pass, and history audit passes.

- [ ] **Step 2: Diagnose any container-only failure before editing**

If Step 1 fails, invoke `superpowers:systematic-debugging`. Capture the failing command, exit status, package ownership/path evidence, and minimal reproduction. Add or strengthen a focused regression test before changing source. Do not patch the workflow to hide a missing validation group.

- [ ] **Step 3: Commit only evidence-driven corrections**

If source changes were required, run the focused regression, `./scripts/check.sh --quick`, stage only the direct files, inspect the staged diff, run `./scripts/audit.sh --staged`, and commit with a focused `fix(ci): ...` message. If Step 1 passed without changes, make no empty commit.

- [ ] **Step 4: Repeat from a new container**

Rerun the entire Step 1 command from a fresh `archlinux:base-devel` container. Expected: the complete command exits 0; reusing a previously modified container is not acceptable evidence.

---

### Task 8: Run final host, bootstrap, privacy, Git, and live desktop verification

**Files:**
- No planned source changes; any discovered defect returns to the relevant task with a new red test.

**Interfaces:**
- Consumes: complete feature-branch range from the rollback tag through Task 7.
- Produces: evidence package for independent review and local integration.

- [ ] **Step 1: Run full repository and history gates fresh**

Run:

```bash
./scripts/check.sh
./scripts/audit.sh --history
git diff --check pre-publication-hardening-2026-08-24..HEAD
git fsck --strict --no-reflogs
```

Expected: all groups pass, 56 configurations pass, no audit finding, no whitespace error, and no Git corruption. Dangling unreachable objects may be reported by `fsck`; corruption may not.

- [ ] **Step 2: Rehearse fresh-machine automation without mutation**

Run:

```bash
./bootstrap.sh --profile desktop --dry-run --yes
./scripts/install-packages.sh --profile full --dry-run --yes
./scripts/doctor.sh --profile desktop --quick
```

Expected: bootstrap and package resolution complete without requiring a manual package list; doctor reports zero errors. Warnings must be classified and resolved when they indicate a repository defect.

- [ ] **Step 3: Verify independence and publication inventory**

Run:

```bash
rg -n -i 'ml4w|mylinuxforwork' --hidden --glob '!.git/**' .
git ls-files | rg -i '\.(png|jpe?g|webp|gif|svg)$' | wc -l
./tests/test-assets.sh
find dotfiles -type f -size +10M -print
git log --format='%an <%ae>' pre-publication-hardening-2026-08-24..HEAD | sort -u
```

Expected: every remaining ML4W reference is attribution, migration compatibility, test data, or historical documentation; exactly 27 assets are manifested; no current file exceeds 10 MiB; commit identities contain no private email.

- [ ] **Step 4: Verify the live desktop without disruptive actions**

Run from the active graphical session:

```bash
hyprctl configerrors
hyprctl -j binds | jq 'length'
hyprctl dispatch 'hl.dsp.no_op()'
systemctl --user is-active myhypr-session.target walker.service elephant.service
pgrep -af 'waybar|nwg-dock-hyprland|quickshell|swaync|awww'
```

Expected: config errors are empty; binding count remains 111; typed no-op succeeds; the session target and managed launcher services are active; Waybar, dock, QuickShell, notifications, and wallpaper processes are present.

Use existing safe tests for interactions:

```bash
lua ./tests/test-keybindings.lua
./tests/test-waybar-actions.sh
./tests/test-waybar-themes.sh
./tests/test-dock-launch.sh
./tests/test-screenshot.sh
./tests/test-wallpaper-settings.sh
```

Expected: Wi-Fi click action, CPU/resource drawer action, neutral MyHypr menu action, dock launcher, screenshot selector, and wallpaper settings all pass. Do not automate a power action or real screenshot.

- [ ] **Step 5: Review the complete range before integration**

Run:

```bash
git status --short --branch
git log --oneline --decorate pre-publication-hardening-2026-08-24..HEAD
git diff --stat pre-publication-hardening-2026-08-24..HEAD
git diff --check pre-publication-hardening-2026-08-24..HEAD
```

Expected: worktree clean, only intentional commits, reviewable size, no whitespace errors.

Invoke `superpowers:requesting-code-review` on the complete range. Resolve every critical and important finding with a new focused test and audited commit. Rerun Tasks 7 and 8 after any correction.

---

### Task 9: Integrate into local main and prepare the push handoff

**Files:**
- No source changes expected.

**Interfaces:**
- Consumes: independently reviewed feature branch with all Task 7 and Task 8 evidence fresh.
- Produces: clean local `main` containing the publication-hardening commits; no remote mutation.

- [ ] **Step 1: Invoke the branch-finishing workflow**

Use `superpowers:finishing-a-development-branch`. Select local integration, not push or PR creation.

- [ ] **Step 2: Merge with history preserved**

From the primary worktree, verify it is clean, then fast-forward or merge the feature branch according to the finishing skill. Do not squash audited logical commits and do not push the rollback tag.

- [ ] **Step 3: Re-run the final local gate on `main`**

Run:

```bash
git switch main
./scripts/check.sh
./scripts/audit.sh --history
git status --short --branch
git log -1 --oneline --decorate
```

Expected: full validation and history audit pass; `main` is clean and ahead of `origin/main` only by reviewed local commits.

- [ ] **Step 4: Verify push ancestry without pushing**

Run:

```bash
git merge-base --is-ancestor origin/main main
git rev-list --left-right --count origin/main...main
git remote get-url --push origin
```

Expected: `main` is a fast-forward descendant of `origin/main`, the left count is zero, and the push URL is the intended GitHub repository.

- [ ] **Step 5: Hand off the explicit user command**

Report the final commit, ahead/behind counts, full/container/live verification results, rollback tag, and any authentication limitation. Give—but do not execute—the command:

```bash
git push origin main
```
