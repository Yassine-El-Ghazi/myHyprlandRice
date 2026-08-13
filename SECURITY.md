# Security policy

## Reporting a vulnerability

Do not open a public issue containing a credential, private path, or exploit detail. Revoke exposed credentials first, then use GitHub's private vulnerability reporting feature when it is available. Otherwise, contact the repository owner through their GitHub profile without including the secret itself.

The actively supported configuration is the latest commit on `main`.

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

Never commit `.env` files, private keys, browser profiles, shell history, host-specific `local.lua`, or application-generated state.
