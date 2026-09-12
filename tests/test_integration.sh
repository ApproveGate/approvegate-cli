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
python3 "$MOCK_SERVER" 0 >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  rm -f "$SERVER_LOG" "${REQUEST_LOG_FILE:-}"
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
  bash "$CHECK_SH" --service test-svc --release v1.0.0 --branch main --environment staging "$@" 2>&1
}

# --- allow ---
out="$(run_check allow)"; code=$?
assert_eq "allow: exit code" "0" "$code"
assert_contains "allow: prints configuration header" "$out" "Approvegate check configuration:"
assert_contains "allow: prints service" "$out" "service: test-svc"
assert_contains "allow: prints release" "$out" "release: v1.0.0"
assert_contains "allow: prints branch" "$out" "branch: main"
assert_contains "allow: prints environment" "$out" "environment: staging"
assert_contains "allow: prints short artifact sha" "$out" "artifactSha: abc123def456"
assert_contains "allow: prints HTTP status" "$out" "Approvegate API returned HTTP 200."
assert_contains "allow: prints decision" "$out" "Approvegate decision: allow"
assert_contains "allow: confirmation message" "$out" "allowed"
assert_not_contains "allow: API key not leaked" "$out" "$DUMMY_KEY"

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

# --- malformed response body: rejected, not a silent allow ---
out="$(run_check malformed)"; code=$?
assert_eq "malformed: exit code" "1" "$code"
assert_contains "malformed: distinct rejection message" "$out" "rejected the request"

# --- timeout treated as unreachable, with retries ---
out="$(run_check hang)"; code=$?
assert_eq "hang/timeout: exit code" "2" "$code"
assert_contains "hang/timeout: distinct unreachable message" "$out" "Approvegate API unreachable"

# --- connection refused (nothing listening) ---
FREE_PORT="$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()")"
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
REQUEST_LOG_FILE="$(mktemp)"
export REQUEST_LOG_FILE
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

echo
echo "integration tests: $pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]]
