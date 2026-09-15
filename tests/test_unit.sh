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
assert_eq "missing --release and --branch exits 1" "1" "$code"
assert_contains "missing release and branch message names both" "$out" "--release or --branch"

out="$(run_check GITHUB_REF=refs/heads/main -- --service foo --release v1.0.0 2>&1)"
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
