#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# run_all_tests.sh - Run all util-unix test scripts and summarize results
#
# Exits 1 if any suite failed. A suite fails if it prints a FAIL line, exits
# non-zero (a crash, a FATAL refusal, a syntax error) or reports no result at
# all, so a suite that stops early cannot pass by printing less.
# a memory-limited scope of its own, so a runaway case cannot take the caller down
[ "${TEST_CONTAINED:-}" = "cg:$(cat /proc/self/cgroup 2>/dev/null)" ] || exec sh "$(dirname "$0")/contain.sh" sh "$0" "$@"

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

    # tee keeps the output visible; the suite's own status goes to a file
    # because a pipeline only reports the status of its last command
    temp_output=$(mktemp)
    status_file=$(mktemp)
    { sh "$script" 2>&1; echo $? > "$status_file"; } | tee "$temp_output"
    status=$(cat "$status_file")

    # Count occurrences, defaulting to 0 if grep finds nothing
    pass=$(grep -c "^PASS" "$temp_output" 2>/dev/null) || pass=0
    fail=$(grep -c "^FAIL" "$temp_output" 2>/dev/null) || fail=0
    skip=$(grep -c "^SKIP" "$temp_output" 2>/dev/null) || skip=0

    rm -f "$temp_output" "$status_file"

    TOTAL_PASS=$((TOTAL_PASS + pass))
    TOTAL_FAIL=$((TOTAL_FAIL + fail))
    TOTAL_SKIP=$((TOTAL_SKIP + skip))

    reason=""
    if [ "$status" != 0 ]; then
        reason="exit status ${status:-unknown}"
    elif [ "$fail" -gt 0 ]; then
        reason="$fail failed"
    elif [ $((pass + skip)) -eq 0 ]; then
        reason="no results"
    fi
    if [ -n "$reason" ]; then
        printf "SUITE FAILED: %s (%s)\n" "$util" "$reason"
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
    printf "######################################\n"
    exit 1
fi
printf "\n All utils passed!\n"
printf "######################################\n"
