# approvegate-cli

A GitHub Action (and standalone script) that blocks a deploy job unless Approvegate
has a recorded, valid approval for the deploy being checked.

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

To check a specific approval record directly, pass its ApproveGate ID:

```yaml
- uses: ApproveGate/approvegate-cli@v1
  with:
    service: ledger-api
    change-request-id: cmtxrt6ef00008ompx0kxlmku
    environment: production
  env:
    APPROVEGATE_API_KEY: ${{ secrets.APPROVEGATE_API_KEY }}
```

Inputs:

| Input | Required | Notes |
|---|---|---|
| `service` | yes | No auto-detection — there's no reliable free signal for this in a monorepo. |
| `change-request-id` | no | Checks a specific ApproveGate approval/change request record directly. |
| `release` | no | Release/version identifier. Auto-derived from a tag push (`refs/tags/v2.14.3` → `v2.14.3`) when possible. |
| `branch` | no | Branch/ref identifier. Auto-derived from a branch push only when no `release` is provided. |
| `environment` | no | Falls back to the job's `environment:` name when GitHub Actions exposes it to the step. Required otherwise. |
| `force-approve` | no | Emergency override — always allows the deploy when `reason` is present. |
| `reason` | no | Recorded alongside the check. Required with `force-approve`. |
| `on-unreachable` | no | `fail` by default. Use `allow` to proceed unverified if Approvegate is unreachable after retries. |

Outputs:

| Output | Notes |
|---|---|
| `decision` | `allow` or `block`. |
| `unverified` | `true` only when `on-unreachable: allow` let the deploy proceed without verification. |
| `reason` | Human-readable decision or unverified fallback reason. |

At least one lookup key must be present after auto-resolution: `change-request-id`,
`release`, `branch`, or the commit SHA that GitHub exposes as `GITHUB_SHA`. If
you explicitly pass `release`, the action does **not** also auto-add `branch`
from `GITHUB_REF`; this prevents accidental checks that require an approval to
match both fields.

The job fails (non-zero exit) if the deploy isn't approved, if Approvegate is
unreachable, or if required inputs are missing. The only exception is the explicit
`on-unreachable: allow` fallback.

## Emergency override

`force-approve` is the manual override for a deploy Approvegate can reach and
record. It always requires a reason:

```yaml
- uses: ApproveGate/approvegate-cli@v1
  with:
    service: ledger-api
    release: v2.14.3
    environment: production
    force-approve: "true"
    reason: "SEV1 rollback, incident INC-4821"
  env:
    APPROVEGATE_API_KEY: ${{ secrets.APPROVEGATE_API_KEY }}
```

Approvegate records the deploy as an override with the actor, SHA, run URL, and
reason.

## Unreachable fallback

By default, network errors, timeouts, and 5xx responses fail the job after the
configured retries:

```yaml
with:
  on-unreachable: fail
```

For teams that need an outage escape hatch, `on-unreachable: allow` succeeds the
step after retries, sets `unverified=true`, writes a job summary, and uploads
`approvegate-unverified-deploy.json` as an artifact:

```yaml
- uses: ApproveGate/approvegate-cli@v1
  with:
    service: ledger-api
    release: v2.14.3
    environment: production
    on-unreachable: allow
  env:
    APPROVEGATE_API_KEY: ${{ secrets.APPROVEGATE_API_KEY }}
```

This is intentionally different from `force-approve`: if the service is
unreachable, Approvegate cannot record the deploy immediately. The GitHub run
summary and artifact are the evidence for that unverified deploy.

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

Each check call sends only: `service`, optional `changeRequestId`, `release`
and/or `branch`, `environment`, the commit `artifactSha`, GitHub actor/run
metadata, completed job statuses from the current workflow run, and (for the
override path) `forceApprove`/`reason`.
**No source code, file contents, or repository data is ever read or transmitted.** The
`APPROVEGATE_API_KEY` is read only from an environment variable — it is never
accepted as a CLI flag and never printed to the job log, including on error.

The completed-job status capture uses the workflow token against the GitHub
Actions jobs API. If that API call is unavailable or lacks permission, the check
continues without `pipelineStatuses`.

The CLI prints a safe request summary before contacting Approvegate:

```text
Approvegate check configuration:
  checksEndpoint: https://approvegate.example.com/api/v1/checks
  service: ledger-api
  changeRequestId: (none)
  release: v2.14.3
  branch: (none)
  environment: production
  artifactSha: abc123def456...
  forceApprove: false
  onUnreachable: fail
  timeoutSeconds: 10
  maxAttempts: 3
Approvegate API request attempt 1/3...
Approvegate API returned HTTP 200.
Approvegate decision: allow
Approvegate release request: https://approvegate.example.com/app/acme-corp-1/release-requests/cmtxrt6ef00008ompx0kxlmku
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
