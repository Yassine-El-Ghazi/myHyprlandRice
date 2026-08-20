# Security policy

## Reporting a vulnerability

Do not open a public issue containing a credential, private path, or exploit detail. Revoke exposed credentials first, then use GitHub's private vulnerability reporting feature when it is available. Otherwise, contact the repository owner through their GitHub profile without including the secret itself.

The actively supported configuration is the latest commit on `main`.

## Security model

Tracked settings are treated as code; mutable values are treated as data. MyHypr constrains settings to declared paths, writes them atomically, validates selectable values, and launches post-actions as argument vectors. Generated state is copied into normal home-directory files so applications cannot write back into Git through folded directory links.

Package installation uses signed Arch repositories and explicit AUR package declarations. Review AUR build files when prompted. The bootstrap does not download and execute opaque install scripts.

## Local safety gates

Every commit should pass:

```bash
./scripts/audit.sh --staged
```

Before publishing a new clone or release, also scan reachable history:

```bash
./scripts/audit.sh --history
```

The audit checks sensitive filenames, high-confidence credential signatures, unsafe credential storage, machine-specific home paths, large additions, whitespace, and configuration syntax. Gitleaks is used only after it detects a synthetic test secret; the built-in scanner remains active even when Gitleaks is unavailable or broken.

Never commit `.env` files, private keys, browser profiles, shell history, host-specific `local.lua`, or application-generated state. Treat migration and conflict archives under `~/.local/state/myhyprlandrice/` as private local data; they are intentionally ignored and must not be published.
