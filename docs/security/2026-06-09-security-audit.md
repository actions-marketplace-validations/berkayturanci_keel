# Security Audit — 2026-06-09

## Scope

This audit reviewed keel at `2cef711572e8cdb41fb2a5ab187d84f494d7dc78`
(`v1.0.1` public release line, after the v1 public-surface sweep), with focus on:

- Python package dependency and packaging exposure.
- GitHub Actions permissions, pinned actions, publishing, release assets, and provenance.
- Runtime trust boundaries for command gates, extensions, adapters, GitHub transport,
  capture/redaction, and optional `jury` integration.
- Public repository hygiene for secrets, concrete consumer names, and security metadata.
- GitHub repository security settings visible through the authenticated GitHub API.

## Summary

No critical or high-severity application security issue was found in keel's source tree.
The core remains deterministic and small, uses `yaml.safe_load`, keeps GitHub and git calls
on argv wrappers, documents the command-gate shell boundary, redacts capture artifacts before
durability, and ships releases through OIDC trusted publishing with release assets and
checksums.

The audit opened two follow-up hardening issues:

1. GitHub secret scanning and push protection are disabled for the repository.
2. A few consumer-neutrality guards use concrete consumer-name literals as forbidden tokens.

One accepted risk remains documented rather than treated as a vulnerability: command gates
execute project-configured shell commands. This is keel's intended model and is already
covered in `SECURITY.md`.

## Evidence

### Automated checks

| Check | Result |
|---|---|
| `pip-audit` over the audit virtual environment | Initially found only `pip` in the audit venv at `26.1.1`; after upgrading the audit venv to `pip 26.1.2`, no known vulnerabilities were found |
| `bandit -r src scripts -f txt` | No high-severity findings |
| Bandit medium finding | `B604` on `src/keel/runner.py` because command gates intentionally use `shell=True` |
| Bandit low findings | Subprocess import/call reminders and false positives on consent metadata strings |
| GitHub code-scanning open alerts | 0 |
| GitHub Dependabot open alerts | 0 |
| Secret-scanning alerts endpoint | Returned `404` because secret scanning is disabled |
| Workflow `uses:` pin check | No unpinned action refs found; all `uses:` refs are exact 40-character SHAs |
| Release smoke test for PyPI `keel-workflow==1.0.1` | Passed; `keel version` returned `keel 1.0.1`; 17 adapters/skills were present |
| GitHub Release `SHA256SUMS` verification | Wheel, source distribution, and SBOM checksums passed |
| GitHub attestation verification for the `v1.0.1` wheel | `gh attestation verify ... --repo berkayturanci/keel` exited 0 |

### Repository and workflow controls

- Repository is public and includes `LICENSE`, `SECURITY.md`, `CONTRIBUTING.md`,
  `CODE_OF_CONDUCT.md`, issue templates, a PR template, `CODEOWNERS`, CodeQL, Scorecard,
  Dependabot, and release documentation.
- Latest `main` runs after #188 completed successfully for CI, CodeQL, Scorecard, and Pages.
- GitHub Actions use read-only top-level permissions by default, with job-scoped elevations
  for publishing, Pages deployment, CodeQL upload, and Scorecard OIDC.
- Workflow `uses:` references are pinned to exact commit SHAs.
- The publish workflow uses PyPI trusted publishing through OIDC, creates a GitHub Release,
  uploads wheel, source distribution, SBOM, and `SHA256SUMS`, and emits build-provenance
  attestations.
- Branch protection for `main` has strict required status checks for the full Python
  version/OS matrix and disables force pushes and branch deletions. Required PR approvals are
  not enforced by GitHub settings; keel's review policy is enforced by workflow/process.

### Trust boundaries reviewed

- `src/keel/config.py`, `src/keel/install.py`, and extension metadata parsing use
  `yaml.safe_load`.
- `src/keel/git.py` and `src/keel/github.py` invoke `git` / `gh` through argv wrappers, not a
  shell.
