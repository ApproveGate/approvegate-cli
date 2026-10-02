#!/usr/bin/env bash
# Unit tests for check.sh: pure-function behavior and argument validation.
# No network calls are made here — every case fails before check.sh would
# ever hit the API.
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SH="$SCRIPT_DIR/../check.sh"

pass_count=0
fail_count=0

# shellcheck disable=SC1090
source "$CHECK_SH"

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo "FAIL: $desc"
    echo "  expected: $expected"
    echo "  actual:   $actual"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo "FAIL: $desc"
    echo "  expected to contain: $needle"
    echo "  actual: $haystack"
  fi
}

# --- extract_tag_from_ref ---

assert_eq "tag ref extracts version" \
  "v2.14.3" "$(extract_tag_from_ref "refs/tags/v2.14.3")"

assert_eq "branch ref extracts nothing" \
  "" "$(extract_tag_from_ref "refs/heads/main")"

assert_eq "empty ref extracts nothing" \
  "" "$(extract_tag_from_ref "")"

# --- extract_branch_from_ref ---

assert_eq "branch ref extracts branch" \
  "main" "$(extract_branch_from_ref "refs/heads/main")"

assert_eq "tag ref extracts no branch" \
  "" "$(extract_branch_from_ref "refs/tags/v2.14.3")"

# --- display_sha ---

assert_eq "long sha is shortened" \
  "9f2a1c4e7b0d…a83c17b" "$(display_sha "9f2a1c4e7b0d11223344556677889900aa83c17b")"

assert_eq "short sha passes through" \
  "abc123def456" "$(display_sha "abc123def456")"

assert_eq "empty sha shows none" \
  "(none)" "$(display_sha "")"

# --- reason_for_code ---

assert_eq "PENDING reason names release and environment" \
  "v2.14.3 has not been approved for production deployment." "$(reason_for_code PENDING v2.14.3 production "raw")"

assert_eq "DEPLOY_FROZEN reason names environment" \
  "production is inside a deploy freeze window." "$(reason_for_code DEPLOY_FROZEN v2.14.3 production "raw")"

assert_eq "ARTIFACT_MISMATCH reason" \
  "The artifact being deployed does not match the SHA bound to the approval." "$(reason_for_code ARTIFACT_MISMATCH v2.14.3 production "raw")"

assert_eq "unknown code falls back to the API reason" \
  "Something custom." "$(reason_for_code SOMETHING_NEW v2.14.3 production "Something custom.")"

# --- render_result_block ---

SERVICE="ledger-api"
RELEASE="v2.14.3"
BRANCH=""
details_body='{"decision":"allow","details":{"artifactSha":"9f2a1c4e7b0d11223344556677889900aa83c17b","approval":{"status":"APPROVED","release":"v2.14.3","branch":null,"ticketRef":"CHG-4471","approverEmail":"maya.chen@acmepay.com","requesterEmail":"jordan.doe@acmepay.com","validUntil":"2026-10-08T14:38:00.000Z"},"sod":{"mode":"ENFORCING","satisfied":true,"requester":"jordan.doe","approver":"maya.chen"},"freeze":{"active":false,"windowReason":null,"overridden":false}}}'
block="$(render_result_block "$details_body" "fallbacksha")"
assert_contains "block: artifact line uses details sha" "$block" "  artifact   9f2a1c4e7b0d…a83c17b"
assert_contains "block: request line includes ticket" "$block" "  request    ledger-api v2.14.3 · CHG-4471"
assert_contains "block: approval line" "$block" "  approval   APPROVED by maya.chen@acmepay.com"
assert_contains "block: sod line" "$block" "  sod        satisfied · jordan.doe ≠ maya.chen"
assert_contains "block: window line" "$block" "  window     valid until 2026-10-08 14:38 UTC"
assert_contains "block: freeze line" "$block" "  freeze     none active"

