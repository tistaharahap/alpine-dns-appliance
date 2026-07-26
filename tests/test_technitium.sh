#!/bin/sh
# Exercises the pure logic in alpine/technitium.initd.
set -u
. "$(dirname "$0")/assert.sh"

einfo() { :; }
ewarn() { :; }
eerror() { :; }

_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

# Point the run file at a temp path before sourcing.
DNS_IP_RUNFILE="$_tmp/dns-ip"
export DNS_IP_RUNFILE

. "$(dirname "$0")/../alpine/technitium.initd"

# --- technitium_endpoints ---------------------------------------------------
assert_eq "192.168.1.53:53,127.0.0.1:53" "$(technitium_endpoints 192.168.1.53)" \
    "endpoints pair the claimed address with loopback"
assert_eq "10.0.0.59:53,127.0.0.1:53" "$(technitium_endpoints 10.0.0.59)" \
    "endpoints work for any claimed address"
technitium_endpoints "" >/dev/null 2>&1
assert_rc 1 $? "technitium_endpoints rejects an empty address"

# --- claimed_ip -------------------------------------------------------------
claimed_ip >/dev/null 2>&1
assert_rc 1 $? "claimed_ip fails when the run file is absent"

: > "$DNS_IP_RUNFILE"
claimed_ip >/dev/null 2>&1
assert_rc 1 $? "claimed_ip fails when the run file is empty"

echo "192.168.1.54" > "$DNS_IP_RUNFILE"
assert_eq "192.168.1.54" "$(claimed_ip)" "claimed_ip reads the run file"

printf ' ' > "$DNS_IP_RUNFILE"
claimed_ip >/dev/null 2>&1
assert_rc 1 $? "claimed_ip rejects a whitespace-only run file"

printf '192.168.1.54 \n' > "$DNS_IP_RUNFILE"
claimed_ip >/dev/null 2>&1
assert_rc 1 $? "claimed_ip rejects an address with trailing whitespace"

printf '192.168.1.54\nextra\n' > "$DNS_IP_RUNFILE"
claimed_ip >/dev/null 2>&1
assert_rc 1 $? "claimed_ip rejects a multi-line run file"

printf '192.168.1.999\n' > "$DNS_IP_RUNFILE"
claimed_ip >/dev/null 2>&1
assert_rc 1 $? "claimed_ip rejects an out-of-range octet"

printf '10.0.0.59\n' > "$DNS_IP_RUNFILE"
assert_eq "10.0.0.59" "$(claimed_ip)" "claimed_ip still accepts a valid address"

# --- interlock and layout ---------------------------------------------------
_src=$(cat "$(dirname "$0")/../alpine/technitium.initd")
assert_contains "$_src" "need dns-ip" \
    "declares the need dns-ip interlock so DNS never starts without an address"
assert_eq "/opt/technitium" "$TECHNITIUM_DIR" "installs under /opt/technitium"
assert_contains "$TECHNITIUM_API" "127.0.0.1:5380" "API base points at loopback:5380"

test_summary "test_technitium"
