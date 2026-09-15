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
#             [--force-approve] [--reason "<text>"] [--on-unreachable fail|allow]
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
#   GITHUB_TOKEN                     Optional. Used on GitHub Actions to collect
#                                    already-completed jobs from this run.

set -u
set -o pipefail

DEFAULT_API_URL="https://approvegate.io/api/v1/checks"
API_URL="${APPROVEGATE_API_URL:-$DEFAULT_API_URL}"
REQUEST_TIMEOUT_SECONDS="${APPROVEGATE_TIMEOUT_SECONDS:-10}"
MAX_ATTEMPTS="${APPROVEGATE_MAX_RETRIES:-3}"
RETRY_DELAY_SECONDS="${APPROVEGATE_RETRY_DELAY_SECONDS:-1}"

SERVICE=""
RELEASE=""
BRANCH=""
RELEASE_PROVIDED="false"
BRANCH_PROVIDED="false"
ENVIRONMENT=""
FORCE_APPROVE="false"
REASON=""
ON_UNREACHABLE="fail"
UNVERIFIED_DEPLOY_FILE="approvegate-unverified-deploy.json"

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

short_value() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf '%s' "(none)"
  elif [[ ${#value} -gt 12 ]]; then
    printf '%s' "${value:0:12}..."
  else
    printf '%s' "$value"
  fi
}

api_url_display() {
  printf '%s' "$API_URL" | sed -E 's/[?#].*$//'
}

print_request_summary() {
  local artifact_sha="$1"
  echo "Approvegate check configuration:"
  echo "  checksEndpoint: $(api_url_display)"
  echo "  service: ${SERVICE}"
  echo "  release: ${RELEASE:-"(none)"}"
  echo "  branch: ${BRANCH:-"(none)"}"
  echo "  environment: ${ENVIRONMENT}"
  echo "  artifactSha: $(short_value "$artifact_sha")"
  echo "  forceApprove: ${FORCE_APPROVE}"
  echo "  onUnreachable: ${ON_UNREACHABLE}"
  echo "  timeoutSeconds: ${REQUEST_TIMEOUT_SECONDS}"
  echo "  maxAttempts: ${MAX_ATTEMPTS}"
}

usage_error() {
  echo "error: $1" >&2
  echo "usage: check.sh --service <name> [--release <tag>] [--branch <ref>] [--environment <env>] [--force-approve] [--reason <text>] [--on-unreachable fail|allow]" >&2
  exit 1
}

write_output() {
  local key="$1"
  local value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >>"$GITHUB_OUTPUT"
  fi
}

append_summary() {
  local text="$1"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$text" >>"$GITHUB_STEP_SUMMARY"
  fi
}

github_run_url() {
  if [[ -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
    printf '%s/%s/actions/runs/%s' "${GITHUB_SERVER_URL:-https://github.com}" "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"
  fi
}

collect_github_pipeline_statuses() {
  if [[ -z "${GITHUB_TOKEN:-}" || -z "${GITHUB_REPOSITORY:-}" || -z "${GITHUB_RUN_ID:-}" ]]; then
    printf '%s' "[]"
    return 0
  fi

  local jobs_url="${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/jobs?per_page=100"
  local jobs_response
  jobs_response="$(curl -fsS \
    --max-time "$REQUEST_TIMEOUT_SECONDS" \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$jobs_url" 2>/dev/null)" || {
    printf '%s' "[]"
    return 0
  }

  printf '%s' "$jobs_response" | jq -c '[.jobs[]? | select(.status == "completed" and .conclusion != null) | {name, conclusion, url: .html_url}] | .[:50]' 2>/dev/null || printf '%s' "[]"
}

write_unverified_deploy_file() {
  local artifact_sha="$1"
  local reason_text="$2"
  jq -n \
    --arg service "$SERVICE" \
    --arg release "$RELEASE" \
    --arg branch "$BRANCH" \
    --arg environment "$ENVIRONMENT" \
    --arg artifactSha "$artifact_sha" \
    --arg reason "$reason_text" \
    --arg actorProvider "github" \
    --arg actorLogin "${GITHUB_ACTOR:-}" \
    --arg actorId "${GITHUB_ACTOR_ID:-}" \
    --arg triggeringActorLogin "${GITHUB_TRIGGERING_ACTOR:-}" \
    --arg ciProvider "github_actions" \
    --arg ciRepo "${GITHUB_REPOSITORY:-}" \
    --arg ciWorkflow "${GITHUB_WORKFLOW:-}" \
    --arg ciJob "${GITHUB_JOB:-}" \
    --arg ciRunId "${GITHUB_RUN_ID:-}" \
    --arg ciRunAttempt "${GITHUB_RUN_ATTEMPT:-}" \
    --arg ciRunUrl "$(github_run_url)" \
    '{
      service: $service,
      environment: $environment,
      artifactSha: $artifactSha,
      reason: $reason,
      actor: {provider: $actorProvider, login: $actorLogin, id: $actorId, triggeringLogin: $triggeringActorLogin},
      ci: {provider: $ciProvider, repo: $ciRepo, workflow: $ciWorkflow, job: $ciJob, runId: $ciRunId, runAttempt: $ciRunAttempt, runUrl: $ciRunUrl}
    }
    + (if $release != "" then {release: $release} else {} end)
    + (if $branch != "" then {branch: $branch} else {} end)' >"$UNVERIFIED_DEPLOY_FILE"
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
        RELEASE_PROVIDED="true"
        shift 2
        ;;
      --branch)
        [[ $# -ge 2 ]] || usage_error "--branch requires a value"
        BRANCH="$2"
        BRANCH_PROVIDED="true"
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
      --on-unreachable)
        [[ $# -ge 2 ]] || usage_error "--on-unreachable requires a value"
        ON_UNREACHABLE="$2"
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

  if [[ "$RELEASE_PROVIDED" != "true" && -z "$RELEASE" ]]; then
    RELEASE="$(extract_tag_from_ref "${GITHUB_REF:-}")"
  fi

  if [[ "$BRANCH_PROVIDED" != "true" && -z "$BRANCH" && -z "$RELEASE" ]]; then
    BRANCH="$(extract_branch_from_ref "${GITHUB_REF:-}")"
  fi

  if [[ "$BRANCH_PROVIDED" != "true" && -z "$BRANCH" && -z "$RELEASE" && "${GITHUB_REF_TYPE:-}" == "branch" ]]; then
    BRANCH="${GITHUB_REF_NAME:-}"
  fi

  if [[ -z "$RELEASE" && -z "$BRANCH" ]]; then
    usage_error "no --release or --branch was passed, and neither could be derived from this run (GITHUB_REF=${GITHUB_REF:-<unset>}). Pass one explicitly."
  fi

  if [[ -z "$ENVIRONMENT" ]]; then
    usage_error "--environment is required (the job has no environment: set, or this runner doesn't expose it). Pass --environment explicitly."
  fi

  if [[ "$ON_UNREACHABLE" != "fail" && "$ON_UNREACHABLE" != "allow" ]]; then
    usage_error "--on-unreachable must be either 'fail' or 'allow'"
  fi

  if [[ "$FORCE_APPROVE" == "true" && -z "$REASON" ]]; then
    usage_error "--reason is required when --force-approve is used"
  fi

  if [[ -z "${APPROVEGATE_API_KEY:-}" ]]; then
    usage_error "APPROVEGATE_API_KEY is not set. Set it as a secret-backed environment variable, never as a flag."
  fi
}

main() {
  parse_args "$@"
  validate_and_resolve

  local artifact_sha="${GITHUB_SHA:-}"
  print_request_summary "$artifact_sha"
  local run_url
  run_url="$(github_run_url)"
  local pipeline_statuses
  pipeline_statuses="$(collect_github_pipeline_statuses)"

  local payload
  payload="$(jq -nc \
    --arg service "$SERVICE" \
    --arg release "$RELEASE" \
    --arg branch "$BRANCH" \
    --arg environment "$ENVIRONMENT" \
    --arg artifactSha "$artifact_sha" \
    --argjson forceApprove "$FORCE_APPROVE" \
    --arg reason "$REASON" \
    --arg actorProvider "github" \
    --arg actorLogin "${GITHUB_ACTOR:-}" \
    --arg actorId "${GITHUB_ACTOR_ID:-}" \
    --arg triggeringActorLogin "${GITHUB_TRIGGERING_ACTOR:-}" \
    --arg ciProvider "github_actions" \
    --arg ciRepo "${GITHUB_REPOSITORY:-}" \
    --arg ciWorkflow "${GITHUB_WORKFLOW:-}" \
    --arg ciJob "${GITHUB_JOB:-}" \
    --arg ciRunId "${GITHUB_RUN_ID:-}" \
    --arg ciRunAttempt "${GITHUB_RUN_ATTEMPT:-}" \
    --arg ciRunUrl "$run_url" \
    --argjson pipelineStatuses "$pipeline_statuses" \
    '{service: $service, environment: $environment, artifactSha: $artifactSha,
      actor: {provider: $actorProvider, login: $actorLogin, id: $actorId, triggeringLogin: $triggeringActorLogin},
      ci: {provider: $ciProvider, repo: $ciRepo, workflow: $ciWorkflow, job: $ciJob, runId: $ciRunId, runAttempt: $ciRunAttempt, runUrl: $ciRunUrl},
      pipelineStatuses: $pipelineStatuses}
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
    echo "Approvegate API request attempt ${attempt}/${MAX_ATTEMPTS}..."
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
      echo "Approvegate API returned HTTP ${http_status}."
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
    if [[ "$ON_UNREACHABLE" == "allow" ]]; then
      local unverified_reason="Approvegate API unreachable after ${attempt} attempt(s); deploy was not verified."
      echo "Deploy allowed without verification because --on-unreachable allow is set." >&2
      write_unverified_deploy_file "$artifact_sha" "$unverified_reason"
      write_output "decision" "allow"
      write_output "unverified" "true"
      write_output "reason" "$unverified_reason"
      append_summary "## ApproveGate deploy check"
      append_summary ""
      append_summary "Deploy proceeded without ApproveGate verification because the service was unreachable after retries."
      append_summary ""
      append_summary "Evidence file: ${UNVERIFIED_DEPLOY_FILE}"
      exit 0
    else
      echo "Deploy blocked: could not reach Approvegate to verify approval." >&2
      exit 2
    fi
  fi

  if [[ "$http_status" -ge 500 ]]; then
    echo "Approvegate API unreachable: server returned HTTP $http_status after ${attempt} attempt(s)." >&2
    if [[ "$ON_UNREACHABLE" == "allow" ]]; then
      local unverified_reason="Approvegate API returned HTTP ${http_status} after ${attempt} attempt(s); deploy was not verified."
      echo "Deploy allowed without verification because --on-unreachable allow is set." >&2
      write_unverified_deploy_file "$artifact_sha" "$unverified_reason"
      write_output "decision" "allow"
      write_output "unverified" "true"
      write_output "reason" "$unverified_reason"
      append_summary "## ApproveGate deploy check"
      append_summary ""
      append_summary "Deploy proceeded without ApproveGate verification because the service returned HTTP ${http_status} after retries."
      append_summary ""
      append_summary "Evidence file: ${UNVERIFIED_DEPLOY_FILE}"
      exit 0
    else
      echo "Deploy blocked: could not reach Approvegate to verify approval." >&2
      exit 2
    fi
  fi

  local decision=""
  local reason_text=""
  local release_request_url=""
  if decision="$(printf '%s' "$body" | jq -er '.decision' 2>/dev/null)"; then
    reason_text="$(printf '%s' "$body" | jq -r '.reason // "(no reason provided)"' 2>/dev/null)"
    release_request_url="$(printf '%s' "$body" | jq -r '.releaseRequestUrl // .links.releaseRequest // .releaseRequestPath // ""' 2>/dev/null)"
  fi

  case "$decision" in
    allow)
      echo "Approvegate decision: allow"
      if [[ -n "$release_request_url" ]]; then
        echo "Approvegate release request: ${release_request_url}"
      fi
      echo "Approvegate: deploy allowed for ${SERVICE}@${RELEASE:-$BRANCH} in ${ENVIRONMENT}. ${reason_text}"
      write_output "decision" "allow"
      write_output "unverified" "false"
      write_output "reason" "$reason_text"
      exit 0
      ;;
    block)
      echo "Approvegate decision: block" >&2
      if [[ -n "$release_request_url" ]]; then
        echo "Approvegate release request: ${release_request_url}" >&2
      fi
      echo "Approvegate: deploy blocked for ${SERVICE}@${RELEASE:-$BRANCH} in ${ENVIRONMENT}: ${reason_text}" >&2
      write_output "decision" "block"
      write_output "unverified" "false"
      write_output "reason" "$reason_text"
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
