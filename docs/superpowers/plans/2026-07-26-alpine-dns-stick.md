# alpine-dns-stick Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a two-phase toolchain that turns a USB stick into a portable, immutable Technitium DNS appliance which claims a static IP in the `.53`–`.59` range on any LAN and refuses to serve DNS if it cannot.

**Architecture:** `build-usb.sh` runs on macOS and produces a writable FAT32/UEFI stick by copying the Alpine 3.24.1 ISO tree onto it (not `dd` — a `dd`'d ISO is read-only and breaks `lbu` persistence). `provision.sh` runs once on the booted appliance and installs Technitium plus two OpenRC services, then freezes everything into an apkovl with `lbu commit`. Pure logic in every script is factored into small named functions so a shell test harness can exercise it on macOS without hardware.

**Tech Stack:** bash 3.2 (macOS host), POSIX sh / busybox ash (Alpine target), OpenRC, Technitium DNS Server v15.4 on Alpine's musl-native `aspnetcore10-runtime`, `iputils-arping`.

**Spec:** `docs/superpowers/specs/2026-07-26-alpine-dns-stick-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

- `build-usb.sh` must run under **macOS stock bash 3.2**. No associative arrays, no `local -n`, no `${var^^}`, no `mapfile`, no `&>>`. Use `set -euo pipefail`.
- `provision.sh`, `alpine/dns-ip.initd`, `alpine/technitium.initd`, and everything under `tests/` must be **POSIX sh** compatible with busybox ash. No `local` keyword reliance for correctness (busybox supports it, but prefix helper variables with `_` to avoid collisions), no bashisms, no `[[ ]]`, no arrays.
- Alpine version `3.24.1`; ISO `alpine-standard-3.24.1-x86_64.iso`; sha256 `f4dd613206676c62949144c8ad75fc64582099f444dd1485bae104a60f51dd26`.
- Alpine mirror base `https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64`.
- Technitium portable URL `https://download.technitium.com/dns/DnsServerPortable.tar.gz` (unversioned — checksum is observed at provision time, never pinned in the script).
- Alpine packages, exact strings: `aspnetcore10-runtime`, `libmsquic`, `icu-libs`, `icu-data-full`, `iputils-arping=20250605-r2`.
- Kernel cmdline, verbatim: `modules=loop,squashfs,sd-mod,usb-storage` — **no `quiet`**. GRUB `timeout=3`.
- Partition scheme is **MBR**, filesystem FAT32, volume name `ALPINE`.
- `arping -D` exit codes: **0 = address free**, **1 = address in use**. Never invert this.
- Technitium API base `http://127.0.0.1:5380`. Blocklist URLs longer than 255 characters are rejected by `/api/settings/set` and must be filtered out.
- Hostname is `dns-appliance`. Candidate octet range is 53–59 inclusive.
- Never write code that runs `dd`, `diskutil eraseDisk`, or any other destructive command during development or testing.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `tests/assert.sh` | Assertion primitives and pass/fail counters. Sourced by every test file. |
| `tests/run-tests.sh` | Runs all `tests/test_*.sh`, then shellcheck if available. Single entry point. |
| `tests/test_dns_ip.sh` | Exercises `dns-ip.initd` pure functions with a stubbed `arping_free`. |
| `tests/test_technitium.sh` | Exercises `technitium.initd` endpoint construction and dependency declaration. |
| `tests/test_build_usb.sh` | Exercises `build-usb.sh` dependency check, plist disk validation, grub.cfg, checksums. |
| `tests/test_provision.sh` | Exercises `provision.sh` blocklist parsing, boot-medium detection, password generation. |
| `alpine/dns-ip.initd` | Subnet discovery, address claiming. Owns `eth0` entirely. |
| `alpine/technitium.initd` | Supervised DNS server; `need dns-ip` interlock; binds to the claimed address. |
| `config/blocklists.txt` | Blocklist URLs, one per line, `#` comments. |
| `build-usb.sh` | Phase 1, macOS: fetch/verify ISO, select and format disk, populate stick, checklist. |
| `provision.sh` | Phase 2, Alpine: packages, Technitium, services, API config, `lbu commit`. |
| `README.md` | Architecture, usage, troubleshooting. |

**Sourcing guard.** `build-usb.sh` and `provision.sh` end with:

```sh
if [ "${ADS_SOURCE_ONLY:-0}" != "1" ]; then
    main "$@"
fi
```

Test files set `ADS_SOURCE_ONLY=1` before sourcing, so they get the functions without triggering the destructive main flow. The two `.initd` files need no guard: OpenRC scripts only *define* `depend`/`start`/`stop`, so sourcing them is already side-effect free. Keeping them side-effect free is a hard requirement — no top-level code beyond variable assignments and function definitions.

---

### Task 1: Test harness and blocklist config

**Files:**
- Create: `tests/assert.sh`
- Create: `tests/run-tests.sh`
- Create: `tests/test_harness.sh`
- Create: `config/blocklists.txt`

**Interfaces:**
- Consumes: nothing.
- Produces: `assert_eq EXPECTED ACTUAL MESSAGE`, `assert_rc EXPECTED_RC ACTUAL_RC MESSAGE`, `assert_contains HAYSTACK NEEDLE MESSAGE`, `assert_not_contains HAYSTACK NEEDLE MESSAGE`, `test_summary NAME` (returns non-zero if any assertion failed). Counters `ADS_TESTS_RUN` and `ADS_TESTS_FAILED`. Every later task's test file sources `tests/assert.sh` and ends with `test_summary`.

- [ ] **Step 1: Write the failing test for the harness itself**

Create `tests/test_harness.sh`. The harness must be trustworthy before anything relies on it, so this verifies that a failing assertion actually increments the failure counter.

```sh
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
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `sh tests/test_harness.sh`
Expected: FAIL — `tests/assert.sh: No such file or directory`

- [ ] **Step 3: Implement the assertion library**

Create `tests/assert.sh`:

```sh
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `sh tests/test_harness.sh`
Expected: PASS. The intentional failure runs inside a silenced subshell, so no `FAIL` line appears. Output ends with `ok   a failing assert_eq increments ADS_TESTS_FAILED` and `-- test_harness: 5 assertions, 0 failed`. Exit code 0 — confirm with `echo $?`.

- [ ] **Step 5: Write the suite runner**

Create `tests/run-tests.sh`:

```sh
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
```

Make it executable: `chmod +x tests/run-tests.sh`

- [ ] **Step 6: Run the suite**

Run: `./tests/run-tests.sh`
Expected: PASS. `== tests/test_harness.sh ==` section passes, shellcheck section prints `SKIPPED - shellcheck not installed`, final line `ALL TESTS PASSED`, exit 0.

- [ ] **Step 7: Create the blocklist seed file**

Create `config/blocklists.txt`:

```
# Ad-block list URLs for Technitium DNS Server, one per line.
# Lines beginning with # are comments; a # anywhere on a line starts a comment.
# Whitespace is stripped. URLs longer than 255 characters are skipped with a
# warning, because /api/settings/set rejects them.
#
# Applied by provision.sh via the Technitium settings API. To change these
# after provisioning, edit this file and re-run provision.sh, or edit the list
# directly in the web console and run `lbu commit -d`.

https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts
```

- [ ] **Step 8: Commit**

```bash
git add tests config
git commit -m "test: add shell test harness and blocklist seed config"
```

---

### Task 2: `dns-ip` OpenRC service

**Files:**
- Create: `alpine/dns-ip.initd`
- Create: `tests/test_dns_ip.sh`

**Interfaces:**
- Consumes: `tests/assert.sh` from Task 1.
- Produces: `mask_to_prefix MASK` → echoes prefix 0–32, rc 1 if unparseable or non-contiguous. `octet_base IPV4` → echoes the first three octets (`192.168.1.42` → `192.168.1`), rc 1 if malformed. `arping_free IFACE IP` → rc 0 when free. `find_free_ip IFACE BASE` → echoes the first free candidate address, rc 1 when all are taken. Constants `DNS_IP_FIRST_OCTET=53`, `DNS_IP_LAST_OCTET=59`, `DNS_IP_RUNFILE=/run/dns-ip`, `DNS_IP_IFACE=eth0`, `DNS_IP_LEASE=/run/dns-ip.lease`. Task 3 reads `DNS_IP_RUNFILE`; Task 5 starts this service by name.

- [ ] **Step 1: Write the failing test**

Create `tests/test_dns_ip.sh`:

```sh
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

# --- octet_base -------------------------------------------------------------
assert_eq "192.168.1" "$(octet_base 192.168.1.42)" "octet_base strips the host octet"
assert_eq "10.0.0"    "$(octet_base 10.0.0.7)"     "octet_base on a 10/8 address"
octet_base "nope" >/dev/null 2>&1; assert_rc 1 $? "octet_base rejects malformed input"

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

test_summary "test_dns_ip"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `sh tests/test_dns_ip.sh`
Expected: FAIL — `alpine/dns-ip.initd: No such file or directory`

- [ ] **Step 3: Implement the service**

Create `alpine/dns-ip.initd`:

```sh
#!/sbin/openrc-run
# shellcheck shell=sh
# dns-ip - discover the LAN, then claim a predictable static address.
#
# This service owns eth0 completely. /etc/network/interfaces deliberately has
# no eth0 stanza, so nothing races this script for the address.
#
# Sourced by tests/test_dns_ip.sh, so everything below must be a variable
# assignment or a function definition. No top-level side effects.

name="dns-ip"
description="Claim a static LAN address in the .53-.59 range"

DNS_IP_IFACE="${DNS_IP_IFACE:-eth0}"
DNS_IP_FIRST_OCTET=53
DNS_IP_LAST_OCTET=59
DNS_IP_RUNFILE="${DNS_IP_RUNFILE:-/run/dns-ip}"
DNS_IP_LEASE="${DNS_IP_LEASE:-/run/dns-ip.lease}"

depend() {
    need localmount
    before net
}

# Convert a dotted-quad netmask to a prefix length.
# Echoes 0-32 on success. Returns 1 for anything malformed or non-contiguous
# (255.0.255.0 is not a valid mask, and silently accepting it would produce a
# wrong prefix rather than an honest failure).
mask_to_prefix() {
    _m="$1"
    case "$_m" in
        *.*.*.*.*) return 1 ;;
        *.*.*.*) ;;
        *) return 1 ;;
    esac

    _prefix=0
    _partial_seen=0
    _oifs="$IFS"
    IFS=.
    for _octet in $_m; do
        case "$_octet" in
            255) _bits=8 ;;
            254) _bits=7 ;;
            252) _bits=6 ;;
            248) _bits=5 ;;
            240) _bits=4 ;;
            224) _bits=3 ;;
            192) _bits=2 ;;
            128) _bits=1 ;;
            0)   _bits=0 ;;
            *)   IFS="$_oifs"; return 1 ;;
        esac
        # Once a non-255 octet appears, every later octet must be 0.
        if [ "$_partial_seen" -eq 1 ] && [ "$_bits" -ne 0 ]; then
            IFS="$_oifs"
            return 1
        fi
        [ "$_bits" -lt 8 ] && _partial_seen=1
        _prefix=$((_prefix + _bits))
    done
    IFS="$_oifs"

    printf '%s\n' "$_prefix"
}

