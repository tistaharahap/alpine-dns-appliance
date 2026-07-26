#!/bin/sh
# Runs every test file, then shellcheck when it is available.
set -u
cd "$(dirname "$0")/.." || exit 1

_fail=0

for _t in tests/test_*.sh; do
    printf '\n== %s ==\n' "$_t"
    sh "$_t" || _fail=1
done

printf '\n== shellcheck ==\n'
if command -v shellcheck >/dev/null 2>&1; then
    for _f in build-usb.sh; do
        [ -f "$_f" ] && { shellcheck -s bash "$_f" || _fail=1; }
    done
    for _f in provision.sh alpine/dns-ip.initd alpine/technitium.initd tests/*.sh; do
        [ -f "$_f" ] && { shellcheck -s sh "$_f" || _fail=1; }
    done
    [ "$_fail" -eq 0 ] && printf 'clean\n'
else
    printf 'SKIPPED - shellcheck not installed (brew install shellcheck)\n'
fi

printf '\n'
if [ "$_fail" -eq 0 ]; then
    printf 'ALL TESTS PASSED\n'
else
    printf 'TESTS FAILED\n'
fi
exit "$_fail"
