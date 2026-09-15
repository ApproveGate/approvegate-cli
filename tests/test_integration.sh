#!/usr/bin/env bash
# End-to-end tests for check.sh against tests/mock_server.py.
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SH="$SCRIPT_DIR/../check.sh"
MOCK_SERVER="$SCRIPT_DIR/mock_server.py"

pass_count=0
fail_count=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo "FAIL: $desc (expected [$expected], got [$actual])"
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

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo "FAIL: $desc — found forbidden string [$needle] in output"
  fi
}

DUMMY_KEY="test-dummy-api-key-should-never-appear-in-output"

# --- start the mock server on an OS-assigned port ---
SERVER_LOG="$(mktemp)"
REQUEST_LOG_FILE="$(mktemp)"
export REQUEST_LOG_FILE
python3 "$MOCK_SERVER" 0 >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  rm -f "$SERVER_LOG" "${REQUEST_LOG_FILE:-}" "${GITHUB_OUTPUT_FILE:-}" "${GITHUB_STEP_SUMMARY_FILE:-}" approvegate-unverified-deploy.json
}
trap cleanup EXIT

# Wait for the server to print its bound port.
PORT=""
for _ in $(seq 1 50); do
  PORT="$(head -n1 "$SERVER_LOG" 2>/dev/null || true)"
  [[ -n "$PORT" ]] && break
  sleep 0.1
done
if [[ -z "$PORT" ]]; then
  echo "FAIL: mock server never started"
  exit 1
fi

run_check() {
  # Usage: run_check <mode-path> [extra check.sh args...]
  local mode="$1"; shift
  APPROVEGATE_API_URL="http://127.0.0.1:${PORT}/mode/${mode}" \
  APPROVEGATE_API_KEY="$DUMMY_KEY" \
  APPROVEGATE_RETRY_DELAY_SECONDS=0 \
  APPROVEGATE_TIMEOUT_SECONDS=1 \
  GITHUB_SHA="abc123def456" \
  GITHUB_TOKEN="dummy-github-token" \
  GITHUB_API_URL="http://127.0.0.1:${PORT}" \
  GITHUB_SERVER_URL="https://github.com" \
  GITHUB_REPOSITORY="acme/ledger" \
  GITHUB_WORKFLOW="Deploy production" \
  GITHUB_JOB="deploy" \
  GITHUB_RUN_ID="1" \
  GITHUB_RUN_ATTEMPT="2" \
  GITHUB_ACTOR="mchen" \
  GITHUB_ACTOR_ID="12345" \
  GITHUB_TRIGGERING_ACTOR="incident-lead" \
  bash "$CHECK_SH" --service test-svc --release v1.0.0 --branch main --environment staging "$@" 2>&1
}

# --- allow ---
>"$REQUEST_LOG_FILE"
out="$(run_check allow)"; code=$?
assert_eq "allow: exit code" "0" "$code"
assert_contains "allow: prints configuration header" "$out" "Approvegate check configuration:"
assert_contains "allow: prints full checks endpoint path" "$out" "checksEndpoint: http://127.0.0.1:${PORT}/mode/allow"
assert_contains "allow: prints service" "$out" "service: test-svc"
assert_contains "allow: prints release" "$out" "release: v1.0.0"
assert_contains "allow: prints branch" "$out" "branch: main"
assert_contains "allow: prints environment" "$out" "environment: staging"
assert_contains "allow: prints short artifact sha" "$out" "artifactSha: abc123def456"
assert_contains "allow: prints HTTP status" "$out" "Approvegate API returned HTTP 200."
assert_contains "allow: prints decision" "$out" "Approvegate decision: allow"
assert_contains "allow: prints release request URL" "$out" "Approvegate release request: http://localhost:3000/app/acme-corp-1/release-requests/approval-123"
assert_contains "allow: confirmation message" "$out" "allowed"
assert_not_contains "allow: API key not leaked" "$out" "$DUMMY_KEY"
logged_body="$(tail -n1 "$REQUEST_LOG_FILE")"
assert_contains "allow: request included GitHub actor" "$logged_body" '"login":"mchen"'
assert_contains "allow: request included triggering actor" "$logged_body" '"triggeringLogin":"incident-lead"'
assert_contains "allow: request included GitHub run URL" "$logged_body" '"runUrl":"https://github.com/acme/ledger/actions/runs/1"'
assert_contains "allow: request included pipeline status" "$logged_body" '"name":"unit-tests"'
assert_contains "allow: request omitted in-progress deploy job status" "$logged_body" '"security-scan"'

