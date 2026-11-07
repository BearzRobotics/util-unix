#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# run_all_tests.sh - Run all util-unix test scripts and summarize results

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
FAILED_UTILS=""

run_suite() {
    script="$1"
    util=$(basename "$script" | sed 's/test_//;s/\.sh//')

    printf "\n######################################\n"
    printf " Testing: %s\n" "$util"
    printf "######################################\n"

    # Run script directly to preserve terminal for colors
    # Capture counts by parsing output on the fly
    temp_output=$(mktemp)
    sh "$script" 2>&1 | tee "$temp_output"

    # Count occurrences, defaulting to 0 if grep finds nothing
    pass=$(grep -c "^PASS" "$temp_output" 2>/dev/null) || pass=0
    fail=$(grep -c "^FAIL" "$temp_output" 2>/dev/null) || fail=0
    skip=$(grep -c "^SKIP" "$temp_output" 2>/dev/null) || skip=0

    rm -f "$temp_output"

    TOTAL_PASS=$((TOTAL_PASS + pass))
    TOTAL_FAIL=$((TOTAL_FAIL + fail))
    TOTAL_SKIP=$((TOTAL_SKIP + skip))

    if [ "$fail" -gt 0 ]; then
        FAILED_UTILS="$FAILED_UTILS $util"
    fi
}

# Run all test scripts
for script in "$TESTS_DIR"/test_*.sh; do
    run_suite "$script"
done

# Final summary
TOTAL=$((TOTAL_PASS + TOTAL_FAIL + TOTAL_SKIP))
printf "\n\n######################################\n"
printf " FINAL RESULTS\n"
printf "######################################\n"
printf " Passed : %d\n" "$TOTAL_PASS"
printf " Failed : %d\n" "$TOTAL_FAIL"
printf " Skipped: %d\n" "$TOTAL_SKIP"
printf " Total  : %d\n" "$TOTAL"

if [ -n "$FAILED_UTILS" ]; then
    printf "\n Failed utils:%s\n" "$FAILED_UTILS"
else
    printf "\n All utils passed!\n"
fi
printf "######################################\n"