block="$(render_result_block '{"decision":"block","reason":"x"}' "abc123def456")"
assert_contains "no details: artifact line falls back to GITHUB_SHA" "$block" "  artifact   abc123def456"
assert_contains "no details: request line" "$block" "  request    ledger-api v2.14.3"
assert_eq "no details: only two lines" "2" "$(printf '%s\n' "$block" | wc -l | tr -d ' ')"
SERVICE=""
RELEASE=""

# --- CLI validation (black-box subprocess; must fail before any API call) ---

run_check() {
  # Runs check.sh as a real subprocess with a clean env plus overrides.
  # Usage: run_check VAR=val VAR2=val2 -- --flag value ...
  local -a env_assignments=()
  while [[ "$1" != "--" ]]; do
    env_assignments+=("$1")
    shift
  done
  shift # drop the --
  env -i PATH="$PATH" ${env_assignments[@]+"${env_assignments[@]}"} bash "$CHECK_SH" "$@"
}

out="$(run_check -- 2>&1)"
code=$?
assert_eq "missing --service exits 1" "1" "$code"
assert_contains "missing --service message names the flag" "$out" "--service is required"

out="$(run_check GITHUB_REF=refs/heads/main -- --service foo --environment staging 2>&1)"
code=$?
assert_eq "branch-derived check without API key exits 1" "1" "$code"
assert_contains "branch-derived check resolves; next failure is the API key" "$out" "APPROVEGATE_API_KEY"

out="$(run_check GITHUB_REF=refs/tags/v9.9.9 -- --service foo --environment staging 2>&1)"
code=$?
assert_eq "tag trigger without --release still fails (no API key), not on release" "1" "$code"
assert_contains "tag-derived release resolves; next failure is the API key" "$out" "APPROVEGATE_API_KEY"

out="$(run_check -- --service foo --environment staging 2>&1)"
code=$?
assert_eq "missing lookup key exits 1" "1" "$code"
assert_contains "missing lookup key message names change-request-id" "$out" "--change-request-id"
assert_contains "missing lookup key message names GITHUB_SHA" "$out" "GITHUB_SHA"

out="$(run_check GITHUB_SHA=abc123 APPROVEGATE_API_KEY=dummy APPROVEGATE_API_URL=http://127.0.0.1:1 APPROVEGATE_TIMEOUT_SECONDS=1 APPROVEGATE_MAX_RETRIES=1 -- --service foo --environment staging 2>&1)"
code=$?
assert_eq "sha-only check resolves; next failure is network" "2" "$code"
assert_contains "sha-only check reaches API path" "$out" "Approvegate API request attempt"

out="$(run_check APPROVEGATE_API_KEY=dummy APPROVEGATE_API_URL=http://127.0.0.1:1 APPROVEGATE_TIMEOUT_SECONDS=1 APPROVEGATE_MAX_RETRIES=1 -- --service foo --change-request-id approval-123 --environment staging 2>&1)"
code=$?
assert_eq "change-request-id-only check resolves; next failure is network" "2" "$code"
assert_contains "change-request-id-only check reaches API path" "$out" "Approvegate API request attempt"

out="$(run_check GITHUB_REF=refs/heads/main -- --service foo --release v1.1.0 2>&1)"
code=$?
assert_eq "missing --environment exits 1" "1" "$code"
assert_contains "missing --environment message names the flag" "$out" "--environment"

out="$(run_check -- --bogus-flag 2>&1)"
code=$?
assert_eq "unknown flag exits 1" "1" "$code"
assert_contains "unknown flag message" "$out" "unknown argument"

out="$(run_check GITHUB_REF=refs/heads/main APPROVEGATE_API_KEY=dummy -- --service foo --environment staging --force-approve 2>&1)"
code=$?
assert_eq "force-approve without reason exits 1" "1" "$code"
assert_contains "force-approve without reason names reason" "$out" "--reason is required"

out="$(run_check GITHUB_REF=refs/heads/main APPROVEGATE_API_KEY=dummy -- --service foo --environment staging --on-unreachable maybe 2>&1)"
code=$?
assert_eq "invalid on-unreachable exits 1" "1" "$code"
assert_contains "invalid on-unreachable message" "$out" "--on-unreachable must be either"

echo
echo "unit tests: $pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]]