# 192.168.1.42 -> 192.168.1
octet_base() {
    case "$1" in
        *.*.*.*.*) return 1 ;;
        *.*.*.*) ;;
        *) return 1 ;;
    esac
    printf '%s\n' "${1%.*}"
}

# Is the address free?
#
# arping -D is duplicate address detection mode. For the pinned
# iputils-arping 20250605-r2:
#
#   exit 0 -> DAD succeeded, NO replies received -> address is FREE
#   exit 1 -> a reply arrived                    -> address is IN USE
#
# This is inverted relative to arping's ordinary reachability mode, and
# relative to Thomas Habets' unrelated `arping` package, where a 0 exit means
# the host answered. provision.sh pins the package version so that a change in
# these semantics fails at install time rather than silently claiming an
# address somebody else is already using.
arping_free() {
    arping -D -c 2 -w 3 -I "$1" "$2" >/dev/null 2>&1
}

# Echo the first free candidate in BASE.53 .. BASE.59, or return 1.
find_free_ip() {
    _iface="$1"
    _base="$2"
    _octet="$DNS_IP_FIRST_OCTET"
    while [ "$_octet" -le "$DNS_IP_LAST_OCTET" ]; do
        _candidate="${_base}.${_octet}"
        if arping_free "$_iface" "$_candidate"; then
            printf '%s\n' "$_candidate"
            return 0
        fi
        _octet=$((_octet + 1))
    done
    return 1
}

# Run udhcpc purely to learn the subnet and gateway, then release.
# Populates DNS_IP_LEASE with `ip=`, `subnet=`, `router=` lines.
discover_lease() {
    cat > /run/dns-ip-lease.script <<'LEASESCRIPT'
#!/bin/sh
[ "$1" = "bound" ] || exit 0
{
    echo "ip=$ip"
    echo "subnet=$subnet"
    echo "router=$router"
} > /run/dns-ip.lease
LEASESCRIPT
    chmod +x /run/dns-ip-lease.script
    rm -f "$DNS_IP_LEASE"
    udhcpc -i "$DNS_IP_IFACE" -n -q -t 5 -s /run/dns-ip-lease.script >/dev/null 2>&1
}

start() {
    ebegin "Claiming a LAN address for $DNS_IP_IFACE"

    ip link set "$DNS_IP_IFACE" up 2>/dev/null

    if ! discover_lease || [ ! -f "$DNS_IP_LEASE" ]; then
        eerror "DHCP discovery failed on $DNS_IP_IFACE - cannot determine the subnet"
        eerror "Technitium will not be started. Check the cable, switch, and DHCP server."
        eend 1
        return 1
    fi

    # shellcheck disable=SC1090  # runtime-generated lease file, path is known
    . "$DNS_IP_LEASE"

    if [ -z "${ip:-}" ] || [ -z "${router:-}" ]; then
        eerror "DHCP lease did not include an address and gateway - refusing to continue"
        eend 1
        return 1
    fi

    if _prefix=$(mask_to_prefix "${subnet:-}"); then
        einfo "Discovered subnet mask ${subnet} (/${_prefix}), gateway ${router}"
    else
        _prefix=24
        ewarn "Could not parse netmask '${subnet:-<empty>}' from the DHCP lease;"
        ewarn "assuming /24. If this LAN is not a /24 the claimed address may be"
        ewarn "unreachable - set the mask correctly on your DHCP server."
    fi

    if ! _base=$(octet_base "$ip"); then
        eerror "DHCP lease address '$ip' is not a valid IPv4 address"
        eend 1
        return 1
    fi

    # Discovery is finished. Drop the DHCP address before probing, so our own
    # lease cannot answer the duplicate-address probes.
    ip addr flush dev "$DNS_IP_IFACE"

    if ! _claimed=$(find_free_ip "$DNS_IP_IFACE" "$_base"); then
        eerror "no IP available in .53-.59, refusing to start"
        eerror "All of ${_base}.53 through ${_base}.59 answered ARP probes."
        eerror "Free one of them, or move the appliance to another subnet."
        eend 1
        return 1
    fi

    ip addr add "${_claimed}/${_prefix}" dev "$DNS_IP_IFACE"
    ip route add default via "$router" dev "$DNS_IP_IFACE" 2>/dev/null

    printf '%s\n' "$_claimed" > "$DNS_IP_RUNFILE"
    einfo "Claimed ${_claimed}/${_prefix} on $DNS_IP_IFACE"
    eend 0
}

stop() {
    ebegin "Releasing the claimed LAN address"
    ip addr flush dev "$DNS_IP_IFACE" 2>/dev/null
    rm -f "$DNS_IP_RUNFILE" "$DNS_IP_LEASE"
    eend 0
}
```

Note the test file stubs `einfo`/`ewarn`/`eerror`/`checkpath` but not `ebegin`/`eend` — those only appear inside `start`/`stop`, which the tests never call.

- [ ] **Step 4: Run the test to verify it passes**

Run: `sh tests/test_dns_ip.sh`
Expected: PASS — `-- test_dns_ip: 21 assertions, 0 failed`, exit 0.

- [ ] **Step 5: Run the whole suite**

Run: `./tests/run-tests.sh`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 6: Commit**

```bash
git add alpine/dns-ip.initd tests/test_dns_ip.sh
git commit -m "feat: add dns-ip service that claims a .53-.59 address via ARP DAD"
```

---

### Task 3: `technitium` OpenRC service

**Files:**
- Create: `alpine/technitium.initd`
- Create: `tests/test_technitium.sh`

**Interfaces:**
- Consumes: `DNS_IP_RUNFILE` (`/run/dns-ip`) written by Task 2.
- Produces: `technitium_endpoints IP` → echoes `IP:53,127.0.0.1:53`, rc 1 on empty input. `claimed_ip` → echoes the contents of `/run/dns-ip`, rc 1 if missing or empty. Constants `TECHNITIUM_DIR=/opt/technitium`, `TECHNITIUM_API=http://127.0.0.1:5380`. Task 5 installs this file and reuses `TECHNITIUM_DIR`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_technitium.sh`:

