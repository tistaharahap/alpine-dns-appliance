# shellcheck shell=sh
# Assertion primitives for the alpine-dns-stick test suite.
# Sourced, never executed. POSIX sh only.

ADS_TESTS_RUN=0
ADS_TESTS_FAILED=0

_ads_pass() {
    ADS_TESTS_RUN=$((ADS_TESTS_RUN + 1))
    printf '  ok   %s\n' "$1"
}

_ads_fail() {
    ADS_TESTS_RUN=$((ADS_TESTS_RUN + 1))
    ADS_TESTS_FAILED=$((ADS_TESTS_FAILED + 1))
    printf '  FAIL %s\n' "$1"
    shift
    for _detail in "$@"; do
        printf '       %s\n' "$_detail"
    done
}

assert_eq() {
    if [ "$1" = "$2" ]; then
        _ads_pass "$3"
    else
        _ads_fail "$3" "expected: [$1]" "actual:   [$2]"
    fi
}

assert_rc() {
    if [ "$1" -eq "$2" ]; then
        _ads_pass "$3"
    else
        _ads_fail "$3" "expected rc: $1" "actual rc:   $2"
    fi
}

assert_contains() {
    case "$1" in
        *"$2"*) _ads_pass "$3" ;;
        *) _ads_fail "$3" "haystack: [$1]" "should contain: [$2]" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) _ads_fail "$3" "haystack: [$1]" "should NOT contain: [$2]" ;;
        *) _ads_pass "$3" ;;
    esac
}

test_summary() {
    printf '  -- %s: %d assertions, %d failed\n' \
        "$1" "$ADS_TESTS_RUN" "$ADS_TESTS_FAILED"
    [ "$ADS_TESTS_FAILED" -eq 0 ]
}
