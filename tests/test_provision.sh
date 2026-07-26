#!/bin/sh
# Exercises the pure logic in provision.sh. Nothing here touches apk or a network.
set -u
. "$(dirname "$0")/assert.sh"

ADS_SOURCE_ONLY=1
export ADS_SOURCE_ONLY
# shellcheck disable=SC1091  # sourced for its functions, main() is guarded
. "$(dirname "$0")/../provision.sh"

_tmp=$(mktemp -d)
# Normalize physically up front: boot_medium_dir now resolves with pwd -P
# (Finding 5), and on macOS $TMPDIR itself is reached through a symlink
# (/tmp -> /private/tmp). Without this, every boot_medium_dir assertion
# below would compare a physical path against a symlinked one.
_tmp=$(cd "$_tmp" && pwd -P)
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

# A symlinked mount point must resolve to the real device directory, not the
# symlink's own name - that name is what gets passed to setup-lbu.
mkdir -p "$_tmp/real/sdb1/provision"
: > "$_tmp/real/sdb1/provision/provision.sh"
ln -s "$_tmp/real/sdb1" "$_tmp/media/symlinked-mount"
assert_eq "$_tmp/real/sdb1" \
    "$(boot_medium_dir "$_tmp/media/symlinked-mount/provision/provision.sh")" \
    "boot_medium_dir resolves physically through a symlinked mount point"
assert_eq "sdb1" \
    "$(lbu_media_name "$(boot_medium_dir "$_tmp/media/symlinked-mount/provision/provision.sh")")" \
    "lbu_media_name yields the real device name, not the symlink's name"

assert_eq "sda1" "$(lbu_media_name "$_tmp/media/sda1/")" \
    "lbu_media_name strips a trailing slash before taking the basename"

# --- medium_fstype / medium_is_ro -------------------------------------------
# Alpine's diskless mode mounts the boot medium READ-ONLY on purpose
# (/etc/fstab ships `/dev/usbdisk /media/usb vfat noauto,ro`), and lbu remounts
# it rw only for the duration of a commit. So "can I write to it right now" is
# the wrong question - the right one is "what filesystem is it, and can it be
# remounted rw". The first line below is copied verbatim from a real appliance.
cat > "$_tmp/mounts" <<'MOUNTS'
/dev/sda1 /media/usb vfat ro,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=utf8,shortname=mixed,errors=remount-ro 0 0
/dev/sdb1 /media/writable vfat rw,relatime 0 0
/dev/sr0 /media/cdrom iso9660 ro,relatime 0 0
/dev/sdc1 /media/tricky vfat rw,relatime,errors=remount-ro 0 0
MOUNTS
PROC_MOUNTS="$_tmp/mounts"

assert_eq "vfat" "$(medium_fstype /media/usb)" "medium_fstype reads the type of a ro vfat medium"
assert_eq "iso9660" "$(medium_fstype /media/cdrom)" "medium_fstype identifies a dd'd ISO medium"
medium_fstype /media/not-mounted >/dev/null 2>&1
assert_rc 1 $? "medium_fstype fails when the mountpoint is not mounted"

medium_is_ro /media/usb
assert_rc 0 $? "medium_is_ro detects the read-only boot medium"
medium_is_ro /media/writable
assert_rc 1 $? "medium_is_ro returns false for an rw medium"

# `errors=remount-ro` contains the substring "ro" and appears on the real
# appliance's mount line. Matching options as substrings rather than as whole
# comma-separated fields would call every such mount read-only.
medium_is_ro /media/tricky
assert_rc 1 $? "medium_is_ro is not fooled by errors=remount-ro on an rw mount"

# --- parse_link_names -------------------------------------------------------
# Alpine's live ISO leaves every interface down, so provision.sh has to bring
# one up itself before apk can reach a mirror. This parses `ip -o link show`
# to report what the machine actually has, which is what makes the error
# actionable when eth0 is not the name in use.
assert_eq "eth0" "$(parse_link_names <<'LINKS'
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP mode DEFAULT group default qlen 1000
LINKS
)" "parse_link_names returns the non-loopback interface"

assert_eq "enp3s0
wlan0" "$(parse_link_names <<'LINKS'
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT
2: enp3s0: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN mode DEFAULT
3: wlan0: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN mode DEFAULT
LINKS
)" "parse_link_names lists every non-loopback interface, one per line"

assert_eq "" "$(parse_link_names <<'LINKS'
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT
LINKS
)" "parse_link_names yields nothing when only loopback exists"

# An @-suffixed name (VLAN, veth peer) must lose the peer part.
assert_eq "eth0" "$(parse_link_names <<'LINKS'
2: eth0@if7: <BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state UP mode DEFAULT
LINKS
)" "parse_link_names strips an @peer suffix from the interface name"

# --- random_password --------------------------------------------------------
_pw=$(random_password)
assert_eq "24" "$(printf '%s' "$_pw" | wc -c | tr -d ' ')" "random_password is 24 characters"
assert_eq "" "$(printf '%s' "$_pw" | tr -d 'A-Za-z0-9')" "random_password is alphanumeric only"

# Two consecutive calls must differ. A generator stuck on a constant would
# silently give every appliance the same admin password.
_pw_a=$(random_password)
_pw_b=$(random_password)
assert_not_contains "$_pw_a" "$_pw_b" "random_password output varies between calls"

# --- valid_ipv4 --------------------------------------------------------------
valid_ipv4 "192.168.1.54" >/dev/null 2>&1
assert_rc 0 $? "valid_ipv4 accepts a normal address"
valid_ipv4 "10.0.0.59" >/dev/null 2>&1
assert_rc 0 $? "valid_ipv4 accepts another normal address"
valid_ipv4 "192.168.1.999" >/dev/null 2>&1
assert_rc 1 $? "valid_ipv4 rejects an out-of-range octet"
valid_ipv4 "192.168.1" >/dev/null 2>&1
assert_rc 1 $? "valid_ipv4 rejects too few components"
valid_ipv4 "192.168.1.1.1" >/dev/null 2>&1
assert_rc 1 $? "valid_ipv4 rejects too many components"
valid_ipv4 "" >/dev/null 2>&1
assert_rc 1 $? "valid_ipv4 rejects an empty string"
valid_ipv4 "192.168.1.abc" >/dev/null 2>&1
assert_rc 1 $? "valid_ipv4 rejects a non-numeric octet"
valid_ipv4 "192.168.1.54 " >/dev/null 2>&1
assert_rc 1 $? "valid_ipv4 rejects an address with trailing whitespace"

# --- lbu_list_entry ----------------------------------------------------------
assert_eq "opt" "$(lbu_list_entry "/opt")" \
    "lbu_list_entry strips the leading slash from /opt"
assert_eq "etc/dns-appliance" "$(lbu_list_entry "$CREDS_DIR")" \
    "lbu_list_entry matches CREDS_DIR for the lbu include-list check"

test_summary "test_provision"