```sh
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

# --- interlock and layout ---------------------------------------------------
_src=$(cat "$(dirname "$0")/../alpine/technitium.initd")
assert_contains "$_src" "need dns-ip" \
    "declares the need dns-ip interlock so DNS never starts without an address"
assert_eq "/opt/technitium" "$TECHNITIUM_DIR" "installs under /opt/technitium"
assert_contains "$TECHNITIUM_API" "127.0.0.1:5380" "API base points at loopback:5380"

test_summary "test_technitium"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `sh tests/test_technitium.sh`
Expected: FAIL — `alpine/technitium.initd: No such file or directory`

- [ ] **Step 3: Implement the service**

Create `alpine/technitium.initd`:

```sh
#!/sbin/openrc-run
# shellcheck shell=sh
# technitium - Technitium DNS Server, bound to the address dns-ip claimed.
#
# Sourced by tests/test_technitium.sh, so everything below must be a variable
# assignment or a function definition. No top-level side effects.

name="technitium"
description="Technitium DNS Server"

TECHNITIUM_DIR="${TECHNITIUM_DIR:-/opt/technitium}"
TECHNITIUM_API="${TECHNITIUM_API:-http://127.0.0.1:5380}"
DNS_IP_RUNFILE="${DNS_IP_RUNFILE:-/run/dns-ip}"
TECHNITIUM_CREDS="${TECHNITIUM_CREDS:-/etc/dns-appliance/admin-password}"

supervisor="supervise-daemon"
command="/usr/bin/dotnet"
command_args="${TECHNITIUM_DIR}/DnsServerApp.dll"
directory="$TECHNITIUM_DIR"
pidfile="/run/technitium.pid"
output_log="/var/log/technitium.log"
error_log="/var/log/technitium.log"
respawn_delay=5
respawn_max=0

depend() {
    # The interlock: if dns-ip fails, OpenRC will not start this service, so
    # the appliance never serves DNS from an address it did not deliberately
    # claim.
    need dns-ip
    after firewall
}

# Echo the DNS listen endpoints for a claimed address.
technitium_endpoints() {
    [ -n "${1:-}" ] || return 1
    printf '%s:53,127.0.0.1:53\n' "$1"
}

# Echo the address dns-ip claimed, or fail.
claimed_ip() {
    [ -s "$DNS_IP_RUNFILE" ] || return 1
    _ip=$(cat "$DNS_IP_RUNFILE")
    [ -n "$_ip" ] || return 1
    printf '%s\n' "$_ip"
}

start_pre() {
    if ! claimed_ip >/dev/null; then
        eerror "$DNS_IP_RUNFILE is missing or empty - dns-ip did not claim an address"
        eerror "Refusing to start the DNS server. Run: rc-service dns-ip start"
        return 1
    fi
    checkpath --directory --mode 0755 "$TECHNITIUM_DIR/config"
    checkpath --file --mode 0644 "$output_log"
}

