# Contributing

Changes should remain reproducible on a clean Arch-based installation and must not assume a monitor name, username, home path, secret, or user-local binary.

1. Run `make dry-run` to inspect package and linking changes.
2. Keep host-only configuration in the files documented under `examples/`.
3. Run `make check` and `make audit`.
4. Stage intentionally, then run `./scripts/audit.sh --staged`.
5. Use a focused commit message such as `fix(hypr): select focused output dynamically`.

Package dependencies belong in `packages/arch/`. Runtime-generated files belong in `defaults/` and the matching ignore lists—not in the Stow package. A change to bootstrap, linking, migration, or uninstall behavior should also be exercised against a temporary home directory.
