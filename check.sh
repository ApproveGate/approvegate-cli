#!/usr/bin/env bash
#
# Approvegate deploy check.
#
# Calls POST /api/v1/checks and exits 0 (allow) or non-zero (block / error).
# Never accepts the API key as a flag — read only from APPROVEGATE_API_KEY so
# it can't leak into job logs or process listings.
#
# Usage:
#   check.sh --service <name> [--release <tag>] [--branch <ref>] [--environment <env>] \
#             [--force-approve] [--reason "<text>"]
#
# Required env:
#   APPROVEGATE_API_KEY   Tenant API key, sent as the X-Api-Key header.
# Optional env:
#   APPROVEGATE_API_URL          Overrides the checks endpoint (default: production).
#   GITHUB_SHA                   Commit SHA, sent as artifactSha. Set automatically
#                                 on GitHub Actions runners.
#   GITHUB_REF                   Used to derive --release from a tag push
#                                 (refs/tags/v2.14.3 -> v2.14.3) or --branch from
#                                 a branch push (refs/heads/main -> main) when not
#                                 passed explicitly.
#   GITHUB_REF_NAME              Used as a fallback for --branch on GitHub Actions
#                                 branch-triggered runs.
#   APPROVEGATE_TIMEOUT_SECONDS  Per-request curl timeout (default: 10).
#   APPROVEGATE_MAX_RETRIES      Attempts on connection errors/timeouts/5xx (default: 3).
#   APPROVEGATE_RETRY_DELAY_SECONDS  Delay between retry attempts (default: 1).

set -u
set -o pipefail

DEFAULT_API_URL="https://approvegate.trhks9stfcjz6.us-east-1.cs.amazonlightsail.com/api/v1/checks"
API_URL="${APPROVEGATE_API_URL:-$DEFAULT_API_URL}"
REQUEST_TIMEOUT_SECONDS="${APPROVEGATE_TIMEOUT_SECONDS:-10}"
MAX_ATTEMPTS="${APPROVEGATE_MAX_RETRIES:-3}"
RETRY_DELAY_SECONDS="${APPROVEGATE_RETRY_DELAY_SECONDS:-1}"

SERVICE=""
RELEASE=""
BRANCH=""
ENVIRONMENT=""
FORCE_APPROVE="false"
REASON=""

