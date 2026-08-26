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
- Hyprland 0.56+ uses a Lua entrypoint, with all 56 shipped environment,
  keybinding, monitor, and appearance combinations validated.
- Mutable selectors, generated colors, wallpaper state, and machine-specific
  configuration stay out of Git.
- MyHypr's local Quickshell panels control settings, audio, brightness,
  Waybar, the dock, themes, wallpaper, and power actions.
- Package installation prefers official repositories and has an audited AUR
  fallback. It never uses `curl | sh`.
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
myhyprctl update
myhyprctl docs
```

Shell aliases such as `myhypr`, `myhypr-settings`, `myhypr-doctor`, and
`myhypr-update` are also provided consistently across Bash, Zsh, and Fish.

Settings are constrained by
`~/.config/myhypr/settings-schema.json`. Updates are atomic, path-contained,
single-line validated, and never evaluated as shell text.

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
make check                         # Full suite and all 56 Hyprland variants
./scripts/check.sh --quick         # Fast syntax and integration suite
make audit                         # Tracked and untracked worktree audit
make audit-history                 # Scan every reachable Git blob too
make doctor PROFILE=desktop        # Links, commands, services, state, hooks
./scripts/update.sh --profile desktop
```

The test suite uses disposable homes and mocked system tools to verify package
bootstrap, Stow backups, runtime seeding, namespace migration, settings path
containment, graphical-session environment isolation, service activation,
desktop controls, Waybar/Walker theme fallbacks, and declarative wallpaper
effects.

The graphical updater selects `paru`, then `yay`, then `pacman`. Flatpak is
updated only when remotes exist, and any failed package or metadata operation
is reported instead of showing a false success message.

## Rollback and removal

Before upgrades or large migrations, create a known-good tag:

```bash
git tag known-good-$(date +%Y%m%d)
```

Restore repository state with normal Git commits/tags. Restore displaced local
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