- `src/keel/runner.py` intentionally executes project-provided command gates through a shell.
  This is documented in `SECURITY.md` and should be treated like running a Makefile or CI
  script from the target repository.
- `src/keel/jury.py` writes the diff to a temporary file, invokes the optional `jury` CLI
  through argv, and unlinks the temporary file after execution.
- Operator consent contracts record approved scopes and explicitly avoid recording secret
  values.
- Capture redaction covers private-key blocks, bearer tokens, GitHub tokens,
  credential-bearing URLs, and token/password-style assignments, with project-owned deny
  patterns compiled before durable capture artifacts are accepted.

## Findings

### Medium — GitHub secret scanning and push protection are disabled

**Evidence:** `gh api repos/berkayturanci/keel --jq '.security_and_analysis'` reported:

```json
{
  "dependabot_security_updates": {"status": "enabled"},
  "secret_scanning": {"status": "disabled"},
  "secret_scanning_non_provider_patterns": {"status": "disabled"},
  "secret_scanning_push_protection": {"status": "disabled"},
  "secret_scanning_validity_checks": {"status": "disabled"}
}
```

The secret-scanning alerts endpoint also returned `404` with the message
`Secret scanning is disabled on this repository.`

**Impact:** GitHub will not surface repository-level secret scanning alerts for committed
credentials, and push protection will not block supported secret patterns before they land.
Keel has its own capture redaction safeguards, but repository-level secret scanning is still
an important open-source safety net.

**Recommendation:** Enable GitHub secret scanning. If available for this repository/account,
also enable push protection, non-provider patterns, and validity checks.

**Tracking:** [#190](https://github.com/berkayturanci/keel/issues/190).

**Status:** Resolved on 2026-06-09 by enabling GitHub secret scanning and push protection
for the repository. The authenticated repository API now reports
`secret_scanning.status=enabled` and `secret_scanning_push_protection.status=enabled`.
Non-provider patterns and validity checks remain disabled in the current repository
settings surface.

### Low — Concrete consumer-name literals appear in neutrality guards

**Evidence:** The public-hygiene scan found concrete consumer/project-name literals used as
forbidden tokens in neutrality tests and release-smoke checks.

**Impact:** The guards are trying to prevent consumer-specific leakage, but storing concrete
consumer names in public test fixtures and scripts still exposes the names. Public open-source
artifacts should use generic sentinel names for this class of check.

**Recommendation:** Replace the concrete literals with generic sentinel names while keeping
the same consumer-neutrality coverage.

**Tracking:** [#191](https://github.com/berkayturanci/keel/issues/191).

**Status:** Resolved on 2026-06-09 by replacing concrete consumer-name deny-list literals
with generic sentinel names in the consumer-neutrality guards and release-smoke checks.

## Accepted Risk

### Command gates execute configured shell commands

`src/keel/runner.py` uses `shell=True` for command gates. This is intentional: projects
configure build, lint, and command extension bodies as shell snippets. The risk is equivalent
to running a repository's Makefile, package scripts, or CI commands. The boundary is
documented in `SECURITY.md`, and keel should continue treating untrusted project configs as
untrusted executable input.

No issue was opened for this item because it is core behavior, not an implementation bug.

## No Issue Opened For

- Bandit low false positives on consent metadata strings.
- Bandit subprocess import/call reminders where commands are passed as argv or are
  release-smoke tooling.
- The unsigned `v1.0.1` annotated tag: release tag signing policy already states that signed
  tags are preferred, annotated tags are accepted when signing is unavailable, and lightweight
  production tags are not allowed. The release also has OIDC publishing, checksums, SBOM, and
  build-provenance attestation evidence.
- Required PR approvals not being enforced by GitHub branch protection. This is a process
  hardening option rather than an immediate source vulnerability; keel's merge policy still
  requires review evidence before merge.

## Recommended Next Steps

1. Ship #190 to enable repository secret scanning and push protection where supported.
2. Ship #191 to replace concrete consumer-name literals with generic sentinels.
3. Re-run this audit after those repository-setting and hygiene follow-ups land.
