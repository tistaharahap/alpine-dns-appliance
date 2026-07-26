#!/bin/sh
# Verifies the assertion primitives themselves.
set -u
. "$(dirname "$0")/assert.sh"

assert_eq "abc" "abc" "assert_eq matches equal strings"
assert_rc 0 0 "assert_rc matches equal codes"
assert_contains "hello world" "lo wo" "assert_contains finds a substring"
assert_not_contains "hello world" "banana" "assert_not_contains rejects an absent substring"

# A failing assertion must actually be counted as a failure - otherwise every
# later test file could be silently reporting success. Run it in a subshell so
# this file's own counters are untouched.
if (
    assert_eq "a" "b" "intentional failure" >/dev/null 2>&1
    [ "$ADS_TESTS_FAILED" -eq 1 ] && [ "$ADS_TESTS_RUN" -eq 5 ]
); then
    _ads_pass "a failing assert_eq increments ADS_TESTS_FAILED"
else
    _ads_fail "a failing assert_eq does not increment ADS_TESTS_FAILED"
fi

test_summary "test_harness"