# --- block ---
out="$(run_check block)"; code=$?
assert_eq "block: exit code" "1" "$code"
assert_contains "block: prints decision" "$out" "Approvegate decision: block"
assert_contains "block: prints exact API reason" "$out" "No deploy authorization recorded for release."
assert_not_contains "block: API key not leaked" "$out" "$DUMMY_KEY"

# --- server error (5xx) treated as unreachable, with retries ---
out="$(run_check servererror)"; code=$?
assert_eq "servererror: exit code" "2" "$code"
assert_contains "servererror: distinct unreachable message" "$out" "Approvegate API unreachable"
assert_contains "servererror: mentions retry attempts" "$out" "attempt"

GITHUB_OUTPUT_FILE="$(mktemp)"
GITHUB_STEP_SUMMARY_FILE="$(mktemp)"
rm -f approvegate-unverified-deploy.json
out="$(GITHUB_OUTPUT="$GITHUB_OUTPUT_FILE" GITHUB_STEP_SUMMARY="$GITHUB_STEP_SUMMARY_FILE" run_check servererror --on-unreachable allow)"; code=$?
assert_eq "servererror with on-unreachable allow: exit code" "0" "$code"
assert_contains "servererror with on-unreachable allow: output explains unverified deploy" "$out" "allowed without verification"
assert_contains "servererror with on-unreachable allow: writes decision output" "$(cat "$GITHUB_OUTPUT_FILE")" "decision=allow"
assert_contains "servererror with on-unreachable allow: writes unverified output" "$(cat "$GITHUB_OUTPUT_FILE")" "unverified=true"
assert_contains "servererror with on-unreachable allow: writes summary" "$(cat "$GITHUB_STEP_SUMMARY_FILE")" "Deploy proceeded without ApproveGate verification"
assert_contains "servererror with on-unreachable allow: writes evidence file" "$(cat approvegate-unverified-deploy.json)" '"service": "test-svc"'

# --- malformed response body: rejected, not a silent allow ---
out="$(run_check malformed)"; code=$?
assert_eq "malformed: exit code" "1" "$code"
assert_contains "malformed: distinct rejection message" "$out" "rejected the request"

# --- timeout treated as unreachable, with retries ---
out="$(run_check hang)"; code=$?
assert_eq "hang/timeout: exit code" "2" "$code"
assert_contains "hang/timeout: distinct unreachable message" "$out" "Approvegate API unreachable"

# --- connection refused (nothing listening) ---
FREE_PORT=$((PORT + 1))
out="$(APPROVEGATE_API_URL="http://127.0.0.1:${FREE_PORT}/mode/allow" \
  APPROVEGATE_API_KEY="$DUMMY_KEY" \
  APPROVEGATE_RETRY_DELAY_SECONDS=0 \
  APPROVEGATE_TIMEOUT_SECONDS=1 \
  GITHUB_SHA="abc123def456" \
  bash "$CHECK_SH" --service test-svc --release v1.0.0 --environment staging 2>&1)"
code=$?
assert_eq "connection refused: exit code" "2" "$code"
assert_contains "connection refused: distinct unreachable message" "$out" "Approvegate API unreachable"
assert_not_contains "connection refused: API key not leaked" "$out" "$DUMMY_KEY"

# --- force-approve: always allow, and the request body actually carries the fields ---
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
python3 "$MOCK_SERVER" "$PORT" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
sleep 0.3

