# Security policy

## Reporting a vulnerability

Do not open a public issue containing a credential, private path, or exploit detail. Revoke exposed credentials first, then use GitHub's private vulnerability reporting feature when it is available. Otherwise, contact the repository owner through their GitHub profile without including the secret itself.

The actively supported configuration is the latest commit on `main`.

## Security model

Tracked settings are treated as code; mutable values are treated as data. MyHypr constrains settings to declared paths, writes them atomically, validates selectable values, and launches post-actions as argument vectors. Generated state is copied into normal home-directory files so applications cannot write back into Git through folded directory links.

Package installation uses signed Arch repositories and explicit AUR package declarations. Review AUR build files when prompted. The bootstrap does not download and execute opaque install scripts.

## Maintenance transaction boundaries

Maintenance operations use a per-user runtime lock and atomically written,
user-only transaction directories below
`${XDG_STATE_HOME:-~/.local/state}/myhyprlandrice/transactions`. Journal fields
are schema-bounded and contain state, timestamps, commit identifiers, recovery
coverage, and result classes—not arbitrary command output. Separate package and
helper logs are permission-restricted and redact credential-like values and URI
userinfo. The tools never store an authentication password.

An incoming dotfiles revision is fetched and validated in an isolated
candidate worktree as the regular user. Only the already trusted transaction
engine may request the single `sudo` ticket used by privileged apply stages;
AUR builds remain unprivileged.

Recovery accepts only a contained transaction identifier and validates file
ownership, file type, expected state, and active Git revision before mutation.
It restores only transaction-owned configuration evidence when doing so cannot
overwrite unexpected user data. Cross-transaction paths, symlinks, collisions,
and an unrelated active commit fail closed or become `needs-attention`.
Recovery is idempotent and never replays an interrupted stage.

Filesystem snapshots and package logs have deliberately narrower trust
semantics. Snapper or Timeshift must already be configured, and the probe
records coverage independently for root, package database, home, and boot.
Recovery reports provider guidance and uncovered layers but never performs a
snapshot restore, package downgrade, deletion, or reboot automatically.

Committed and recovered transaction directories are retained only while they
are both among the newest ten successful records and no more than 30 days old.
Failed, interrupted, and needs-attention evidence is retained for diagnosis.
Treat all transaction records, migration archives, conflict backups, baseline
evidence, and screenshots as private local data. No maintenance command
publishes them automatically.

## Local safety gates

Every commit should pass:

```bash
./scripts/audit.sh --staged
```

Before publishing a new clone or release, also scan reachable history:

```bash
./scripts/audit.sh --history
```

The audit checks sensitive filenames, high-confidence credential signatures, unsafe credential storage, machine-specific home paths, the complete published index for files over 10 MiB and exact digest-bound exceptions, whitespace, and configuration syntax. Gitleaks is used only after it detects a synthetic test secret; the built-in scanner remains active even when Gitleaks is unavailable or broken.

When a verified file must exceed 10 MiB, `.audit-large-files` records one exception per line using four tab-separated fields: the file's SHA-256 digest, byte count, repository path, and rationale. The file is absent when no exception is required; path-only, stale, mismatched, or unnecessary exceptions are rejected.

Never commit `.env` files, private keys, browser profiles, shell history,
host-specific `local.lua`, transaction state, or application-generated state.
Treat archives and evidence under `~/.local/state/myhyprlandrice/` as private
local data; they are intentionally ignored and must not be published.
