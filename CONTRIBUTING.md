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

## Maintenance transaction changes

Treat update and recovery code as a failure-sensitive interface:

- Add deterministic fixtures for success, failure before and after mutation,
  interrupted state, lock contention, retry, and recovery idempotency where
  those paths can change.
- Keep journals schema-bounded, atomic, user-only, and free of raw command
  output, environment dumps, package inventories, host or network identifiers,
  and credentials. Redact separate command logs before publication to disk.
- Validate incoming dotfiles candidates as the regular user. Privileged work
  must be controlled by the trusted active revision, use one authentication
  ticket per operation, and never run AUR builds as root. Keep candidate
  execution network-isolated and bounded by a trusted wall-clock deadline.
- Preserve full Arch upgrade semantics. Never introduce a selective package
  synchronization path that can leave an unsupported partial upgrade.
- Recover only from transaction-owned evidence after validating ownership,
  file type, path containment, and expected active state. Never replay an
  interrupted stage or automatically restore a filesystem snapshot or
  downgrade packages.
- Update the CLI documentation and focused tests whenever a state, journal
  field, stage, recovery rule, retention rule, or public command changes.

Before committing maintenance work, run all affected focused tests followed
by `./scripts/check.sh`, inspect the staged diff, and run
`./scripts/audit.sh --staged`. Before publishing a release, also run
`./scripts/audit.sh --history` from the exact commit that will be published.

Before a release or public history rewrite, also run `make audit-history`. Preserve GPL attribution in `NOTICE` when changing inherited code or assets.