out="$(run_check force --force-approve --reason "emergency rollback fix")"; code=$?
assert_eq "force-approve: exit code always 0" "0" "$code"
assert_contains "force-approve: confirmation message" "$out" "allowed"

logged_body="$(tail -n1 "$REQUEST_LOG_FILE")"
assert_contains "force-approve: request included forceApprove:true" "$logged_body" '"forceApprove":true'
assert_contains "force-approve: request included branch" "$logged_body" '"branch":"main"'
assert_contains "force-approve: request included the reason" "$logged_body" "emergency rollback fix"

# If a release is explicitly supplied on a branch-triggered run, the CLI must not
# silently add branch too. That would require an approval matching both fields.
>"$REQUEST_LOG_FILE"
out="$(APPROVEGATE_API_URL="http://127.0.0.1:${PORT}/mode/allow" \
  APPROVEGATE_API_KEY="$DUMMY_KEY" \
  APPROVEGATE_RETRY_DELAY_SECONDS=0 \
  APPROVEGATE_TIMEOUT_SECONDS=1 \
  GITHUB_REF="refs/heads/main" \
  GITHUB_SHA="abc123def456" \
  bash "$CHECK_SH" --service test-svc --release main --environment staging 2>&1)"
code=$?
assert_eq "explicit release on branch ref: exit code" "0" "$code"
assert_contains "explicit release on branch ref: log shows no branch" "$out" "branch: (none)"
logged_body="$(tail -n1 "$REQUEST_LOG_FILE")"
assert_contains "explicit release on branch ref: request includes release" "$logged_body" '"release":"main"'
assert_not_contains "explicit release on branch ref: request omits branch" "$logged_body" '"branch"'

# Without force-approve, the same mode blocks (proves the mock isn't just always allowing).
out="$(run_check force)"; code=$?
assert_eq "force mode without --force-approve blocks" "1" "$code"

# --- change-request-id: takes precedence as the lookup key and is sent verbatim ---
>"$REQUEST_LOG_FILE"
out="$(APPROVEGATE_API_URL="http://127.0.0.1:${PORT}/mode/allow" \
  APPROVEGATE_API_KEY="$DUMMY_KEY" \
  APPROVEGATE_RETRY_DELAY_SECONDS=0 \
  APPROVEGATE_TIMEOUT_SECONDS=1 \
  GITHUB_SHA="abc123def456" \
  bash "$CHECK_SH" --service test-svc --change-request-id approval-123 --environment staging 2>&1)"
code=$?
assert_eq "change-request-id: exit code" "0" "$code"
assert_contains "change-request-id: prints changeRequestId" "$out" "changeRequestId: approval-123"
logged_body="$(tail -n1 "$REQUEST_LOG_FILE")"
assert_contains "change-request-id: request includes changeRequestId" "$logged_body" '"changeRequestId":"approval-123"'

# --- SHA-only check: no --release/--branch/--change-request-id, GITHUB_SHA carries the check ---
>"$REQUEST_LOG_FILE"
out="$(APPROVEGATE_API_URL="http://127.0.0.1:${PORT}/mode/allow" \
  APPROVEGATE_API_KEY="$DUMMY_KEY" \
  APPROVEGATE_RETRY_DELAY_SECONDS=0 \
  APPROVEGATE_TIMEOUT_SECONDS=1 \
  GITHUB_SHA="abc123def456" \
  bash "$CHECK_SH" --service test-svc --environment staging 2>&1)"
code=$?
assert_eq "sha-only: exit code" "0" "$code"
assert_contains "sha-only: log shows no release or branch" "$out" "release: (none)"
logged_body="$(tail -n1 "$REQUEST_LOG_FILE")"
assert_contains "sha-only: request includes artifactSha" "$logged_body" '"artifactSha":"abc123def456"'
assert_not_contains "sha-only: request omits release" "$logged_body" '"release"'
assert_not_contains "sha-only: request omits branch" "$logged_body" '"branch"'

echo
echo "integration tests: $pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]]
