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
