#!/bin/bash

# Gene Test Suite Runner
# Compares output against # Expected: comments when present
# Otherwise just verifies the test runs without error

set -e  # Exit on error

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if gene executable exists
if [ ! -f "$SCRIPT_DIR/../bin/gene" ]; then
    echo -e "${RED}Error: gene executable not found at $SCRIPT_DIR/../bin/gene${NC}"
    echo "Please run 'nimble build' first."
    exit 1
fi

GENE="$SCRIPT_DIR/../bin/gene"
PASSED=0
FAILED=0
TOTAL=0

run_gene() {
    "$GENE" run --no-gir-cache "$@"
}

echo "================================"
echo "    Gene Test Suite Runner"
echo "================================"
echo

# Function to run a single test file
run_test() {
    local test_file=$1
    local test_name=$(basename "$test_file" .gene)
    local test_dir=$(dirname "$test_file")
    local test_basename=$(basename "$test_file")
    local extra_args=$(grep "^# Args:" "$test_file" | sed 's/^# Args: //' | tr '\n' ' ' || true)
    local expected_exit=$(grep "^# ExitCode:" "$test_file" | head -n 1 | sed 's/^# ExitCode: //' || true)
    if [ -z "$expected_exit" ]; then
        expected_exit=0
    fi

    TOTAL=$((TOTAL + 1))

    # Check if test has expected output
    if grep -q "^# Expected:" "$test_file"; then
        # Extract all expected output lines (skip empty Expected: lines)
        local expected_output=$(grep "^# Expected:" "$test_file" | sed 's/^# Expected: //' | grep -v '^$' || true)

        if [ -z "$expected_output" ]; then
            # Empty expected output - just check if it runs
            set +e
            (cd "$test_dir" && run_gene $extra_args "$test_basename") > /dev/null 2>&1
            local exit_code=$?
            set -e
            if [ "$exit_code" -eq "$expected_exit" ]; then
                printf "  %-40s ${GREEN}✓ PASS${NC}\n" "$test_name"
                PASSED=$((PASSED + 1))
            else
                printf "  %-40s ${RED}✗ FAIL${NC}\n" "$test_name"
                echo "    Expected exit code: $expected_exit, actual: $exit_code"
                FAILED=$((FAILED + 1))
            fi
        else
            # Run test and capture output
            set +e
            actual_output=$(cd "$test_dir" && run_gene $extra_args "$test_basename" 2>&1)
            local exit_code=$?
            set -e
            # Filter out empty lines and compile-time type warnings from actual output
            # (compile warnings contain "Type error:", runtime warnings like "Lossy conversion" are kept)
            actual_output=$(echo "$actual_output" | grep -v '^$' | grep -v 'Warning:.*Type error:' || true)

            # Normalize outputs (remove trailing spaces)
            echo "$expected_output" | sed 's/[[:space:]]*$//' > /tmp/expected_$$.txt
            echo "$actual_output" | sed 's/[[:space:]]*$//' > /tmp/actual_$$.txt

            # Compare outputs and exit code
            if [ "$exit_code" -eq "$expected_exit" ] && diff -B -w /tmp/expected_$$.txt /tmp/actual_$$.txt > /dev/null 2>&1; then
                printf "  %-40s ${GREEN}✓ PASS${NC}\n" "$test_name"
                PASSED=$((PASSED + 1))
            else
                printf "  %-40s ${RED}✗ FAIL${NC}\n" "$test_name"
                echo "    Expected exit code: $expected_exit, actual: $exit_code"
                echo "    Expected:"
                echo "$expected_output" | sed 's/^/      /'
                echo "    Actual:"
                echo "$actual_output" | head -5 | sed 's/^/      /'
                FAILED=$((FAILED + 1))
            fi

            # Clean up temp files
            rm -f /tmp/expected_$$.txt /tmp/actual_$$.txt
        fi
    else
        # No expected output - just check if it runs without error
        set +e
        (cd "$test_dir" && run_gene $extra_args "$test_basename") > /dev/null 2>&1
        local exit_code=$?
        set -e
        if [ "$exit_code" -eq "$expected_exit" ]; then
            printf "  %-40s ${GREEN}✓ PASS${NC}\n" "$test_name"
            PASSED=$((PASSED + 1))
        else
            printf "  %-40s ${RED}✗ FAIL${NC}\n" "$test_name"
            echo "    Expected exit code: $expected_exit, actual: $exit_code"
            error_output=$(cd "$test_dir" && run_gene $extra_args "$test_basename" 2>&1 || true)
            echo "    Error output:"
            echo "$error_output" | head -5 | sed 's/^/      /'
            FAILED=$((FAILED + 1))
        fi
    fi
}

