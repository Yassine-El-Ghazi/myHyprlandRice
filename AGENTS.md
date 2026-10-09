# Security report publication policy

Keep detailed security audit and re-audit reports private. Store them in the
ignored `.private-security-audits/` directory. Never stage, commit, attach to a
public issue or PR, or push these reports, including dated variants. Do not use
`git add -f` to bypass their exclusions.

Public commit and PR descriptions may summarize fixes and validation without
including detailed findings, suspected secret values, or private audit evidence.
