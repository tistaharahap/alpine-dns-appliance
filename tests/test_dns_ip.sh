#!/bin/sh
# Exercises the pure logic in alpine/dns-ip.initd.
# OpenRC helpers are stubbed so the file can be sourced on macOS.
set -u
. "$(dirname "$0")/assert.sh"

# OpenRC provides these; stub them out as no-ops.
einfo() { :; }
ewarn() { :; }
eerror() { :; }
checkpath() { :; }

. "$(dirname "$0")/../alpine/dns-ip.initd"

# --- mask_to_prefix ---------------------------------------------------------
assert_eq "24" "$(mask_to_prefix 255.255.255.0)"   "mask_to_prefix /24"
assert_eq "16" "$(mask_to_prefix 255.255.0.0)"     "mask_to_prefix /16"
assert_eq "8"  "$(mask_to_prefix 255.0.0.0)"       "mask_to_prefix /8"
assert_eq "25" "$(mask_to_prefix 255.255.255.128)" "mask_to_prefix /25"
assert_eq "23" "$(mask_to_prefix 255.255.254.0)"   "mask_to_prefix /23"
assert_eq "32" "$(mask_to_prefix 255.255.255.255)" "mask_to_prefix /32"
assert_eq "0"  "$(mask_to_prefix 0.0.0.0)"         "mask_to_prefix /0"

mask_to_prefix "" >/dev/null 2>&1; assert_rc 1 $? "mask_to_prefix rejects empty"
mask_to_prefix "banana" >/dev/null 2>&1; assert_rc 1 $? "mask_to_prefix rejects non-numeric"
mask_to_prefix "255.255.255" >/dev/null 2>&1; assert_rc 1 $? "mask_to_prefix rejects 3 octets"
mask_to_prefix "255.0.255.0" >/dev/null 2>&1; assert_rc 1 $? "mask_to_prefix rejects non-contiguous mask"
mask_to_prefix "255.255.200.0" >/dev/null 2>&1; assert_rc 1 $? "mask_to_prefix rejects invalid octet"
mask_to_prefix "255.255.255." >/dev/null 2>&1; assert_rc 1 $? "mask_to_prefix rejects trailing empty octet"
mask_to_prefix "255.255..0" >/dev/null 2>&1; assert_rc 1 $? "mask_to_prefix rejects doubled dot"

# --- octet_base -------------------------------------------------------------
assert_eq "192.168.1" "$(octet_base 192.168.1.42)" "octet_base strips the host octet"
assert_eq "10.0.0"    "$(octet_base 10.0.0.7)"     "octet_base on a 10/8 address"
octet_base "nope" >/dev/null 2>&1; assert_rc 1 $? "octet_base rejects malformed input"
octet_base "a.b.c.d" >/dev/null 2>&1; assert_rc 1 $? "octet_base rejects non-numeric quad"
octet_base "999.1.1.1" >/dev/null 2>&1; assert_rc 1 $? "octet_base rejects out-of-range octet"
octet_base "192.168.+1.1" >/dev/null 2>&1; assert_rc 1 $? "octet_base rejects octet with a leading +"
octet_base "192.168.1." >/dev/null 2>&1; assert_rc 1 $? "octet_base rejects trailing empty octet"
octet_base "192.168..1" >/dev/null 2>&1; assert_rc 1 $? "octet_base rejects doubled dot"

# --- find_free_ip -----------------------------------------------------------
assert_eq "53" "$DNS_IP_FIRST_OCTET" "candidate range starts at .53"
assert_eq "59" "$DNS_IP_LAST_OCTET"  "candidate range ends at .59"

# Stub: nothing is in use, so .53 wins.
arping_free() { return 0; }
assert_eq "192.168.1.53" "$(find_free_ip eth0 192.168.1)" "claims .53 when all free"

# Stub: .53 and .54 are occupied, .55 is free.
arping_free() {
    case "$2" in
        *.53|*.54) return 1 ;;
        *) return 0 ;;
    esac
}
assert_eq "192.168.1.55" "$(find_free_ip eth0 192.168.1)" "skips occupied addresses"

# Stub: everything is occupied.
arping_free() { return 1; }
find_free_ip eth0 192.168.1 >/dev/null 2>&1
assert_rc 1 $? "returns 1 when .53-.59 are all taken"

# Stub: only the last candidate is free — proves the loop is inclusive of .59.
arping_free() { case "$2" in *.59) return 0 ;; *) return 1 ;; esac; }
assert_eq "192.168.1.59" "$(find_free_ip eth0 192.168.1)" "range is inclusive of .59"

# --- resolv_conf_contents ---------------------------------------------------
# udhcpc hands us the LAN's DNS servers in $dns. Without writing them out, the
# appliance's OS has no resolver at all: dns-ip runs udhcpc with a custom lease
# script that never touches /etc/resolv.conf, then flushes the address.
assert_eq "nameserver 10.8.8.1" "$(resolv_conf_contents "10.8.8.1")" \
    "resolv_conf_contents emits a single nameserver"
assert_eq "nameserver 10.8.8.1
nameserver 1.1.1.1" "$(resolv_conf_contents "10.8.8.1 1.1.1.1")" \
    "resolv_conf_contents emits one line per nameserver"
assert_eq "" "$(resolv_conf_contents "")" \
    "resolv_conf_contents yields nothing for an empty lease"

# A malformed entry must not reach resolv.conf: the lease is attacker-adjacent
# input on an untrusted LAN, and a garbage nameserver line breaks resolution
# for everything on the box.
assert_eq "nameserver 10.8.8.1" "$(resolv_conf_contents "10.8.8.1 not-an-ip 999.1.1.1")" \
    "resolv_conf_contents drops entries that are not valid IPv4 addresses"

test_summary "test_dns_ip"
