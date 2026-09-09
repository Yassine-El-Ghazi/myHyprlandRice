# MyHyprlandRice

[![Validate](https://github.com/Yassine-El-Ghazi/myHyprlandRice/actions/workflows/validate.yml/badge.svg)](https://github.com/Yassine-El-Ghazi/myHyprlandRice/actions/workflows/validate.yml)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

A self-contained, reproducible Hyprland desktop for Arch Linux and CachyOS.

MyHypr combines Hyprland's Lua configuration, Waybar, Quickshell, Awww,
Waypaper, Matugen, Kitty, Neovim, and portable Bash/Zsh/Fish startup. Its own
settings UI, scripts, themes, state model, migration tooling, and validation
suite are all stored in this repository. No external dotfiles repository,
installer, Flatpak remote, or hosted settings service is required at runtime.

## Why this setup is different

- One command installs declared Arch/AUR dependencies, enables desktop
  services, backs up conflicts, links configuration, seeds runtime state, and
  runs diagnostics.
- Hyprland 0.56+ uses a Lua entrypoint, with 56 shipped environment,
  keybinding, monitor, and appearance variants validated individually.
- Mutable selectors, generated colors, wallpaper state, and machine-specific
  configuration stay out of Git.
- MyHypr's local Quickshell panels control settings, audio, brightness,
  Waybar, the dock, themes, wallpaper, and power actions.
- Package installation prefers official repositories and has an audited AUR
  fallback. It never pipes a network download directly into a shell.
- Every commit is guarded by syntax checks, style-level ShellCheck, integration
  fixtures, secret/privacy scans, and pinned CI actions.
- Stow conflicts and namespace migrations are archived under local state so
  they can be rolled back instead of being silently deleted.

## Requirements

- Arch Linux, CachyOS, or another Arch-based distribution
- A regular user with `sudo` authorization
- An internet connection for first-time package installation
- Git for cloning the repository

Run the bootstrap as your regular user, never as root.

## Reproduce the desktop

```bash
git clone https://github.com/Yassine-El-Ghazi/myHyprlandRice.git
cd myHyprlandRice

# Review every planned package, service, migration, backup, and link action.
./bootstrap.sh --profile desktop --dry-run

# Apply the reviewed setup.
./bootstrap.sh --profile desktop
```

Log out and back in after the first installation, then select Hyprland from
your display manager. For an unattended machine you control:

```bash
./bootstrap.sh --profile desktop --yes
```

The bootstrap is idempotent. Running it again preserves existing runtime
preferences and only installs or links what is missing.

On Neovim's first start, the plugin manager's moving `stable` branch downloads
plugins recorded in `lazy-lock.json` and the configured Tree-sitter parsers.
The plugin revisions are locked; the plugin manager branch and parser/tool
downloads are not immutable. The bootstrap installs the required Node.js and
Tree-sitter runtimes, but account authentication remains private; run
`:Copilot auth` inside Neovim if you want to use Copilot on a new machine. No
token or editor login is stored in this repository.

The tracked OpenCode desktop entry exposes an existing GUI installation at
`/opt/OpenCode/OpenCode`; bootstrap does not install that externally packaged
GUI. Install OpenCode separately if you want that launcher on another machine.

### What bootstrap automates

1. Resolves the selected package profile from `packages/arch/`.
2. Installs repository packages, then uses `paru` or `yay` for AUR packages.
   If neither exists, it can build `paru-bin` in a disposable directory.
   Privileged work shares one terminal authentication; AUR builds never run
   as root.
3. Enables NetworkManager and Bluetooth, then installs tracked Elephant and
   Walker services under a dedicated MyHypr graphical-session target.
4. Creates standard XDG user directories.
5. Archives recognized legacy state and stale local tool shadows.
6. Repairs the obsolete Flatpak metadata source only when no installed ref
   still depends on it.
7. Uses GNU Stow with `--no-folding`, backing up conflicts before linking.
8. Seeds normal mutable files from `defaults/` without overwriting changes.
9. Enables the repository-local pre-commit audit and runs the doctor.

Useful switches:

```text
--profile core|desktop|full
--dry-run
--yes
--no-packages
--no-system
--no-link
--no-hooks
```

## Package profiles

| Profile | Intended use |
| --- | --- |
| `core` | Shells, terminal, editor, prompt, fonts, Stow, and repository quality tools |
| `desktop` | Core plus the complete Hyprland session, MyHypr panels, networking, Bluetooth, audio, wallpaper, screenshots, OCR, file management, mail, and GUI software management |
| `full` | Desktop plus optional alternate browser, mail, media, image-viewer, and clock applications |

Manifest entries can declare alternatives with `package-a|package-b`. An
already satisfied package or virtual provision wins; otherwise an official
repository package is preferred before the first AUR alternative.
Elephant is installed through its atomic `elephant-all` build so its Go plugin
providers cannot drift from the core service ABI.

The shipped `nvidia` environment is a narrow dedicated-GPU compatibility
profile. Hybrid laptops should keep the `default` profile and place only
hardware-specific, verified exceptions in `~/.config/hypr/local.lua`; the
repository does not globally force PRIME offload, a Vulkan vendor, or browser
sandbox overrides.

## MyHypr controls

After starting a new shell, `~/.config/myhypr/bin` is on `PATH`:

```bash
myhyprctl welcome       # Local welcome and maintenance panel
myhyprctl settings      # Schema-driven settings editor
myhyprctl calendar
myhyprctl sidebar
myhyprctl power
myhyprctl wallpaper
myhyprctl theme
myhyprctl reload        # Reload Hyprland and print config errors
myhyprctl doctor
myhyprctl update-plan   # Validate and preview a dotfiles update
myhyprctl update        # Apply a transactional dotfiles update
myhyprctl update-system # Apply a transactional full system update
myhyprctl update-status # Inspect the latest maintenance transaction
myhyprctl recover ID    # Recover a failed or interrupted transaction
myhyprctl docs
```

Shell aliases such as `myhypr`, `myhypr-settings`, `myhypr-doctor`, and
`myhypr-update` are also provided consistently across Bash, Zsh, and Fish.

Settings are constrained by
`~/.config/myhypr/settings-schema.json`. Updates are atomic, path-contained,
single-line validated, and never evaluated as shell text.

### Add personal shortcuts

Shortcuts are configured only through Hyprland's Lua API. For a portable
shortcut that follows this repository to another computer, edit
`~/.config/hypr/conf/custom.lua` and add one described binding:

```lua
hl.bind("SUPER + SHIFT + N", hl.dsp.exec_cmd("obsidian"), {
    description = "Open notes",
})
```

For a shortcut private to one computer, copy `examples/hypr/local.lua` to
`~/.config/hypr/local.lua` and add the same form there. The private file is
loaded last and ignored by Git. To replace an existing shortcut, call
`hl.unbind("EXACT + KEY")` before the replacement binding.

Reload and verify before committing a portable shortcut:

```bash
hyprctl reload
hyprctl configerrors
git diff --check
lua tests/test-keybindings.lua
```

Press `SUPER + CTRL + K` to search the active described shortcuts. The viewer
queries the running compositor, so described bindings from both `custom.lua`
and `local.lua` appear automatically. Use `wev` when you need to discover an
uncommon key name or keycode.

## State model

Tracked configuration and mutable state deliberately live in different trees:

| Location | Role |
| --- | --- |
| `dotfiles/` | Declarative files linked individually with GNU Stow |
| `defaults/` | First-run values copied into normal mutable files |
| `examples/` | Safe templates for host-specific overrides |
| `~/.config/hypr/local.lua` | Private machine-specific monitors, devices, and commands |
| `~/.{bash,zsh}rc_custom` | Private Bash/Zsh customization |
| `~/.config/fish/config.local.fish` | Private Fish customization |
| `~/.local/state/myhyprlandrice/` | Conflict backups and reversible migration archives |
| `~/.cache/myhypr/` | Wallpaper and ephemeral desktop cache |

Stow uses `--no-folding`, so applications cannot write generated state through
a linked config directory into the repository. The doctor verifies that every
tracked file resolves to the current checkout and that runtime files are normal
files rather than Git-backed symlinks.

### Carry preferences to another computer

Normal preference changes remain local by design. To intentionally promote the
current allow-listed runtime values into portable defaults:

```bash
make capture
git diff -- defaults/
make audit
```

`capture-runtime.sh` refuses symlinks, copies only files already declared in
`defaults/`, and runs the privacy/security audit after a real capture.

## Validate and maintain

```bash
make check                         # Full suite and 56 shipped Hyprland variants
./scripts/check.sh --quick         # Fast syntax and integration suite
make audit                         # Tracked and untracked worktree audit
make audit-history                 # Scan every reachable Git blob too
make doctor PROFILE=desktop        # Links, commands, services, state, hooks
myhyprctl update-plan              # Safe preview; changes no active config
```

The test suite uses disposable homes and mocked system tools to verify package
bootstrap, Stow backups, runtime seeding, namespace migration, settings path
containment, graphical-session environment isolation, service activation,
desktop controls, Waybar/Walker theme fallbacks, and declarative wallpaper
effects.

Because the live desktop links directly to the main checkout, make future
changes in a separate Git worktree so an unfinished branch cannot alter the
running session:

```bash
git worktree add ../myHyprlandRice-work -b fix/short-description main
cd ../myHyprlandRice-work
make check
make audit
```

After reviewing and committing the worktree, fast-forward `main` and run
`./scripts/link-dotfiles.sh` once from the main checkout to deploy any newly
tracked files.

### Transactional updates and recovery

Use the separate dotfiles and system operations deliberately:

| Purpose | Command |
| --- | --- |
| Preview a dotfiles update | `myhyprctl update-plan` |
| Apply a dotfiles update | `myhyprctl update` |
| Apply a full system update | `myhyprctl update-system` |
| Show the latest transaction | `myhyprctl update-status` |
| Show one transaction | `myhyprctl update-status TRANSACTION_ID` |
| Recover an interrupted or failed transaction | `myhyprctl recover TRANSACTION_ID` |

Private transaction state is stored below
`${XDG_STATE_HOME:-~/.local/state}/myhyprlandrice/transactions`. A transaction
is successful only after postflight checks pass and its state becomes
`committed`.

A dotfiles preview fetches without moving the active branch, materializes the
incoming revision separately, and runs its required validation and publication
audit as the regular user. Each isolated candidate command has a fixed
five-minute deadline, so an incoming check cannot hang maintenance forever.
Incoming code cannot obtain privileges merely by being fetched. Apply records
a private checkpoint before mutation and can
restore the previous Git revision, managed links, allow-listed mutable state,
selectors, graphical user-service state, and displaced-file backups on every
supported filesystem.

System maintenance performs a complete Arch upgrade through `paru`, `yay`, or
`pacman`; it does not construct a partial-upgrade command. Flatpak user and
system installations are handled separately and only when their scope has a
configured remote. Immediately before privileged apply stages, the engine
requests one `sudo` credential ticket and reuses it for that bounded operation.
It never stores the password, and AUR builds remain unprivileged.

`myhyprctl update-status` reports the transaction state, failed postflight
checks, recovery coverage, and whether that transaction is the known-good
revision. Package recommendations—including `.pacnew`, `.pacsave`, outdated
process, AUR rebuild, and reboot-sensitive findings—are available in the
bounded JSON view:

```bash
./scripts/maintenance.sh status --json \
  | jq '.postflight.recommendations'
```

Review `.pacnew` and `.pacsave` files against their active configuration; do
not replace configuration blindly. Likewise, inspect which reboot-sensitive
classes were reported before deciding whether and when to reboot.

Recovery intentionally does not replay interrupted stages. Run recovery,
inspect any retained `needs-attention.txt`, then start a new plan. Package
downgrades and snapshot restores are never run automatically: package output
is evidence, not a rollback script, and a snapshot may cover only some of
root, the package database, home, and boot.

Snapshot software is neither installed nor configured inside an update. Set
up and test Snapper or Timeshift as a separate administrator task, then probe
the effective layer coverage with a non-applying plan:

```bash
./scripts/maintenance.sh plan system --profile desktop --snapshot auto
# For an explicitly configured provider, replace auto with snapper or timeshift.
```

Inspect the printed coverage before using that provider for apply. The private
transaction also contains `snapshot-probe.json`; recovery prints the provider
identifier, uncovered layers, package log location, and provider documentation
without composing or running a restore command.

Root, package-database, and boot coverage make an update system-restorable. If
only a separate `/home` subvolume is uncovered, maintenance prints that
limitation but does not request redundant confirmation; use an independent
personal-data backup if you also want complete home recovery. Missing system
layers still require explicit confirmation before any update is applied.

Each apply prepares a digest-bound `known-good.pending.json` only after its
postflight stage succeeds. It is promoted atomically to `known-good.json` only
after the journal is committed; `status` can reconcile an interrupted final
promotion. Completed plans, committed transactions, and recovered transactions
are pruned unless they are both among the newest ten successful records and no
more than 30 days old. Failed, interrupted, and needs-attention evidence is
retained for diagnosis.
Journals are user-only and schema-bounded; separate command logs are user-only,
redacted, and governed by the transaction retention policy. Arbitrary command
output, environment values, network names, and credentials do not enter the
journal. Transaction evidence and private baseline screenshots are never
published automatically.

## Rollback and removal

The transactional updater creates the normal recovery checkpoint and promotes
its local known-good record automatically. Before an unusual manual migration
outside that workflow, you may also create a named Git reference:

```bash
git tag known-good-$(date +%Y%m%d)
```

For a failed maintenance transaction, begin with `myhyprctl update-status` and
then `myhyprctl recover TRANSACTION_ID`. For unrelated manual recovery, restore
repository state with normal Git commits or tags and restore displaced local
files from the timestamped directories under
`~/.local/state/myhyprlandrice/backups/` or `migrations/`.

Remove managed links while retaining packages and all mutable state:

```bash
./scripts/uninstall.sh --dry-run
./scripts/uninstall.sh
```

## Repository layout

```text
.
├── bootstrap.sh          Reproducible entrypoint
├── defaults/             First-run mutable state
├── dotfiles/             GNU Stow package and MyHypr runtime
├── examples/             Host-local override templates
├── packages/arch/        Core, desktop, and full manifests
├── scripts/              Install, migrate, validate, audit, and diagnose
└── tests/                Deterministic integration fixtures
```

## Security, license, and attribution

The local pre-commit hook runs `./scripts/audit.sh --staged`. The scanner checks
sensitive filenames, credential signatures, unsafe credential storage,
machine-specific home paths, all files over 10 MiB unless a digest-bound
exception is documented, whitespace, and the full quick validation suite. See
[SECURITY.md](SECURITY.md) for reporting guidance and
[CONTRIBUTING.md](CONTRIBUTING.md) for repository rules.

MyHyprlandRice is independently maintained. Required attribution for inherited
GPL-licensed code and assets is preserved in [NOTICE](NOTICE); it does not imply
an active runtime, update, service, or repository dependency.

Path-level image sources, licenses, trademark notices, and local modifications
are listed in [ASSETS.md](ASSETS.md).

Licensed under [GNU GPL version 3](LICENSE).
