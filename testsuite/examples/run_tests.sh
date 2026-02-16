#!/bin/bash

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENE="$SCRIPT_DIR/../../bin/gene"

if [ ! -f "$GENE" ]; then
  echo -e "${RED}Error: gene executable not found at $GENE${NC}"
  echo "Please run 'nimble build' first."
  exit 1
fi

PASSED=0
FAILED=0
TOTAL=0

pass() {
  printf "  %-44s ${GREEN}✓ PASS${NC}\n" "$1"
  PASSED=$((PASSED + 1))
  TOTAL=$((TOTAL + 1))
}

fail() {
  printf "  %-44s ${RED}✗ FAIL${NC}\n" "$1"
  if [ -n "${2:-}" ]; then
    echo "    $2"
  fi
  FAILED=$((FAILED + 1))
  TOTAL=$((TOTAL + 1))
}

echo -e "${BLUE}Testing gene run-examples:${NC}"

# 1) Happy path: exact match, wildcard return, and throws checks pass.
set +e
PASS_OUTPUT=$("$GENE" run-examples "$SCRIPT_DIR/cases/pass_examples.gene" 2>&1)
PASS_EXIT=$?
set -e
if [ "$PASS_EXIT" -eq 0 ] \
  && echo "$PASS_OUTPUT" | grep -q "PASS add example 1" \
  && echo "$PASS_OUTPUT" | grep -q "PASS add example 2" \
  && echo "$PASS_OUTPUT" | grep -q "PASS positive_only example 1" \
  && echo "$PASS_OUTPUT" | grep -q "PASS positive_only example 2" \
  && echo "$PASS_OUTPUT" | grep -q "Examples run: 4, passed: 4, failed: 0, functions: 2"; then
  pass "run-examples happy path"
else
  fail "run-examples happy path" "Unexpected output or exit code"
fi

# 2) Mismatch should fail with detailed output and non-zero exit.
set +e
FAIL_OUTPUT=$("$GENE" run-examples "$SCRIPT_DIR/cases/fail_examples.gene" 2>&1)
FAIL_EXIT=$?
set -e
if [ "$FAIL_EXIT" -ne 0 ] \
  && echo "$FAIL_OUTPUT" | grep -q "FAIL add example 1" \
  && echo "$FAIL_OUTPUT" | grep -q "expected: return 4" \
  && echo "$FAIL_OUTPUT" | grep -q "actual: return 3" \
  && echo "$FAIL_OUTPUT" | grep -q "location:"; then
  pass "run-examples mismatch reporting"
else
  fail "run-examples mismatch reporting" "Expected failure details were missing"
fi

# 3) Invalid ^examples syntax should fail fast.
set +e
INVALID_OUTPUT=$("$GENE" run-examples "$SCRIPT_DIR/cases/invalid_examples.gene" 2>&1)
INVALID_EXIT=$?
set -e
if [ "$INVALID_EXIT" -ne 0 ] && echo "$INVALID_OUTPUT" | grep -q "Invalid ^examples"; then
  pass "invalid ^examples syntax handling"
else
  fail "invalid ^examples syntax handling" "Expected invalid syntax error"
fi

echo
printf "  Total:  %3d\n" "$TOTAL"
printf "  Passed: %3d\n" "$PASSED"
printf "  Failed: %3d\n" "$FAILED"

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi

exit 0
