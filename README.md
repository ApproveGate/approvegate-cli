# approvegate-cli

A GitHub Action (and standalone script) that blocks a deploy job unless Approvegate
has a recorded, valid approval for the service/release/environment being deployed.

## Usage (GitHub Action)

```yaml
- uses: ApproveGate/approvegate-cli@v1
  with:
    service: ledger-api
  env:
    APPROVEGATE_API_KEY: ${{ secrets.APPROVEGATE_API_KEY }}
```

Inputs:

| Input | Required | Notes |
|---|---|---|
| `service` | yes | No auto-detection — there's no reliable free signal for this in a monorepo. |
| `release` | no | Auto-derived from a tag push (`refs/tags/v2.14.3` → `v2.14.3`). Required if the run wasn't triggered by a tag. |
| `environment` | no | Falls back to the job's `environment:` name when GitHub Actions exposes it to the step. Required otherwise. |
| `force-approve` | no | Emergency override — always allows the deploy. Pair with `reason`. |
| `reason` | no | Recorded alongside the check, especially useful with `force-approve`. |

The job fails (non-zero exit) if the deploy isn't approved, if Approvegate is
unreachable, or if required inputs are missing — it never silently allows a
deploy it couldn't verify.

## Usage (standalone script)

Outside of GitHub Actions (or from another CI system), call `check.sh` directly:

```bash
export APPROVEGATE_API_KEY="..."
./check.sh --service ledger-api --release v2.14.3 --environment production
```

Requires `bash`, `curl`, and `jq` on the runner (all preinstalled on
GitHub-hosted `ubuntu-latest` runners; self-hosted runners need to have them
available).

## What gets sent to Approvegate — and what doesn't

Each check call sends only: `service`, `release`, `environment`, the commit
`artifactSha`, and (for the override path) `forceApprove`/`reason`. **No source
code, file contents, or repository data is ever read or transmitted.** The
`APPROVEGATE_API_KEY` is read only from an environment variable — it is never
accepted as a CLI flag and never printed to the job log, including on error.

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
