# approvegate-cli

A GitHub Action (and standalone script) that blocks a deploy job unless Approvegate
has a recorded, valid approval for the service/release/environment being deployed.

## Usage (GitHub Action)

```yaml
- uses: ApproveGate/approvegate-cli@v1
  with:
    service: ledger-api
    release: v2.14.3
    environment: production
  env:
    APPROVEGATE_API_KEY: ${{ secrets.APPROVEGATE_API_KEY }}
```

For branch-gated deploys, pass the branch as the release identifier if that is
how the approval was created:

```yaml
- uses: ApproveGate/approvegate-cli@v1
  with:
    service: ledger-api
    release: ${{ github.ref_name }}
    environment: production
  env:
    APPROVEGATE_API_KEY: ${{ secrets.APPROVEGATE_API_KEY }}
```

Inputs:

| Input | Required | Notes |
|---|---|---|
| `service` | yes | No auto-detection — there's no reliable free signal for this in a monorepo. |
| `release` | no | Release/version identifier. Auto-derived from a tag push (`refs/tags/v2.14.3` → `v2.14.3`) when possible. |
| `branch` | no | Branch/ref identifier. Auto-derived from a branch push only when no `release` is provided. |
| `environment` | no | Falls back to the job's `environment:` name when GitHub Actions exposes it to the step. Required otherwise. |
| `force-approve` | no | Emergency override — always allows the deploy. Pair with `reason`. |
| `reason` | no | Recorded alongside the check, especially useful with `force-approve`. |

At least one of `release` or `branch` must be present after auto-resolution. If
you explicitly pass `release`, the action does **not** also auto-add `branch`
from `GITHUB_REF`; this prevents accidental checks that require an approval to
match both fields.

The job fails (non-zero exit) if the deploy isn't approved, if Approvegate is
unreachable, or if required inputs are missing — it never silently allows a
deploy it couldn't verify.

## Usage (standalone script)

Outside of GitHub Actions (or from another CI system), call `check.sh` directly:

```bash
export APPROVEGATE_API_KEY="..."
./check.sh --service ledger-api --release v2.14.3 --environment production
```

Branch-only checks are also supported:

```bash
export APPROVEGATE_API_KEY="..."
./check.sh --service ledger-api --branch main --environment production
```

Requires `bash`, `curl`, and `jq` on the runner (all preinstalled on
GitHub-hosted `ubuntu-latest` runners; self-hosted runners need to have them
available).

## What gets sent to Approvegate — and what doesn't

Each check call sends only: `service`, `release` and/or `branch`, `environment`,
the commit `artifactSha`, and (for the override path) `forceApprove`/`reason`.
**No source code, file contents, or repository data is ever read or transmitted.** The
`APPROVEGATE_API_KEY` is read only from an environment variable — it is never
accepted as a CLI flag and never printed to the job log, including on error.

The CLI prints a safe request summary before contacting Approvegate:

```text
Approvegate check configuration:
  endpoint: https://approvegate.example.com/...
  service: ledger-api
  release: v2.14.3
  branch: (none)
  environment: production
  artifactSha: abc123def456...
  forceApprove: false
  timeoutSeconds: 10
  maxAttempts: 3
```

The API key and raw headers are never logged.

## Versioning

Pin one of:

- **`@v1`** — tracks the latest `v1.x` release, so you automatically get
  patches and fixes.
- **A full commit SHA** — maximum trust and reproducibility; the action can
  never change under you without a new commit in your workflow file.

## Development

```bash
bash tests/test_unit.sh          # arg parsing / validation, no network
bash tests/test_integration.sh   # end-to-end against tests/mock_server.py
shellcheck check.sh
```
