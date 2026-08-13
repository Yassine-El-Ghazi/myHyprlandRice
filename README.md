# MyHyprlandRice

[![Validate](https://github.com/Yassine-El-Ghazi/myHyprlandRice/actions/workflows/validate.yml/badge.svg)](https://github.com/Yassine-El-Ghazi/myHyprlandRice/actions/workflows/validate.yml)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

A reproducible, adaptive Hyprland desktop for Arch Linux and CachyOS. It combines Hyprland's current Lua configuration, Waybar, Quickshell, Awww, Waypaper, Matugen, Kitty, Neovim, and portable Bash/Zsh/Fish startup with an audited bootstrap workflow.

The project began as a modified ML4W configuration. Its code and assets are vendored here under GPL-3.0; the bootstrap uses declared Arch/AUR packages and does not add the ML4W Flatpak remote. A narrowly scoped migration removes that obsolete remote when no installed Flatpak ref depends on it.

## Highlights

- Hyprland 0.56+ Lua entrypoint with all 56 shipped configuration variants validated
- Adaptive Matugen colors without generated files dirtying Git
- Awww wallpaper restore and a portable Waypaper setup
- Dynamic refresh-rate keys that discover the focused monitor and its real modes
- Three package profiles with repository-first resolution and explicit AUR fallback
- Conflict-aware GNU Stow installation with recoverable timestamped backups
- Local-only shell, monitor, and application state separated from tracked files
- Pre-commit privacy checks, full-history scanning, ShellCheck, and pinned CI actions
- No `curl | sh`, plaintext Git credential store, embedded token, or hard-coded home path

## Quick start

The automated package installer currently targets Arch-based systems. Run it as a normal user, never as root.

```bash
git clone https://github.com/Yassine-El-Ghazi/myHyprlandRice.git
cd myHyprlandRice

# Inspect package, migration, linking, and hook changes first.
./bootstrap.sh --profile desktop --dry-run

# Apply after reviewing the dry run.
./bootstrap.sh --profile desktop
```

Existing conflicts are shown before mutation and are moved under `~/.local/state/myhyprlandrice/backups/` only after confirmation. Log out and back in after the first installation.

For unattended setup on a machine you control:

```bash
./bootstrap.sh --profile desktop --yes
```

## Profiles

| Profile | Purpose |
| --- | --- |
| `core` | Shells, terminal, editor, prompt, fonts, Stow, and quality tools |
| `desktop` | Core plus the complete Hyprland session and wired applications |
| `full` | Desktop plus optional mail, browser, media, and utility applications |

Package declarations live in `packages/arch/`. Installed alternatives are respected, official repositories are preferred, and remaining packages use `paru` or `yay`. If neither exists, the bootstrap offers to build `paru-bin` in an isolated temporary directory.

Useful bootstrap switches:

```text
--profile core|desktop|full
--dry-run
--yes
--no-packages
--no-link
--no-hooks
```

## State model

Tracked configuration and mutable application state deliberately follow different paths:

| Location | Role |
| --- | --- |
| `dotfiles/` | Tracked, declarative files linked with Stow |
| `defaults/` | Tracked first-run seeds for generated color and app state |
| `~/.config/hypr/local.lua` | Ignored machine-specific monitors, devices, and commands |
| `~/.{bash,zsh}rc_custom` | Ignored private shell customization |
| `~/.config/fish/config.local.fish` | Ignored private Fish customization |
| `~/.local/state/myhyprlandrice/` | Recoverable backups and migration archives |

Stow runs with `--no-folding`: application-created files land in normal home directories instead of entering the repository through a directory symlink. Matugen outputs are seeded from `defaults/`, then remain local. Copy starting points from `examples/` when a host needs custom rules.

## Daily operations

```bash
make check                 # Syntax, JSONC/TOML/QML, monitor behavior, Hypr variants
make audit                 # Privacy/security audit of tracked and untracked work
make audit-history         # Also inspect every reachable Git blob
make doctor PROFILE=desktop
./scripts/update.sh --profile desktop
```

The graphical Waybar updater chooses `paru`, then `yay`, then `pacman`; Flatpak runs only when remotes exist. A failed package or Flatpak operation is reported as a failure instead of displaying a false “complete” message.

To repair the former metadata error directly:

```bash
./scripts/repair-flatpak.sh --dry-run
./scripts/repair-flatpak.sh
```

The repair removes only the exact `ml4w-repo` remote and refuses removal while any installed Flatpak app or runtime still uses it.

## Rollback and removal

Linking conflicts and stale local binaries are archived, not deleted. Inspect the timestamped directories under `~/.local/state/myhyprlandrice/` to restore a previous file.

Remove managed links while preserving all local/generated state:

```bash
./scripts/uninstall.sh --dry-run
./scripts/uninstall.sh
```

Git commits and release tags are the configuration rollback points. Package installation is intentionally non-destructive; uninstalling links does not remove packages.

## Layout

```text
.
├── bootstrap.sh          Reproducible entrypoint
├── defaults/             First-run mutable state
├── dotfiles/             GNU Stow package
├── examples/             Safe host-local override templates
├── packages/arch/        Core, desktop, and full manifests
├── scripts/              Install, link, migrate, validate, audit, and diagnose
└── tests/                Deterministic integration fixtures
```

## Security and provenance

The repository-local pre-commit hook runs a staged secret/privacy audit. Enable it manually with `git config core.hooksPath .githooks` if bootstrap hooks were skipped. See [SECURITY.md](SECURITY.md) for the threat model and reporting process.

This is an independently maintained derivative, not an official ML4W release. The original ML4W dotfiles project and inherited contributors are credited in [NOTICE](NOTICE). Hyprland, Waybar, Quickshell, and other packaged applications remain independent upstream projects.

Licensed under [GNU GPL version 3](LICENSE).