start_post() {
    # Re-apply the bind address whenever it changes, so moving the stick to a
    # different subnet re-binds without manual intervention. Best effort: the
    # server may still be starting, and a failure here must not take the
    # service down, so it is logged rather than fatal.
    _ip=$(claimed_ip) || return 0
    _endpoints=$(technitium_endpoints "$_ip") || return 0

    [ -s "$TECHNITIUM_CREDS" ] || return 0
    _pass=$(cat "$TECHNITIUM_CREDS")

    _wait=0
    while [ "$_wait" -lt 60 ]; do
        if curl -fsS "$TECHNITIUM_API/api/user/login?user=admin&pass=${_pass}" \
            >/run/technitium-login.json 2>/dev/null; then
            break
        fi
        _wait=$((_wait + 2))
        sleep 2
    done

    _token=$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' /run/technitium-login.json 2>/dev/null)
    rm -f /run/technitium-login.json
    if [ -z "$_token" ]; then
        ewarn "Could not log in to the Technitium API to set the bind address."
        ewarn "The server is running; set it manually in the web console."
        return 0
    fi

    if curl -fsS -X POST "$TECHNITIUM_API/api/settings/set" \
        --data-urlencode "token=${_token}" \
        --data-urlencode "dnsServerLocalEndPoints=${_endpoints}" \
        >/dev/null 2>&1; then
        einfo "Technitium bound to ${_endpoints}"
    else
        ewarn "Failed to set dnsServerLocalEndPoints to ${_endpoints}"
    fi
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `sh tests/test_technitium.sh`
Expected: PASS — `-- test_technitium: 9 assertions, 0 failed`, exit 0.

- [ ] **Step 5: Run the whole suite**

Run: `./tests/run-tests.sh`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 6: Commit**

```bash
git add alpine/technitium.initd tests/test_technitium.sh
git commit -m "feat: add technitium service with a need dns-ip interlock"
```

---

### Task 4: `build-usb.sh` — macOS stick builder

**Files:**
- Create: `build-usb.sh`
- Create: `tests/test_build_usb.sh`

**Interfaces:**
- Consumes: `alpine/`, `config/`, `provision.sh` (copied onto the stick; `provision.sh` need not exist yet for the tests to pass, but Task 5 creates it and the copy step tolerates its absence only by failing loudly — implement the copy so it errors if `provision.sh` is missing).
- Produces: `missing_deps` → echoes space-separated missing commands from `REQUIRED_CMDS`. `sha256_of FILE` → echoes the hex digest. `checksum_ok FILE EXPECTED` → rc 0/1. `plist_value PLIST_XML KEY` → echoes the value, rc 3 if the key is absent. `disk_target_reason` (plist on stdin) → echoes a refusal reason and returns 1 when the disk must not be used. `grub_cfg_contents` → echoes the grub.cfg body. Constants `ALPINE_VERSION`, `ALPINE_ISO`, `ALPINE_ISO_SHA256`, `ALPINE_MIRROR`, `USB_VOLUME_NAME`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_build_usb.sh`:

```sh
#!/bin/sh
# Exercises the pure logic in build-usb.sh. Nothing here touches a real disk.
set -u
. "$(dirname "$0")/assert.sh"

ADS_SOURCE_ONLY=1
export ADS_SOURCE_ONLY
# shellcheck disable=SC1091  # sourced for its functions, main() is guarded
. "$(dirname "$0")/../build-usb.sh"

_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

# --- pinned constants -------------------------------------------------------
assert_eq "3.24.1" "$ALPINE_VERSION" "Alpine version is pinned to 3.24.1"
assert_eq "alpine-standard-3.24.1-x86_64.iso" "$ALPINE_ISO" "ISO filename matches the version"
assert_eq "f4dd613206676c62949144c8ad75fc64582099f444dd1485bae104a60f51dd26" \
    "$ALPINE_ISO_SHA256" "ISO sha256 is the verified digest"
assert_eq "ALPINE" "$USB_VOLUME_NAME" "volume name is ALPINE"

# --- missing_deps -----------------------------------------------------------
REQUIRED_CMDS="ls cat"
assert_eq "" "$(missing_deps)" "missing_deps is empty when everything is present"
REQUIRED_CMDS="ls ads_definitely_not_a_real_command cat"
assert_eq "ads_definitely_not_a_real_command" "$(missing_deps)" \
    "missing_deps names the absent command"
REQUIRED_CMDS="ads_nope_one ads_nope_two"
assert_eq "ads_nope_one ads_nope_two" "$(missing_deps)" "missing_deps lists all absentees"

# --- checksums --------------------------------------------------------------
printf 'hello' > "$_tmp/f"
# echo -n hello | shasum -a 256
_expected="2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
assert_eq "$_expected" "$(sha256_of "$_tmp/f")" "sha256_of computes the digest"
checksum_ok "$_tmp/f" "$_expected"; assert_rc 0 $? "checksum_ok accepts a matching digest"
checksum_ok "$_tmp/f" "deadbeef"; assert_rc 1 $? "checksum_ok rejects a mismatched digest"
checksum_ok "$_tmp/absent" "$_expected"; assert_rc 1 $? "checksum_ok rejects a missing file"

# --- plist parsing and disk safety -----------------------------------------
_mk_plist() {
    # $1 Internal, $2 Ejectable, $3 WholeDisk  (each "true" or "false")
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>Internal</key><$1/>
    <key>Ejectable</key><$2/>
    <key>WholeDisk</key><$3/>
    <key>DeviceIdentifier</key><string>disk9</string>
</dict>
</plist>
PLIST
}

assert_eq "disk9" "$(plist_value "$(_mk_plist false true true)" DeviceIdentifier)" \
    "plist_value reads a string key"
assert_eq "true" "$(plist_value "$(_mk_plist false true true)" Ejectable)" \
    "plist_value normalises booleans to true/false"
plist_value "$(_mk_plist false true true)" NoSuchKey >/dev/null 2>&1
assert_rc 3 $? "plist_value returns 3 for an absent key"

_mk_plist false true true | disk_target_reason >/dev/null 2>&1
assert_rc 0 $? "an external, ejectable whole disk is an acceptable target"

_reason=$(_mk_plist true true true | disk_target_reason 2>&1)
assert_rc 1 $? "an internal disk is refused"
assert_contains "$_reason" "Internal" "the refusal explains that the disk is internal"

_reason=$(_mk_plist false true false | disk_target_reason 2>&1)
assert_rc 1 $? "a partition rather than a whole disk is refused"
assert_contains "$_reason" "whole disk" "the refusal explains the whole-disk requirement"

_reason=$(_mk_plist false false true | disk_target_reason 2>&1)
assert_rc 1 $? "a non-ejectable disk is refused"

# --- grub.cfg ---------------------------------------------------------------
_grub=$(grub_cfg_contents)
assert_contains "$_grub" "set timeout=3" "grub timeout is 3 seconds"
assert_contains "$_grub" "modules=loop,squashfs,sd-mod,usb-storage" "kernel modules line is intact"
assert_contains "$_grub" "/boot/vmlinuz-lts" "grub points at the lts kernel"
assert_contains "$_grub" "/boot/initramfs-lts" "grub points at the lts initramfs"
assert_not_contains "$_grub" "quiet" "quiet is dropped so boot failures are visible"

test_summary "test_build_usb"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `sh tests/test_build_usb.sh`
Expected: FAIL — `build-usb.sh: No such file or directory`

- [ ] **Step 3: Implement the builder**

Create `build-usb.sh`. Note `set -euo pipefail` is set only when *not* sourced, because `-e` inside a sourced test would abort the test file on the first intentionally-failing call.

```bash
#!/usr/bin/env bash
# build-usb.sh - build a bootable Alpine DNS appliance USB stick, on macOS.
#
# Phase 1 of two. Produces a writable FAT32/UEFI stick by copying the Alpine
# ISO tree onto it. Deliberately NOT a dd flash: a dd'd ISO is read-only
# ISO9660, which leaves `lbu commit` nowhere to persist the appliance config.
#
# Requires macOS stock bash 3.2. No bash 4 features.

if [ "${ADS_SOURCE_ONLY:-0}" != "1" ]; then
    set -euo pipefail
fi

# ---------------------------------------------------------------- constants --
ALPINE_VERSION="3.24.1"
ALPINE_ISO="alpine-standard-${ALPINE_VERSION}-x86_64.iso"
ALPINE_ISO_SHA256="f4dd613206676c62949144c8ad75fc64582099f444dd1485bae104a60f51dd26"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64"
USB_VOLUME_NAME="ALPINE"
REQUIRED_CMDS="diskutil curl shasum python3 hdiutil mount"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOWNLOAD_DIR="$REPO_DIR/downloads"
ISO_PATH="$DOWNLOAD_DIR/$ALPINE_ISO"

ISO_MOUNT=""
ISO_DEVICE=""

# ------------------------------------------------------------------ logging --
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m/!\\\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ cleanup --
cleanup() {
    if [ -n "$ISO_MOUNT" ] && mount | grep -q " $ISO_MOUNT "; then
        umount "$ISO_MOUNT" 2>/dev/null || true
    fi
    if [ -n "$ISO_DEVICE" ]; then
        hdiutil detach "$ISO_DEVICE" -quiet 2>/dev/null || true
    fi
    if [ -n "$ISO_MOUNT" ] && [ -d "$ISO_MOUNT" ]; then
        rmdir "$ISO_MOUNT" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------ pure helpers ---

# Echo the commands from REQUIRED_CMDS that are not on PATH.
missing_deps() {
    local missing=""
    local cmd
    for cmd in $REQUIRED_CMDS; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="$missing $cmd"
        fi
    done
    printf '%s\n' "${missing# }"
}

sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

checksum_ok() {
    [ -f "$1" ] || return 1
    [ "$(sha256_of "$1")" = "$2" ]
}

# Read one key out of a `diskutil info -plist` document.
# $1 = the plist XML, $2 = the key. Booleans normalise to true/false.
# Returns 2 if the document will not parse, 3 if the key is absent.
plist_value() {
    printf '%s' "$1" | python3 -c '
import sys, plistlib
key = sys.argv[1]
try:
    doc = plistlib.loads(sys.stdin.buffer.read())
except Exception:
    sys.exit(2)
if key not in doc:
    sys.exit(3)
val = doc[key]
if val is True:
    print("true")
elif val is False:
    print("false")
else:
    print(val)
' "$2"
}

# Decide whether a disk may be erased. Reads `diskutil info -plist` on stdin.
# Echoes a human-readable reason and returns 1 when the disk must not be used.
disk_target_reason() {
    local plist internal ejectable whole
    plist="$(cat)"

    if ! internal="$(plist_value "$plist" Internal)"; then
        echo "could not read this disk's info - is the identifier correct?"
        return 1
    fi
    if [ "$internal" = "true" ]; then
        echo "diskutil reports Internal: Yes - refusing to erase an internal disk"
        return 1
    fi

    whole="$(plist_value "$plist" WholeDisk)" || whole="false"
    if [ "$whole" != "true" ]; then
        echo "that is not a whole disk - pass an identifier like disk4, not disk4s1"
        return 1
    fi

    ejectable="$(plist_value "$plist" Ejectable)" || ejectable="false"
    if [ "$ejectable" != "true" ]; then
        echo "diskutil reports Ejectable: No - refusing, this does not look removable"
        return 1
    fi

    return 0
}

# The grub.cfg written to the stick. Differs from the ISO's in two ways:
# timeout is 3s rather than 1s, and `quiet` is dropped so that a headless
# appliance's boot failures are legible on a plugged-in monitor.
grub_cfg_contents() {
    cat <<'GRUBCFG'
set timeout=3
set default=0

menuentry "Alpine DNS appliance" {
    linux  /boot/vmlinuz-lts modules=loop,squashfs,sd-mod,usb-storage
    initrd /boot/initramfs-lts
}
GRUBCFG
}

# ------------------------------------------------------------------- steps ---

check_deps() {
    log "Checking dependencies"
    local missing
    missing="$(missing_deps)"
    if [ -n "$missing" ]; then
        die "missing required command(s): $missing"
    fi
    echo "    all present: $REQUIRED_CMDS"
}

fetch_iso() {
    log "Acquiring $ALPINE_ISO"
    mkdir -p "$DOWNLOAD_DIR"

    if checksum_ok "$ISO_PATH" "$ALPINE_ISO_SHA256"; then
        echo "    cached copy is checksum-valid, skipping download"
        return 0
    fi

    if [ -f "$ISO_PATH" ]; then
        warn "cached ISO failed its checksum; re-downloading"
        rm -f "$ISO_PATH"
    fi

    echo "    downloading from $ALPINE_MIRROR"
    curl -fL --retry 3 --progress-bar -o "$ISO_PATH" "$ALPINE_MIRROR/$ALPINE_ISO" \
        || die "download failed"

    log "Verifying sha256"
    if ! checksum_ok "$ISO_PATH" "$ALPINE_ISO_SHA256"; then
        rm -f "$ISO_PATH"
        die "sha256 mismatch - expected $ALPINE_ISO_SHA256, got $(sha256_of "$ISO_PATH" 2>/dev/null || echo '<unreadable>')"
    fi
    echo "    sha256 OK"
}

# Prompt for the target disk, validate it, and make the user type it twice.
select_target() {
    log "Available disks"
    diskutil list
    echo

    printf 'Target disk identifier (e.g. disk4), or Ctrl-C to abort: '
    read -r TARGET_DISK
    [ -n "$TARGET_DISK" ] || die "no disk identifier given"
    TARGET_DISK="${TARGET_DISK#/dev/}"

    local info reason
    info="$(diskutil info -plist "/dev/$TARGET_DISK" 2>/dev/null)" \
        || die "diskutil does not recognise /dev/$TARGET_DISK"

    if ! reason="$(printf '%s' "$info" | disk_target_reason)"; then
        die "refusing /dev/$TARGET_DISK: $reason"
    fi

    echo
    log "This will PERMANENTLY ERASE /dev/$TARGET_DISK"
    diskutil list "/dev/$TARGET_DISK"
    echo
    warn "Everything on the disk above will be destroyed. There is no undo."
    printf 'Type the identifier again (%s) to confirm: ' "$TARGET_DISK"
    read -r confirm
    [ "$confirm" = "$TARGET_DISK" ] || die "confirmation did not match - nothing was changed"
}

format_target() {
    log "Unmounting /dev/$TARGET_DISK"
    diskutil unmountDisk force "/dev/$TARGET_DISK"

    log "Formatting /dev/$TARGET_DISK as FAT32 (MBR, volume $USB_VOLUME_NAME)"
    # MBR rather than GPT: some UEFI firmware only scans ESP-typed partitions
    # on GPT media, whereas MBR+FAT32 removable media boots essentially
    # everywhere.
    diskutil eraseDisk MS-DOS "$USB_VOLUME_NAME" MBR "/dev/$TARGET_DISK"
}

mount_iso() {
    log "Mounting $ALPINE_ISO"
    # `hdiutil attach` alone fails on this ISO with "no mountable file
    # systems" - its hybrid MBR defeats hdiutil's format detection. Attaching
    # raw and mounting cd9660 by hand works, and needs no sudo.
    ISO_DEVICE="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$ISO_PATH" \
        | head -1 | awk '{print $1}')"
    [ -n "$ISO_DEVICE" ] || die "could not attach the ISO"

    ISO_MOUNT="$(mktemp -d /tmp/alpine-iso.XXXXXX)"
    mount -t cd9660 -o rdonly "$ISO_DEVICE" "$ISO_MOUNT" \
        || die "could not mount the ISO's cd9660 filesystem"
    echo "    mounted $ISO_DEVICE at $ISO_MOUNT"
}

populate_stick() {
    local dest="/Volumes/$USB_VOLUME_NAME"
    [ -d "$dest" ] || die "expected the new volume at $dest but it is not there"

    log "Copying the Alpine boot tree to $dest"
    cp -R "$ISO_MOUNT/boot" "$dest/"
    cp -R "$ISO_MOUNT/efi" "$dest/"
    cp -R "$ISO_MOUNT/apks" "$dest/"
    cp "$ISO_MOUNT/.alpine-release" "$dest/"

    log "Writing our grub.cfg (timeout 3, no quiet)"
    mkdir -p "$dest/boot/grub"
    grub_cfg_contents > "$dest/boot/grub/grub.cfg"

    log "Copying provisioning files"
    [ -f "$REPO_DIR/provision.sh" ] || die "provision.sh is missing from $REPO_DIR"
    mkdir -p "$dest/provision"
    cp "$REPO_DIR/provision.sh" "$dest/provision/"
    chmod +x "$dest/provision/provision.sh"
    cp -R "$REPO_DIR/alpine" "$dest/provision/"
    cp -R "$REPO_DIR/config" "$dest/provision/"

    mkdir -p "$dest/cache"

    log "Flushing writes"
    sync
}

eject_target() {
    log "Ejecting /dev/$TARGET_DISK"
    diskutil eject "/dev/$TARGET_DISK"
}

print_checklist() {
    cat <<CHECKLIST

============================================================================
  The stick is ready. What to do next:
============================================================================

  1. Plug the stick into the target machine.

  2. Enter its firmware setup (usually F2, F10, F12, or Del at power-on) and:
       - Enable UEFI boot. This stick is UEFI-only; there is no legacy/CSM
         bootloader on it.
       - Disable Secure Boot. Alpine's bootx64.efi is not signed by Microsoft.
       - Put the USB stick first in the boot order.

  3. Boot it. You will briefly see a GRUB error reading

         error: no such device: alpine-std ${ALPINE_VERSION} x86_64

     This is expected and harmless - GRUB looks for the ISO's 24-character
     volume label, which cannot fit in a FAT32 label. It falls back to the
     correct device and boots anyway. See README.md.

  4. At the login prompt, log in as:  root
     There is no password on a fresh Alpine boot.

  5. Find the stick's mount point and run the provisioner:

         ls /media
         /media/<device>/provision/provision.sh

     ...where <device> is usually sda1 or usb. The script is idempotent, so
     if it fails partway you can simply run it again.

  6. When it finishes it prints the appliance's IP address and the generated
     Technitium admin password. Write the password down - it is also stored
     at /etc/dns-appliance/admin-password on the appliance.

  7. Point your router's DHCP DNS setting, or an individual client, at the
     address the appliance claimed.

============================================================================

CHECKLIST
}

main() {
    trap cleanup EXIT
    log "alpine-dns-stick builder - Alpine $ALPINE_VERSION"
    check_deps
    fetch_iso
    select_target
    format_target
    mount_iso
    populate_stick
    cleanup
    ISO_MOUNT=""
    ISO_DEVICE=""
    eject_target
    print_checklist
}

if [ "${ADS_SOURCE_ONLY:-0}" != "1" ]; then
    main "$@"
fi
```

Make it executable: `chmod +x build-usb.sh`

- [ ] **Step 4: Run the test to verify it passes**

Run: `sh tests/test_build_usb.sh`
Expected: PASS — `-- test_build_usb: 25 assertions, 0 failed`, exit 0.

- [ ] **Step 5: Verify the script refuses an internal disk, without erasing anything**

This exercises the real `diskutil` path against the Mac's own boot disk. It must refuse before any destructive call. `disk0` is the internal disk on every Mac.

Run: `printf 'disk0\n' | ./build-usb.sh 2>&1 | tail -5`
Expected: output ends with a line matching `ERR refusing /dev/disk0: diskutil reports Internal: Yes - refusing to erase an internal disk`, and no `eraseDisk` is ever reached. The ISO is already cached and checksum-valid, so this runs quickly.

Run: `printf 'disk99\n' | ./build-usb.sh 2>&1 | tail -3`
Expected: ends with `ERR diskutil does not recognise /dev/disk99`.

- [ ] **Step 6: Run the whole suite**

Run: `./tests/run-tests.sh`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 7: Commit**

```bash
git add build-usb.sh tests/test_build_usb.sh
git commit -m "feat: add macOS build-usb.sh producing a writable FAT32 UEFI stick"
```

---

### Task 5: `provision.sh` — Alpine provisioner

**Files:**
- Create: `provision.sh`
- Create: `tests/test_provision.sh`

**Interfaces:**
- Consumes: `alpine/dns-ip.initd` and `alpine/technitium.initd` from Tasks 2–3; `config/blocklists.txt` from Task 1; the `provision/` directory layout that Task 4 writes to the stick.
- Produces: `blocklist_urls FILE` → echoes a comma-joined URL list. `boot_medium_dir SCRIPT_PATH` → echoes the stick's mount point. `lbu_media_name DIR` → echoes the media basename. `random_password` → echoes 24 alphanumeric characters. `api_token PASSWORD` → echoes a session token. Constants `HOSTNAME_WANTED=dns-appliance`, `TECHNITIUM_DIR=/opt/technitium`, `TECHNITIUM_URL`, `CREDS_DIR=/etc/dns-appliance`, `APK_PACKAGES`, `BLOCKLIST_MAX_URL_LEN=255`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_provision.sh`:

```sh
#!/bin/sh
# Exercises the pure logic in provision.sh. Nothing here touches apk or a network.
set -u
. "$(dirname "$0")/assert.sh"

ADS_SOURCE_ONLY=1
export ADS_SOURCE_ONLY
# shellcheck disable=SC1091  # sourced for its functions, main() is guarded
. "$(dirname "$0")/../provision.sh"

_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

# --- pinned constants -------------------------------------------------------
assert_eq "dns-appliance" "$HOSTNAME_WANTED" "hostname is dns-appliance"
assert_eq "/opt/technitium" "$TECHNITIUM_DIR" "Technitium installs to /opt/technitium"
assert_eq "255" "$BLOCKLIST_MAX_URL_LEN" "blocklist URL cap matches the API limit"
assert_contains "$APK_PACKAGES" "aspnetcore10-runtime" "installs the .NET 10 runtime"
assert_contains "$APK_PACKAGES" "iputils-arping=20250605-r2" "arping version is pinned"
assert_contains "$APK_PACKAGES" "libmsquic" "installs libmsquic"
assert_contains "$APK_PACKAGES" "icu-libs" "installs icu-libs"
assert_not_contains "$APK_PACKAGES" "dotnet-runtime" "does not use Microsoft's glibc build"

# --- blocklist_urls ---------------------------------------------------------
cat > "$_tmp/lists.txt" <<'LISTS'
# a comment
https://example.com/a.txt

   https://example.com/b.txt
https://example.com/c.txt   # trailing comment
LISTS
assert_eq "https://example.com/a.txt,https://example.com/b.txt,https://example.com/c.txt" \
    "$(blocklist_urls "$_tmp/lists.txt")" \
    "blocklist_urls joins URLs and drops comments and blanks"

printf '# only comments\n\n' > "$_tmp/empty.txt"
assert_eq "" "$(blocklist_urls "$_tmp/empty.txt")" "blocklist_urls yields empty for a comment-only file"

# A URL over the 255-char API limit must be skipped, not silently truncated.
{
    printf 'https://example.com/ok.txt\n'
    printf 'https://example.com/'
    i=0; while [ $i -lt 250 ]; do printf 'x'; i=$((i + 1)); done
    printf '\n'
} > "$_tmp/long.txt"
assert_eq "https://example.com/ok.txt" "$(blocklist_urls "$_tmp/long.txt" 2>/dev/null)" \
    "blocklist_urls skips URLs over the 255 character limit"
assert_contains "$(blocklist_urls "$_tmp/long.txt" 2>&1 >/dev/null)" "255" \
    "blocklist_urls warns about the skipped URL"

# --- boot_medium_dir / lbu_media_name ---------------------------------------
mkdir -p "$_tmp/media/sda1/provision"
: > "$_tmp/media/sda1/provision/provision.sh"
assert_eq "$_tmp/media/sda1" "$(boot_medium_dir "$_tmp/media/sda1/provision/provision.sh")" \
    "boot_medium_dir climbs out of provision/"
assert_eq "sda1" "$(lbu_media_name "$_tmp/media/sda1")" "lbu_media_name takes the basename"
boot_medium_dir "$_tmp/nope/provision/provision.sh" >/dev/null 2>&1
assert_rc 1 $? "boot_medium_dir fails when the path does not exist"

# --- random_password --------------------------------------------------------
_pw=$(random_password)
assert_eq "24" "$(printf '%s' "$_pw" | wc -c | tr -d ' ')" "random_password is 24 characters"
assert_eq "" "$(printf '%s' "$_pw" | tr -d 'A-Za-z0-9')" "random_password is alphanumeric only"

# Two consecutive calls must differ. A generator stuck on a constant would
# silently give every appliance the same admin password.
_pw_a=$(random_password)
_pw_b=$(random_password)
assert_not_contains "$_pw_a" "$_pw_b" "random_password output varies between calls"

test_summary "test_provision"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `sh tests/test_provision.sh`
Expected: FAIL — `provision.sh: No such file or directory`

- [ ] **Step 3: Implement the provisioner**

Create `provision.sh`:

```sh
#!/bin/sh
# provision.sh - configure a booted Alpine diskless system into a DNS appliance.
#
# Phase 2 of two. Run once as root from the USB stick:
#     /media/<device>/provision/provision.sh
#
# Idempotent: every step is convergent, so re-running after a partial failure
# completes the job rather than compounding it.
#
# POSIX sh / busybox ash only.

if [ "${ADS_SOURCE_ONLY:-0}" != "1" ]; then
    set -eu
fi

# ---------------------------------------------------------------- constants --
HOSTNAME_WANTED="dns-appliance"
TECHNITIUM_DIR="/opt/technitium"
TECHNITIUM_URL="https://download.technitium.com/dns/DnsServerPortable.tar.gz"
TECHNITIUM_API="http://127.0.0.1:5380"
CREDS_DIR="/etc/dns-appliance"
CREDS_FILE="$CREDS_DIR/admin-password"
BLOCKLIST_MAX_URL_LEN=255

# Alpine's musl-native .NET. Microsoft's glibc build will not run here.
# iputils is pinned so that a change in arping's DAD exit-code semantics
# fails at install time rather than silently claiming an occupied address.
APK_PACKAGES="aspnetcore10-runtime libmsquic icu-libs icu-data-full iputils-arping=20250605-r2 curl"

# ------------------------------------------------------------------ logging --
log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '/!\\ %s\n' "$*" >&2; }
die()  { printf 'ERR %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------ pure helpers ---

# Read blocklist URLs from a file and echo them comma-joined for the
# /api/settings/set blockListUrls parameter. Drops blanks and comments.
# Skips any URL over the API's 255-character limit, with a warning on stderr:
# the API rejects the entire request if one entry is too long, so silently
# passing it through would break blocking altogether.
blocklist_urls() {
    _out=""
    while IFS= read -r _line || [ -n "$_line" ]; do
        _line="${_line%%#*}"
        _line=$(printf '%s' "$_line" | tr -d '[:space:]')
        [ -n "$_line" ] || continue
        if [ "${#_line}" -gt "$BLOCKLIST_MAX_URL_LEN" ]; then
            warn "skipping blocklist URL over $BLOCKLIST_MAX_URL_LEN chars: $(printf '%s' "$_line" | cut -c1-40)..."
            continue
        fi
        if [ -z "$_out" ]; then
            _out="$_line"
        else
            _out="$_out,$_line"
        fi
    done < "$1"
    printf '%s\n' "$_out"
}

# /media/sda1/provision/provision.sh -> /media/sda1
boot_medium_dir() {
    _dir=$(cd "$(dirname "$1")/.." 2>/dev/null && pwd) || return 1
    printf '%s\n' "$_dir"
}

# /media/sda1 -> sda1
lbu_media_name() {
    printf '%s\n' "${1##*/}"
}

random_password() {
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24
}

# Log in to the Technitium API and echo a session token.
api_token() {
    _resp=$(curl -fsS "$TECHNITIUM_API/api/user/login?user=admin&pass=$1" 2>/dev/null) || return 1
    _tok=$(printf '%s' "$_resp" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
    [ -n "$_tok" ] || return 1
    printf '%s\n' "$_tok"
}

# ------------------------------------------------------------------- steps ---

require_root() {
    [ "$(id -u)" = "0" ] || die "provision.sh must run as root"
}

locate_medium() {
    log "Locating the boot medium"
    MEDIUM_DIR=$(boot_medium_dir "$0") \
        || die "could not resolve the stick's mount point from $0"
    MEDIUM_DEV=$(lbu_media_name "$MEDIUM_DIR")
    info "stick mounted at $MEDIUM_DIR (device $MEDIUM_DEV)"

    if ! touch "$MEDIUM_DIR/.write-test" 2>/dev/null; then
        die "$MEDIUM_DIR is not writable.

This stick cannot persist the appliance configuration, which means it was not
built by build-usb.sh - most likely the ISO was dd'd onto it, producing a
read-only ISO9660 filesystem. See the 'Read-only stick' section of README.md
for the setup-bootable recovery procedure."
    fi
    rm -f "$MEDIUM_DIR/.write-test"
    info "stick is writable"
}

setup_base() {
    log "Configuring the base system"

    printf '%s\n' "$HOSTNAME_WANTED" > /etc/hostname
    hostname "$HOSTNAME_WANTED"
    info "hostname set to $HOSTNAME_WANTED"

    # eth0 is deliberately absent: dns-ip owns that interface end to end.
    # This is what guarantees no DHCP client persists on it.
    cat > /etc/network/interfaces <<'IFACES'
auto lo
iface lo inet loopback

# eth0 is intentionally not configured here.
# The dns-ip OpenRC service owns it: it runs udhcpc only to discover the
# subnet, releases the lease, then claims a static address in .53-.59.
IFACES
    info "eth0 left to the dns-ip service"

    setup-apkrepos -c -1 >/dev/null 2>&1 || warn "setup-apkrepos reported a problem; continuing"
    info "community repository enabled"

    mkdir -p "$MEDIUM_DIR/cache"
    setup-apkcache "$MEDIUM_DIR/cache" >/dev/null 2>&1 || warn "setup-apkcache reported a problem"
    info "apk cache at $MEDIUM_DIR/cache"

    setup-lbu "$MEDIUM_DEV" >/dev/null 2>&1 || warn "setup-lbu reported a problem"
    info "lbu media set to $MEDIUM_DEV"
}

install_packages() {
    log "Installing packages"
    apk update >/dev/null 2>&1 || die "apk update failed - is the network up?"
    # shellcheck disable=SC2086  # word splitting of the package list is intended
    apk add $APK_PACKAGES || die "apk add failed

If it failed on iputils-arping=20250605-r2, the pinned version is no longer in
the repository. Do NOT simply drop the pin: dns-ip.initd depends on arping -D
exiting 0 for a free address. Verify that semantics against the new version
first (see README.md, 'arping variants')."
    info "installed: $APK_PACKAGES"
}

install_technitium() {
    log "Installing Technitium DNS Server"
    mkdir -p "$TECHNITIUM_DIR" "$CREDS_DIR"
    chmod 0700 "$CREDS_DIR"

    _tarball="/tmp/DnsServerPortable.tar.gz"
    curl -fsSL -o "$_tarball" "$TECHNITIUM_URL" || die "could not download Technitium"

    # The upstream URL is unversioned, so the checksum is observed here rather
    # than pinned in the script. Recording it makes an unexpected upstream
    # change visible on the next run.
    _sha=$(sha256sum "$_tarball" | awk '{print $1}')
    if [ -f "$CREDS_DIR/technitium.sha256" ]; then
        _prev=$(cat "$CREDS_DIR/technitium.sha256")
        [ "$_prev" = "$_sha" ] || info "Technitium tarball changed upstream ($_prev -> $_sha)"
    fi
    printf '%s\n' "$_sha" > "$CREDS_DIR/technitium.sha256"

    tar -xzf "$_tarball" -C "$TECHNITIUM_DIR" --strip-components=1 \
        || die "could not extract Technitium"
    rm -f "$_tarball"
    info "extracted to $TECHNITIUM_DIR (sha256 $_sha)"
}

install_services() {
    log "Installing OpenRC services"
    _src="$MEDIUM_DIR/provision/alpine"
    for _svc in dns-ip technitium; do
        cp "$_src/${_svc}.initd" "/etc/init.d/$_svc" || die "could not install $_svc"
        chmod +x "/etc/init.d/$_svc"
        rc-update add "$_svc" default >/dev/null 2>&1
        info "$_svc installed and added to the default runlevel"
    done
}

start_services() {
    log "Starting services"

    rc-service dns-ip restart || die "dns-ip failed to claim an address

This is the same failure the appliance would hit at boot. Check the output
above: either DHCP discovery failed, or all of .53-.59 are already taken."

    [ -s /run/dns-ip ] || die "dns-ip reported success but /run/dns-ip is empty"
    CLAIMED_IP=$(cat /run/dns-ip)
    info "claimed $CLAIMED_IP"

    rc-service technitium restart || die "technitium failed to start - see /var/log/technitium.log"

    _wait=0
    while [ "$_wait" -lt 90 ]; do
        if curl -fsS "$TECHNITIUM_API/api/user/login?user=admin&pass=admin" >/dev/null 2>&1 \
           || [ -s "$CREDS_FILE" ]; then
            break
        fi
        _wait=$((_wait + 3))
        sleep 3
    done
    info "Technitium API is responding"
}

configure_technitium() {
    log "Configuring Technitium"

    # On a re-run the password has already been rotated, so try the stored one
    # first and fall back to the factory default.
    _pass="admin"
    [ -s "$CREDS_FILE" ] && _pass=$(cat "$CREDS_FILE")

    if ! _token=$(api_token "$_pass"); then
        if [ "$_pass" != "admin" ] && _token=$(api_token "admin"); then
            warn "stored password did not work; the factory default did"
        else
            die "could not log in to the Technitium API - see /var/log/technitium.log"
        fi
    fi

    _lists=$(blocklist_urls "$MEDIUM_DIR/provision/config/blocklists.txt")
    _endpoints="${CLAIMED_IP}:53,127.0.0.1:53"

    curl -fsS -X POST "$TECHNITIUM_API/api/settings/set" \
        --data-urlencode "token=$_token" \
        --data-urlencode "enableBlocking=true" \
        --data-urlencode "blockListUrls=$_lists" \
        --data-urlencode "blockListUrlUpdateIntervalHours=24" \
        --data-urlencode "dnsServerLocalEndPoints=$_endpoints" \
        >/dev/null || die "could not apply Technitium settings"
    info "blocking enabled, listening on $_endpoints"
    info "blocklists: $_lists"

    if ! curl -fsS -X POST "$TECHNITIUM_API/api/settings/forceUpdateBlockLists" \
        --data-urlencode "token=$_token" >/dev/null 2>&1; then
        warn "could not force an immediate blocklist refresh; lists will update on schedule"
    else
        info "blocklist refresh triggered"
    fi

    # Rotate the factory password exactly once. The file's presence makes this
    # a no-op on re-runs.
    if [ ! -s "$CREDS_FILE" ]; then
        _new=$(random_password)
        if curl -fsS -X POST "$TECHNITIUM_API/api/user/changePassword" \
            --data-urlencode "token=$_token" \
            --data-urlencode "pass=$_new" >/dev/null 2>&1; then
            printf '%s\n' "$_new" > "$CREDS_FILE"
            chmod 0600 "$CREDS_FILE"
            info "admin password rotated and stored at $CREDS_FILE"
        else
            warn "could not rotate the admin password - it is still admin/admin!"
            warn "change it in the web console immediately."
        fi
    else
        info "admin password already rotated; leaving it alone"
    fi
}

persist() {
    log "Persisting configuration with lbu"
    # /opt is NOT in lbu's default include list. Without this, Technitium
    # disappears on the next reboot.
    lbu add /opt >/dev/null 2>&1 || warn "lbu add /opt reported a problem"
    lbu add "$CREDS_DIR" >/dev/null 2>&1 || warn "lbu add $CREDS_DIR reported a problem"
    info "tracking /opt and $CREDS_DIR"

    lbu commit -d || die "lbu commit failed - the configuration will NOT survive a reboot"
    info "committed to $MEDIUM_DIR"
}

report() {
    _pw="(unchanged - still admin/admin, change it now)"
    [ -s "$CREDS_FILE" ] && _pw=$(cat "$CREDS_FILE")

    cat <<REPORT

============================================================================
  dns-appliance is provisioned.
============================================================================

  DNS server      ${CLAIMED_IP}:53
  Web console     http://${CLAIMED_IP}:5380
  Admin user      admin
  Admin password  ${_pw}
                  (also stored at ${CREDS_FILE}, mode 0600)

  Verify it works:

      rc-status                       # dns-ip and technitium both started
      cat /run/dns-ip                 # the claimed address
      dig @${CLAIMED_IP} example.com          # resolves
      dig @${CLAIMED_IP} doubleclick.net      # should return 0.0.0.0
      reboot                          # then re-check the above

  IMPORTANT - this system is diskless and immutable. The OS runs from RAM and
  any change you make is lost on reboot unless you run:

      lbu commit -d

  That includes changes made through the Technitium web console. After
  changing settings there, run `lbu commit -d` or they will not survive.

============================================================================

REPORT
}

main() {
    require_root
    locate_medium
    setup_base
    install_packages
    install_technitium
    install_services
    start_services
    configure_technitium
    persist
    report
}

if [ "${ADS_SOURCE_ONLY:-0}" != "1" ]; then
    main "$@"
fi
```

Make it executable: `chmod +x provision.sh`

- [ ] **Step 4: Run the test to verify it passes**

Run: `sh tests/test_provision.sh`
Expected: PASS — `-- test_provision: 18 assertions, 0 failed`, exit 0.

- [ ] **Step 5: Run the whole suite**

Run: `./tests/run-tests.sh`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 6: Verify build-usb.sh now finds provision.sh**

Run: `sh -c 'ADS_SOURCE_ONLY=1 . ./build-usb.sh; [ -f "$REPO_DIR/provision.sh" ] && echo "provision.sh present"'`
Expected: `provision.sh present`

- [ ] **Step 7: Commit**

```bash
git add provision.sh tests/test_provision.sh
git commit -m "feat: add Alpine provisioner installing Technitium and both services"
```

---

### Task 6: README

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1–5. No code depends on this task.

- [ ] **Step 1: Write the README**

Create `README.md`. It must contain, at minimum, these sections with the stated content. Write it in full prose — this is user-facing documentation, not an outline.

**`# alpine-dns-stick`** — one-paragraph summary: a USB stick that boots any UEFI x86_64 machine into an immutable Technitium DNS resolver with ad-blocking, claiming a predictable address in the `.53`–`.59` range on whatever LAN it finds.

**`## Architecture`** — reproduce the ASCII diagram from the spec (`docs/superpowers/specs/2026-07-26-alpine-dns-stick-design.md`, "Architecture" section) showing the two phases and the runtime service chain.

**`## Why diskless and immutable`** — the OS loads into a tmpfs at boot; the USB is read at boot and written only by `lbu commit`. Pulling the plug cannot corrupt a running system; a compromised resolver is erased by a power cycle; the whole configuration is one auditable tarball. The cost: **any change not captured by `lbu commit -d` is lost on reboot**, including changes made in the Technitium web console.

**`## Usage`** — three numbered stages:
1. On macOS: `./build-usb.sh`. Describe the ISO cache in `downloads/`, the two-step disk confirmation, and that internal disks are refused outright.
2. Boot the target: UEFI enabled, Secure Boot **disabled**, USB first in boot order. Log in as `root` with no password.
3. On the appliance: `/media/<device>/provision/provision.sh`. It prints the claimed IP and generated admin password when it finishes.

**`## Verifying it works`** — the commands from `provision.sh`'s closing report: `rc-status`, `cat /run/dns-ip`, `dig @<ip> example.com`, `dig @<ip> doubleclick.net` expecting `0.0.0.0`, then `reboot` and re-check.

**`## Changing configuration later`** — editing settings in the web console at `http://<ip>:5380`, then `lbu commit -d`. Adding a package: `apk add <pkg>` then `lbu commit -d`. Adding a path outside lbu's defaults: `lbu add <path>` then `lbu commit -d`. Note that `/opt` is already tracked. `lbu status` shows what has changed since the last commit; `lbu diff` shows the detail.

**`## Troubleshooting`** — one subsection each:

- **`### GRUB prints "error: no such device"`** — Expected and harmless. `bootx64.efi` embeds `search --no-floppy --set=root --label "alpine-std 3.24.1 x86_64"`. That label is 24 characters and a FAT32 label caps at 11, so the search cannot match. `search` assigns `$root` only on success, so `$root` stays as the partition GRUB loaded from — the correct one — `$prefix` resolves to `/boot/grub` on the stick, and boot proceeds normally.

- **`### The appliance will not boot at all`** — This stick is UEFI-only. macOS has no `syslinux`, so no legacy/CSM bootloader is installed. Confirm UEFI boot is enabled and Secure Boot disabled. If the machine is CSM-only, build the stick on a Linux host with `setup-bootable`, or use the two-stick approach described under "Read-only stick".

- **`### "no IP available in .53-.59, refusing to start"`** — All seven candidate addresses answered ARP probes. This is deliberate: the appliance refuses to serve DNS rather than claim an address that belongs to something else. Free one of `.53`–`.59` on the LAN, or move the appliance to another subnet. Technitium will not have started — `need dns-ip` blocks it.

- **`### "DHCP discovery failed on eth0"`** — `dns-ip` uses DHCP only to learn the subnet and gateway; it releases the lease immediately afterwards. A failure means no DHCP server answered. Check the cable and switch. There is no static-configuration fallback by design: without knowing the subnet, no candidate address can be chosen safely.

- **`### arping variants and DAD exit codes`** — Two unrelated programs are called `arping`. This appliance requires **iputils**' arping, pinned to `20250605-r2`. In DAD mode (`-D`) it exits **0 when the address is free** (no replies) and **1 when it is in use**. Thomas Habets' `arping` package inverts this. If `apk add iputils-arping=20250605-r2` ever fails because the pin is gone, do not simply drop the pin — verify the new version's DAD exit codes with `man arping` first, because getting this backwards makes the appliance claim addresses that are already occupied.

- **`### .NET on musl`** — Alpine is musl, not glibc. Only Alpine's own `aspnetcore10-runtime` package works; Microsoft's downloadable .NET tarballs are glibc-linked and will not run. Technitium v15 requires .NET 10. `libmsquic` provides QUIC for DoQ and DoH3; `icu-libs` and `icu-data-full` provide globalisation, without which .NET needs `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` and Technitium misbehaves on internationalised domain names.

- **`### Read-only stick / "the stick is not writable"`** — `provision.sh` refuses to continue if it cannot write to the boot medium. This means the stick holds a read-only ISO9660 filesystem, which is what `dd`-ing the ISO produces, and `lbu commit` would have nowhere to persist. `build-usb.sh` never produces this. To recover from a `dd`'d stick, boot it and use a **second** USB stick: `apk add alpine-conf && setup-bootable /media/cdrom /dev/sdb`, which writes a writable FAT32 layout to the second stick. Reboot into that one and run `provision.sh` there.

- **`### Technitium admin password`** — Generated at provisioning and stored at `/etc/dns-appliance/admin-password` (mode 0600, tracked by lbu). If `provision.sh` warned that rotation failed, the credentials are still `admin`/`admin` — change them in the web console immediately, then run `lbu commit -d`.

- **`### Moving the stick to a different subnet`** — Supported. `dns-ip` re-discovers the subnet on every boot and claims a fresh address; `technitium`'s `start_post` re-applies the bind address when it changes. No manual step is needed.

**`## Repository layout`** — a table of the files from the "File Structure" section of this plan.

**`## Development`** — `./tests/run-tests.sh` runs the suite. It shellchecks every script when `shellcheck` is installed (`brew install shellcheck`) and skips that gate with a notice when it is not. Note the dialect per file: `build-usb.sh` is bash 3.2, everything else is POSIX sh. Note that scripts are sourced by their tests with `ADS_SOURCE_ONLY=1`, so no top-level side effects may be added.

- [ ] **Step 2: Verify every troubleshooting claim against the code**

Read `README.md` alongside the scripts and confirm each of these, fixing the README where it drifts:

Run: `grep -n 'no IP available in .53-.59, refusing to start' alpine/dns-ip.initd`
Expected: one match — the README quotes the error message exactly as the code emits it.

Run: `grep -n 'iputils-arping=20250605-r2' provision.sh README.md`
Expected: matches in both files, same version string.

Run: `grep -n 'aspnetcore10-runtime' provision.sh README.md`
Expected: matches in both files.

Run: `grep -c 'lbu commit -d' README.md`
Expected: at least 3 — persistence is stated in the usage, the configuration, and the troubleshooting sections.

- [ ] **Step 3: Run the whole suite one final time**

Run: `./tests/run-tests.sh`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 4: Confirm the repo is clean and complete**

Run: `git status --short && ls -R alpine config tests`
Expected: only `README.md` is untracked; `alpine/` holds both `.initd` files, `config/` holds `blocklists.txt`, `tests/` holds `assert.sh`, `run-tests.sh`, and four `test_*.sh` files. `downloads/` must NOT appear in `git status` — it is gitignored.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: add README covering architecture, usage, and troubleshooting"
```

---

## Self-Review Notes

Checked against `docs/superpowers/specs/2026-07-26-alpine-dns-stick-design.md`:

- Every spec section maps to a task. Boot mechanics → Task 4 (`grub_cfg_contents`, `mount_iso`, MBR formatting). `dns-ip` behaviour → Task 2. `technitium` interlock → Task 3. All nine `provision.sh` steps → Task 5. README contents → Task 6.
- The spec's "Failure modes" table is covered: checksum mismatch and internal-disk refusal are asserted in Task 4 Steps 4–5; DHCP failure, unparseable netmask, and address exhaustion are in Task 2 Step 3 with the exhaustion message asserted verbatim in Task 6 Step 2; API-unreachable and blocklist-refresh failures are in Task 5 Step 3.
- One spec requirement needed an addition not obvious from the spec prose: the 255-character `blockListUrls` limit is a hard API constraint, so `blocklist_urls` filters rather than truncates, and Task 5's test asserts both the skip and the warning.
- Naming is consistent across tasks: `DNS_IP_RUNFILE` is defined in Task 2 and consumed by Task 3; `TECHNITIUM_DIR` is defined identically in Tasks 3 and 5; `ADS_SOURCE_ONLY` guards both sourced scripts.
