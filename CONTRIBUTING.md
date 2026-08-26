# Contributing

Changes should remain reproducible on a clean Arch-based installation and must not assume a monitor name, username, home path, secret, or user-local binary.

1. Keep runtime paths, commands, UI labels, and themes under the MyHypr namespace. Do not add a dependency on another dotfiles repository, remote, or hosted settings service.
2. Run `make dry-run` to inspect package, service, migration, backup, and linking changes.
3. Keep host-only configuration in the files documented under `examples/`.
4. Add or update a deterministic fixture for changes to bootstrap, linking, migration, settings, launchers, or state handling.
5. Update `ASSETS.md` whenever a tracked raster or SVG is added, removed, or modified.
6. Run `make check` and `make audit`.
7. Stage intentionally, inspect `git diff --cached`, then run `./scripts/audit.sh --staged`.
8. Use a focused Conventional Commit message such as `fix(hypr): select focused output dynamically`.

Package dependencies belong in `packages/arch/`. Runtime-generated files belong in `defaults/` and the matching ignore lists—not in the Stow package. Shell code must pass ShellCheck at style severity; runtime text must be parsed as data rather than passed to `eval`, `bash -c`, or sourced as executable settings.

Before a release or public history rewrite, also run `make audit-history`. Preserve GPL attribution in `NOTICE` when changing inherited code or assets.
