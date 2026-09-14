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

## Issue and agent delegation: future opt-in

The custom agent is .github/agents/dotfiles-security.agent.md. Once this file is
on the default branch, an authorized user with Copilot cloud agent access can
assign an issue to Copilot and select dotfiles-security. Include the failed run
URL, check name, and sanitized evidence, then review the tested PR. Never copy
suspected secret values into a public issue.

Automatic issue creation and assignment are not enabled. GitHub's current API
requires a user token (PAT or GitHub App user-to-server token) for Copilot
assignment, plus eligible Copilot access and repository/organization policy.
The ordinary GITHUB_TOKEN is not a substitute. No new credential is required
for the deterministic scanning implemented here.

If automatic triage becomes necessary:

1. Add a reporting job in Validate, dependent on both scan jobs, only for
   schedule or manual dispatch on the default branch. Grant issues: write only
   to that job. Do not check out or execute repository code in it, consume PR
   artifacts, or run it for pull requests. Use fixed trusted code and pass
   context values as data, never interpolate them into shell source.
2. Serialize reporting with a repository-specific concurrency group. Paginate
   issues and create/update one bot-owned issue identified by a stable marker;
   update its body rather than adding weekly comments. Include failed job names
   and the run URL, not raw logs. Reopen the same issue on recurrence. Record
   recovery without automatically merging or declaring a fix reviewed.
3. Confirm plan eligibility, repository access, organization policy, and current
   API permissions. Prefer manual assignment; if approved later, use a dedicated
   user-authorized GitHub App integration rather than a broad long-lived PAT.
   Keep its credential outside untrusted validation jobs.
4. Assign Copilot using the documented issue-assignee API, supplying
   agent_assignment.custom_agent as dotfiles-security and the intended base
   branch. Handle errors and repeated runs without duplicate agent sessions.
   Require human review and existing validation on resulting PRs.

References:

- [Zizmor integration and annotation behavior](https://docs.zizmor.sh/integrations/)
- [Custom agent configuration](https://docs.github.com/en/copilot/reference/custom-agents-configuration)
- [Copilot API authentication and assignment](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/use-cloud-agent-via-the-api)
