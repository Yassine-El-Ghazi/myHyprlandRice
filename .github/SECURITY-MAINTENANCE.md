# Automated security maintenance

Validate runs on pushes, pull requests, manual dispatch, and Tuesdays at 06:23
UTC. Scheduled workflows use the default branch. GitHub can delay schedules and
disables them on public repositories after 60 days of inactivity; check Actions
if expected runs stop.

The existing Arch validation job retains the required-tools suite, configuration
variants, unprivileged execution, and full privacy/history audit. Checkout fetches
full history without persisting credentials. The audit is attempted even after
an earlier failure, unless cancelled; infrastructure or checkout failure can
still prevent a usable audit.

An independent Zizmor job scans workflows on every trigger. Its action is pinned
to a commit and scanner to 1.30.1. Pedantic annotation mode fails on findings
without security-events write access or Advanced Security. Online audits use
only the ephemeral read-only GitHub token. No findings are suppressed.
Dependabot's existing GitHub Actions updates maintain action pins; review the
scanner version input when updating the action.
The Arch amd64 image is digest-pinned. Its job still performs a full package
upgrade to test current Arch releases. Review its digest periodically against
the official archlinux:base-devel registry manifest; do not assume GitHub
Actions Dependabot updates container-image digests. Verify the new image and run
validation before accepting a digest change.

Local verification from the repository root:

```sh
./scripts/check.sh --require-tools
./scripts/audit.sh --history
uvx zizmor==1.30.1 --offline --persona pedantic .github/workflows
```

Offline scanning covers local rules; CI also checks online metadata. Review the
complete output, not just GitHub's limited annotations. All jobs have only
contents: read. No privileged PR triggers, stored credentials, caches, artifact
transfers, issue writers, or automatic merges are introduced. Existing Gitleaks,
ShellCheck, custom checks, and regression tests remain the primary dotfiles
checks. Additional general-purpose scanners are not required for this change.

Audits require a working Gitleaks installation, including its synthetic-secret
self-test. Missing/broken scanners, unreadable inputs, and failed Git inventories
fail the audit rather than silently reducing coverage. Temporary scan data is
private and removed on exit; diagnostics do not print input contents.

## Responding to a failed check

Review the failed job in Actions, make a reviewed fix, and rerun validation and
the history audit before pushing. When reporting a failure, include the run URL,
check name, and sanitized evidence. Never copy suspected secret values into a
public issue.

References:

- [Zizmor integration and annotation behavior](https://docs.zizmor.sh/integrations/)
