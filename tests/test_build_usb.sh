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

# --- same_size ---------------------------------------------------------------
printf 'hello' > "$_tmp/same_a"
printf 'world' > "$_tmp/same_b"
same_size "$_tmp/same_a" "$_tmp/same_b"; assert_rc 0 $? "same_size accepts two files of equal size"
printf 'hello there' > "$_tmp/same_c"
same_size "$_tmp/same_a" "$_tmp/same_c"; assert_rc 1 $? "same_size rejects files of differing size"
same_size "$_tmp/same_a" "$_tmp/absent"; assert_rc 1 $? "same_size rejects a missing file"

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