# Extracts "v2.14.3" from "refs/tags/v2.14.3"; prints nothing for any other ref.
extract_tag_from_ref() {
  local ref="$1"
  if [[ "$ref" =~ ^refs/tags/(.+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Extracts "main" from "refs/heads/main"; prints nothing for any other ref.
extract_branch_from_ref() {
  local ref="$1"
  if [[ "$ref" =~ ^refs/heads/(.+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

usage_error() {
  echo "error: $1" >&2
  echo "usage: check.sh --service <name> [--release <tag>] [--branch <ref>] [--environment <env>] [--force-approve] [--reason <text>]" >&2
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --service)
        [[ $# -ge 2 ]] || usage_error "--service requires a value"
        SERVICE="$2"
        shift 2
        ;;
      --release)
        [[ $# -ge 2 ]] || usage_error "--release requires a value"
        RELEASE="$2"
        shift 2
        ;;
      --branch)
        [[ $# -ge 2 ]] || usage_error "--branch requires a value"
        BRANCH="$2"
        shift 2
        ;;
      --environment)
        [[ $# -ge 2 ]] || usage_error "--environment requires a value"
        ENVIRONMENT="$2"
        shift 2
        ;;
      --force-approve)
        FORCE_APPROVE="true"
        shift
        ;;
      --reason)
        [[ $# -ge 2 ]] || usage_error "--reason requires a value"
        REASON="$2"
        shift 2
        ;;
      *)
        usage_error "unknown argument: $1"
        ;;
    esac
  done
}

validate_and_resolve() {
  if [[ -z "$SERVICE" ]]; then
    usage_error "--service is required (there is no reliable way to infer it in a monorepo)"
  fi

  if [[ -z "$RELEASE" ]]; then
    RELEASE="$(extract_tag_from_ref "${GITHUB_REF:-}")"
  fi

  if [[ -z "$BRANCH" ]]; then
    BRANCH="$(extract_branch_from_ref "${GITHUB_REF:-}")"
  fi

  if [[ -z "$BRANCH" && "${GITHUB_REF_TYPE:-}" == "branch" ]]; then
    BRANCH="${GITHUB_REF_NAME:-}"
  fi

  if [[ -z "$RELEASE" && -z "$BRANCH" ]]; then
    usage_error "no --release or --branch was passed, and neither could be derived from this run (GITHUB_REF=${GITHUB_REF:-<unset>}). Pass one explicitly."
  fi

  if [[ -z "$ENVIRONMENT" ]]; then
    usage_error "--environment is required (the job has no environment: set, or this runner doesn't expose it). Pass --environment explicitly."
  fi

  if [[ -z "${APPROVEGATE_API_KEY:-}" ]]; then
    usage_error "APPROVEGATE_API_KEY is not set. Set it as a secret-backed environment variable, never as a flag."
  fi
}

main() {
  parse_args "$@"
  validate_and_resolve

  local artifact_sha="${GITHUB_SHA:-}"

  local payload
  payload="$(jq -nc \
    --arg service "$SERVICE" \
    --arg release "$RELEASE" \
    --arg branch "$BRANCH" \
    --arg environment "$ENVIRONMENT" \
    --arg artifactSha "$artifact_sha" \
    --argjson forceApprove "$FORCE_APPROVE" \
    --arg reason "$REASON" \
    '{service: $service, environment: $environment, artifactSha: $artifactSha}
     + (if $release != "" then {release: $release} else {} end)
     + (if $branch != "" then {branch: $branch} else {} end)
     + (if $forceApprove then {forceApprove: true} else {} end)
     + (if $reason != "" then {reason: $reason} else {} end)')" || {
    echo "error: failed to build request payload" >&2
    exit 1
  }

  local response
  local curl_status
  local http_status
  local body
  local attempt=1

  while :; do
    response="$(curl -sS \
      --max-time "$REQUEST_TIMEOUT_SECONDS" \
      -X POST "$API_URL" \
      -H "Content-Type: application/json" \
      -H "X-Api-Key: $APPROVEGATE_API_KEY" \
      -d "$payload" \
      -w $'\n%{http_code}')"
    curl_status=$?

    if [[ $curl_status -eq 0 ]]; then
      http_status="${response##*$'\n'}"
      body="${response%$'\n'*}"
      # Only 5xx is treated as a transient/"unreachable" condition worth
      # retrying — 4xx is a real rejection (bad key, bad payload) that
      # won't fix itself on retry.
      if [[ "$http_status" -lt 500 ]]; then
        break
      fi
    fi

    if [[ $attempt -ge $MAX_ATTEMPTS ]]; then
      break
    fi
    echo "Approvegate API call failed (attempt ${attempt}/${MAX_ATTEMPTS}), retrying in ${RETRY_DELAY_SECONDS}s..." >&2
    attempt=$((attempt + 1))
    sleep "$RETRY_DELAY_SECONDS"
  done

  if [[ $curl_status -ne 0 ]]; then
    echo "Approvegate API unreachable: curl exit code $curl_status (network error or timeout after ${REQUEST_TIMEOUT_SECONDS}s) after ${attempt} attempt(s)." >&2
    echo "Deploy blocked: could not reach Approvegate to verify approval." >&2
    exit 2
  fi

  if [[ "$http_status" -ge 500 ]]; then
    echo "Approvegate API unreachable: server returned HTTP $http_status after ${attempt} attempt(s)." >&2
    echo "Deploy blocked: could not reach Approvegate to verify approval." >&2
    exit 2
  fi

  local decision=""
  local reason_text=""
  if decision="$(printf '%s' "$body" | jq -er '.decision' 2>/dev/null)"; then
    reason_text="$(printf '%s' "$body" | jq -r '.reason // "(no reason provided)"' 2>/dev/null)"
  fi

  case "$decision" in
    allow)
      echo "Approvegate: deploy allowed for ${SERVICE}@${RELEASE:-$BRANCH} in ${ENVIRONMENT}. ${reason_text}"
      exit 0
      ;;
    block)
      echo "Approvegate: deploy blocked for ${SERVICE}@${RELEASE:-$BRANCH} in ${ENVIRONMENT}: ${reason_text}" >&2
      exit 1
      ;;
    *)
      echo "Approvegate API rejected the request (HTTP $http_status): ${body}" >&2
      echo "Deploy blocked: response did not contain a usable decision." >&2
      exit 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