# Function to run tests in a directory
run_category() {
    local category=$1
    local dir=$2
    
    if [ -d "$dir" ]; then
        echo -e "${BLUE}Testing $category:${NC}"
        
        # Run numbered tests in order
        for i in 1 2 3 4 5 6 7 8 9; do
            for test_file in "$dir"/${i}_*.gene; do
                if [ -f "$test_file" ]; then
                    run_test "$test_file"
                fi
            done
        done
        
        echo
    fi
}

# Change to testsuite directory
cd "$SCRIPT_DIR"

if [ $# -gt 0 ]; then
    echo -e "${BLUE}Running selected tests:${NC}"
    for test_arg in "$@"; do
        # Allow paths relative to testsuite dir
        if [ -f "$test_arg" ]; then
            run_test "$test_arg"
        elif [ -f "$SCRIPT_DIR/$test_arg" ]; then
            run_test "$SCRIPT_DIR/$test_arg"
        else
            printf "  %-40s ${RED}✗ MISSING${NC}\n" "$test_arg"
            FAILED=$((FAILED + 1))
            TOTAL=$((TOTAL + 1))
        fi
    done
    echo
else
    # Run tests in specific order
    run_category "Basic Literals & Variables" "basics"
    run_category "Control Flow" "control_flow"
    run_category "Operators" "operators"
    run_category "Arrays" "arrays"
    run_category "Maps" "maps"
    run_category "Strings" "strings"
    run_category "Functions" "functions"
    run_category "Contracts" "contracts"
    run_category "Types" "types"
    run_category "Scopes" "scopes"
    run_category "Callable Instances" "callable_instances"
    run_category "OOP" "oop"
    run_category "Async Support" "async"
    run_category "Futures" "futures"
    run_category "Generators" "generators"
    run_category "Imports" "imports"
    run_category "Stdlib" "stdlib"
    run_category "Stdlib Core" "stdlib/core"
    run_category "Stdlib Strings" "stdlib/strings"
    run_category "Stdlib Arrays" "stdlib/arrays"
    run_category "AI Documents" "ai/documents"
    run_category "Stdlib IO" "stdlib/io"
    # run_category "Stdlib Time" "stdlib/time"

    # Run pipe command tests (uses its own test script)
    if [ -f "$SCRIPT_DIR/pipe/run_tests.sh" ]; then
        echo -e "${BLUE}Testing Pipe Command:${NC}"
        if "$SCRIPT_DIR/pipe/run_tests.sh" > /dev/null 2>&1; then
            printf "  %-40s ${GREEN}✓ PASS${NC}\n" "pipe command suite"
            PASSED=$((PASSED + 1))
        else
            printf "  %-40s ${RED}✗ FAIL${NC}\n" "pipe command suite"
            echo "    Run 'testsuite/pipe/run_tests.sh' for details"
            FAILED=$((FAILED + 1))
        fi
        TOTAL=$((TOTAL + 1))
        echo
    fi
fi

# Summary
echo "================================"
echo "        Test Summary"
echo "================================"
echo
printf "  Total Tests:  %3d\n" "$TOTAL"
printf "  ${GREEN}Passed:       %3d${NC}\n" "$PASSED"
printf "  ${RED}Failed:       %3d${NC}\n" "$FAILED"

if [ $FAILED -eq 0 ]; then
    echo
    echo -e "${GREEN}✓ All tests passed successfully!${NC}"
    exit 0
else
    PASS_RATE=$((PASSED * 100 / TOTAL))
    echo
    echo -e "${YELLOW}⚠ Pass rate: ${PASS_RATE}%${NC}"
    exit 1
fi
