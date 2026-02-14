#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENE="$SCRIPT_DIR/../../bin/gene"

if [ ! -f "$GENE" ]; then
  echo "Error: gene executable not found at $GENE"
  exit 1
fi

PASSED=0
FAILED=0

run_case() {
  local input_file=$1
  local expected_file=$2
  local case_name
  case_name=$(basename "$input_file" .input.gene)

  local tmp_file
  tmp_file=$(mktemp)
  cp "$input_file" "$tmp_file"

  if ! "$GENE" fmt "$tmp_file" >/dev/null 2>&1; then
    echo "FAIL: $case_name (formatter command failed)"
    rm -f "$tmp_file"
    FAILED=$((FAILED + 1))
    return
  fi

  if diff -u "$expected_file" "$tmp_file" >/dev/null 2>&1; then
    echo "PASS: $case_name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $case_name (formatted output mismatch)"
    diff -u "$expected_file" "$tmp_file" || true
    FAILED=$((FAILED + 1))
  fi

  rm -f "$tmp_file"
}

for input_file in "$SCRIPT_DIR"/*.input.gene; do
  expected_file="${input_file%.input.gene}.expected.gene"
  if [ ! -f "$expected_file" ]; then
    echo "FAIL: missing expected fixture for $(basename "$input_file")"
    FAILED=$((FAILED + 1))
    continue
  fi
  run_case "$input_file" "$expected_file"
done

# --check should succeed for canonical file
set +e
"$GENE" fmt --check "$SCRIPT_DIR/001_already_canonical.expected.gene" >/dev/null 2>&1
check_canonical_exit=$?
set -e
if [ "$check_canonical_exit" -eq 0 ]; then
  echo "PASS: check mode accepts canonical"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: check mode rejects canonical"
  FAILED=$((FAILED + 1))
fi

# --check should fail for non-canonical file and must not modify file
check_tmp=$(mktemp)
cp "$SCRIPT_DIR/002_unsorted_props.input.gene" "$check_tmp"
orig_tmp=$(mktemp)
cp "$check_tmp" "$orig_tmp"
set +e
"$GENE" fmt --check "$check_tmp" >/dev/null 2>&1
check_noncanonical_exit=$?
set -e
if [ "$check_noncanonical_exit" -ne 0 ] && diff -u "$orig_tmp" "$check_tmp" >/dev/null 2>&1; then
  echo "PASS: check mode rejects non-canonical without changes"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: check mode behavior for non-canonical input"
  FAILED=$((FAILED + 1))
fi
rm -f "$check_tmp" "$orig_tmp"

TOTAL=$((PASSED + FAILED))
echo "Formatter tests: $PASSED/$TOTAL passed"

if [ "$FAILED" -eq 0 ]; then
  exit 0
fi

exit 1
