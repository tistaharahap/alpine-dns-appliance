# alpine-dns-stick — Design

**Date:** 2026-07-26
**Status:** Approved

A two-phase builder that turns a USB stick into a portable, effectively immutable
Technitium DNS appliance running Alpine Linux in diskless mode. The appliance
claims a predictable static IP in the `.53`–`.59` range on whatever LAN it is
plugged into, and refuses to serve DNS if it cannot.

## Goals

- Plug the stick into any UEFI x86_64 machine on any IPv4 LAN and get an
  ad-blocking DNS resolver at a predictable address.
- OS runs from RAM; the on-disk state is a single `apkovl` written by `lbu commit`.
  Nothing else on the stick changes at runtime.
- Never serve DNS from an unintended address. No IP, no service.

## Non-goals

- Legacy BIOS / CSM boot. UEFI only (see "Boot mechanics").
- IPv6 address claiming.
- Multi-NIC. `eth0` only.
- Unattended re-provisioning. `provision.sh` is run by a human, once, and is
  re-runnable if it fails partway.

## Architecture

```
┌─ Phase 1: macOS ───────────────────────────────────────────────┐
│  ./build-usb.sh                                                │
│    downloads/alpine-standard-3.24.1-x86_64.iso  (cached)       │
│         │ sha256 verify                                        │
│         │ mount -t cd9660                                      │
│         ▼                                                      │
│    /dev/diskN  ── diskutil eraseDisk MS-DOS ALPINE MBR ──▶      │
│                   FAT32, writable                              │
│         ├── efi/boot/bootx64.efi     (from ISO)                │
│         ├── boot/{vmlinuz,initramfs,modloop}-lts               │
│         ├── boot/grub/grub.cfg       (ours, replaces ISO's)    │
│         ├── apks/x86_64/             (from ISO)                │
│         └── provision/{provision.sh,alpine/,config/}           │
└────────────────────────────────────────────────────────────────┘
                              │  boot target machine
                              ▼
┌─ Phase 2: booted Alpine (diskless, RAM) ───────────────────────┐
│  # /media/<dev>/provision/provision.sh                         │
│    apk: aspnetcore10-runtime libmsquic icu-libs                │
│         icu-data-full iputils-arping                           │
│    setup-lbu <dev> ; setup-apkcache /media/<dev>/cache         │
│    /opt/technitium  ← DnsServerPortable.tar.gz                 │
│    /etc/init.d/{dns-ip,technitium} → default runlevel          │
│    Technitium API: blocklists, bind address, admin password    │
│    lbu add /opt /etc/dns-appliance ; lbu commit -d             │
│         │                                                      │
│         ▼  writes                                              │
│    /media/<dev>/dns-appliance.apkovl.tar.gz                    │
└────────────────────────────────────────────────────────────────┘
                              │  every subsequent boot
                              ▼
┌─ Runtime ──────────────────────────────────────────────────────┐
│  OpenRC default runlevel                                       │
│    dns-ip      ─ DHCP discover → release → arping .53‥.59       │
│                  → claim → /run/dns-ip                         │
│         │ need                                                 │
│    technitium ─ dotnet DnsServer.dll, bound to $(cat /run/dns-ip)│
└────────────────────────────────────────────────────────────────┘
```

### Why diskless

Alpine's diskless mode loads the whole OS into a tmpfs at boot. The USB is read
only during boot and written only by `lbu commit`. Consequences we want: pulling
the plug can never corrupt a running system, a compromised resolver is erased by
a power cycle, and the stick's entire configuration is one auditable tarball.
The cost is that any change not captured by `lbu commit` is lost on reboot —
documented prominently in the README.

## Boot mechanics

These were verified against the real 3.24.1 ISO, not assumed.

The ISO root contains `.alpine-release`, `apks/x86_64/` (96 packages plus a
`.boot_repository` marker), `boot/{vmlinuz-lts,initramfs-lts,modloop-lts}`, and
`efi/boot/bootx64.efi`. Copying that tree onto a FAT32 partition reproduces
exactly the layout Alpine's own `setup-bootable` produces, so the initramfs
locates the boot repository with no extra kernel arguments.

**GRUB label search fails, harmlessly.** `bootx64.efi` embeds:

```
search --no-floppy --set=root --label "alpine-std 3.24.1 x86_64"
set prefix=($root)/boot/grub
```

That label is 24 characters; a FAT32 label is capped at 11, so the search cannot
succeed on our stick. This is benign: `search` assigns `$root` only on success,
so `$root` remains the partition GRUB was loaded from — ours — and `$prefix`
resolves to our `/boot/grub`, from which `grub.cfg` loads normally. A transient
`error: no such device` appears on the console at boot. This is expected
behaviour and is documented in the README rather than suppressed.

**macOS cannot auto-mount this ISO.** `hdiutil attach` reports "no mountable
file systems" because the hybrid MBR defeats its format detection. The verified
working sequence, which needs no `sudo`:

```
hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage <iso>
mount -t cd9660 -o rdonly /dev/diskN <mountpoint>
```

**MBR, not GPT.** `diskutil eraseDisk MS-DOS ALPINE MBR /dev/diskN` yields an
MBR type 0x0B/0x0C FAT32 partition. Some firmware only scans ESP-typed
partitions when the medium is GPT; MBR+FAT32 removable media is the path
essentially all UEFI firmware boots.

**Kernel cmdline.** We write our own `/boot/grub/grub.cfg` rather than copying
the ISO's, changing two things from the ISO default: `timeout=3` (from 1) and
dropping `quiet`, so that a headless appliance's boot failures are diagnosable
on a plugged-in monitor.

```
set timeout=3
menuentry "Alpine DNS appliance" {
    linux  /boot/vmlinuz-lts modules=loop,squashfs,sd-mod,usb-storage
    initrd /boot/initramfs-lts
}
```

## Components

| File | Dialect | Responsibility |
| --- | --- | --- |
| `build-usb.sh` | bash 3.2 (macOS) | ISO fetch/verify/cache, disk selection, format, copy, eject, checklist |
| `provision.sh` | busybox ash (POSIX) | One-shot Alpine setup; idempotent |
| `alpine/dns-ip.initd` | busybox ash | Subnet discovery and IP claiming |
| `alpine/technitium.initd` | busybox ash | Supervised DNS server, depends on `dns-ip` |
| `config/blocklists.txt` | data | One blocklist URL per line, `#` comments |
| `README.md` | — | Architecture, usage, troubleshooting |

`alpine/answers.txt` is deliberately absent — see "Decisions".

### `build-usb.sh`

Bash on macOS, `set -euo pipefail`, `trap` cleanup that unmounts the ISO and
detaches its ram-disk on any exit path.

Preflight: verify `diskutil`, `curl`, `shasum`, `python3`, `hdiutil`, and
`mount` are all present, failing with one combined message listing everything
missing rather than one at a time.

1. **Acquire ISO.** If `downloads/<iso>` exists and its sha256 matches the pinned
   constant, skip the download. Otherwise fetch from the CDN and verify. Mismatch
   aborts without touching any disk.
2. **Select target.** Print `diskutil list`. Prompt for an identifier. There is
   no default and an empty answer is rejected. Reject the target if
   `diskutil info -plist` reports `Internal: Yes` or `Removable Media: no`.
   Print the disk's size, name, and every volume that will be destroyed, then
   require the identifier to be typed a second time, exactly, to proceed.
3. **Format.** `diskutil unmountDisk force`, then
   `diskutil eraseDisk MS-DOS ALPINE MBR /dev/diskN`.
4. **Populate.** Mount the ISO per "Boot mechanics"; copy `efi/`, `boot/`,
   `apks/`, and `.alpine-release` to the stick; overwrite `boot/grub/grub.cfg`
   with ours; copy `provision.sh`, `alpine/`, and `config/` into
   `provision/` on the stick; create an empty `cache/` for apkcache.
5. **Finish.** `sync`, `diskutil eject`.
6. **Checklist.** Print a numbered end-user procedure: UEFI boot order and
   Secure Boot off, root login with no password, the exact `provision.sh`
   invocation, and what to expect afterwards.

`dd` is not used and not checked for. The brief listed it as a dependency
because the original plan flashed the ISO verbatim; the FAT32 layout replaces
that step entirely with `diskutil eraseDisk` plus a file copy, so a `dd`
dependency check would assert a requirement the script does not have.

Every destructive step is gated behind the two-step confirmation above.
Re-running the script is safe: it re-confirms every time.

### `provision.sh`

POSIX sh for busybox ash. Runs as root on the booted appliance. Every step is
convergent, so a re-run after a partial failure completes the job rather than
compounding it.

1. **Locate the boot medium.** Derive the device and mountpoint from where the
   script itself resides (`/media/<dev>/provision/`), so nothing is hardcoded.
   Abort with an explanation if the medium is not writable — that means the
   stick was built by some path other than `build-usb.sh`, and the README's
   `setup-bootable` recovery procedure applies.
2. **Base system.** `hostname dns-appliance` persisted to `/etc/hostname`;
   `setup-apkrepos` to enable the community repository (needed for
   `aspnetcore10-runtime`); `setup-apkcache /media/<dev>/cache`;
   `setup-lbu <dev>`.
3. **Packages.** `apk add aspnetcore10-runtime libmsquic icu-libs icu-data-full
   iputils-arping=20250605-r2`. The .NET runtime is Alpine's musl-native build;
   Microsoft's glibc tarball is never used.
4. **Technitium.** Download `DnsServerPortable.tar.gz` to `/opt/technitium`,
   recording its sha256 in `/etc/dns-appliance/technitium.sha256` for later
   comparison. The upstream URL is unversioned, so the checksum is observed at
   provision time rather than pinned in the script.
5. **Services.** Install both init scripts to `/etc/init.d/`, `chmod +x`,
   `rc-update add` to the default runlevel. `/etc/network/interfaces` is written
   with a loopback stanza only: `eth0` is deliberately absent, because `dns-ip`
   owns that interface end to end. This is what guarantees no DHCP client
   persists on `eth0` — there is no stanza for `networking` to act on, and
   nothing races `dns-ip` for the address.
6. **Technitium configuration.** Start `dns-ip` first and confirm `/run/dns-ip`
   is populated — provisioning cannot set a bind address before one is claimed,
   and a failure here is the same failure the appliance would hit at boot, so it
   is worth surfacing now. Then start `technitium` and poll `127.0.0.1:5380`
   until it answers or a timeout elapses, then via the HTTP API:
   `GET /api/user/login?user=admin&pass=admin` for a session token; then
   `POST /api/settings/set` with `enableBlocking=true`,
   `blockListUrls=<comma-joined from config/blocklists.txt>`,
   `blockListUrlUpdateIntervalHours=24`, and
   `dnsServerLocalEndPoints=<claimed-ip>:53,127.0.0.1:53`; then
   `POST /api/settings/forceUpdateBlockLists` (failure here is logged, not
   fatal). On a re-run, the stored password is used instead of `admin`.
7. **Credentials.** If `/etc/dns-appliance/admin-password` does not exist,
   generate a random password, apply it via `/api/user/changePassword`, and
   write it to that file mode 0600. The file's presence makes the step a no-op
   on re-runs. The password is printed prominently at the end of the script.
8. **Persist.** `lbu add /opt /etc/dns-appliance` — `/opt` is *not* in lbu's
   default include list and must be added explicitly, or Technitium vanishes on
   reboot. Then `lbu commit -d`.
9. **Report.** Print verification commands and a reminder that any future change
   requires `lbu commit -d` to survive a reboot.

### `alpine/dns-ip.initd`

OpenRC service. Provides the appliance's entire network configuration; nothing
else may configure `eth0`.

```
start():
  udhcpc -i eth0 -n -q -t 5 -s <lease-capture-script>
    │ fail → log "DHCP discovery failed on eth0"; return 1
    ▼
  capture $subnet (netmask) and $router from the lease
  prefix = mask_to_prefix($subnet)
    │ unparseable → prefix=24, log a warning naming the observed value
    ▼
  ip addr flush dev eth0          # release the DHCP address; discovery only
    ▼
  for OCTET in 53..59:
      arping -D -c 2 -w 3 -I eth0 $NET.$OCTET
      exit 0 → free   → claim it, break
      exit 1 → in use → next octet
    ▼
  claim: ip addr add $NET.$OCTET/$prefix dev eth0
         ip route add default via $router
         echo $NET.$OCTET > /run/dns-ip
    ▼
  exhausted → log "no IP available in .53-.59, refusing to start"; return 1
```

**arping exit-code semantics.** Pinned to `iputils-arping 20250605-r2`. In
duplicate-address-detection mode (`-D`), arping exits **0 when DAD succeeded —
that is, no replies were received and the address is free** — and **1 when a
reply arrived, meaning the address is in use**. This is inverted relative to
arping's non-DAD reachability modes and relative to Thomas Habets' unrelated
`arping` package, so the script states the expectation in a comment adjacent to
the check and the package version is pinned. A pinned version means a future
semantics change surfaces as an install failure rather than as an appliance that
silently claims an occupied address.

`stop()` flushes `eth0` and removes `/run/dns-ip`.

### `alpine/technitium.initd`

```
depend() { need dns-ip; after net; }
```

`need dns-ip` is the safety interlock: if `dns-ip` returns non-zero, OpenRC will
not start Technitium, satisfying the requirement that the appliance refuses to
serve DNS without a claimed address. `start_pre()` additionally asserts
`/run/dns-ip` exists and is non-empty.

Runs as a `supervise-daemon` process: `dotnet /opt/technitium/DnsServerApp.dll`
with `--start` semantics, working directory `/opt/technitium`, restarting on
crash. The bind address is read from `/run/dns-ip` and applied through the
settings API when it differs from what Technitium already has stored, so moving
the stick to a different subnet re-binds automatically.

## Pinned external facts

Verified live on 2026-07-26. Each lives in a variable at the top of the script
that uses it.

| Thing | Value | Note |
| --- | --- | --- |
| Alpine | `3.24.1`, `alpine-standard-3.24.1-x86_64.iso` | released 2026-06-13 |
| ISO sha256 | `f4dd613206676c62949144c8ad75fc64582099f444dd1485bae104a60f51dd26` | confirmed by downloading and hashing |
| Technitium | v15.4, `https://download.technitium.com/dns/DnsServerPortable.tar.gz` | URL is unversioned; checksum observed at provision time |
| .NET | `aspnetcore10-runtime` (Alpine community, 10.0.10-r0) | Technitium v15 moved to .NET 10; musl-native |
| Support pkgs | `libmsquic`, `icu-libs`, `icu-data-full` | QUIC transports and ICU globalisation |
| arping | `iputils-arping=20250605-r2` (Alpine main) | DAD exit codes as documented above |
| Blocklist seed | StevenBlack `hosts` | `config/blocklists.txt` |

## Failure modes

| Condition | Behaviour |
| --- | --- |
| ISO checksum mismatch | Abort before any disk is touched |
| Target is an internal disk | Refuse; do not offer an override |
| Confirmation typed incorrectly | Abort |
| DHCP discovery fails | `dns-ip` logs the reason, exits 1; Technitium never starts |
| Netmask unparseable | Assume /24, log a warning naming the observed value, continue |
| All of `.53`–`.59` occupied | Log "no IP available in .53-.59, refusing to start", exit 1 |
| Technitium API unreachable during provision | Retry until timeout, then fail loudly with the service log location |
| Blocklist force-update fails | Log and continue; lists refresh on their own schedule |

## Decisions

**FAT32 copy over `dd`.** A `dd`-flashed ISO is read-only ISO9660, so
`lbu commit` has nowhere to write and the appliance cannot persist anything.
Copying the ISO tree onto a FAT32 partition makes the entire stick writable and
matches what `setup-bootable` produces. The trade-off is UEFI-only booting,
since macOS has no `syslinux` with which to install a legacy MBR bootloader;
the target hardware is UEFI, so this cost is not paid.

**No HTTP-server fallback.** The brief allowed serving `provision.sh` over
`python3 -m http.server` if partitioning failed. With the FAT32 layout the
provision files simply ride on the stick, so the fallback has no remaining
purpose and is dropped. `python3` remains a preflight-checked dependency
because it is used for plist parsing during disk validation.

**No `setup-alpine` / `answers.txt`.** `setup-alpine` targets a disk install and
performs considerably more than this appliance needs, and it is not cleanly
re-runnable. `provision.sh` instead calls the specific `setup-*` helpers it
wants — `setup-apkrepos`, `setup-apkcache`, `setup-lbu` — which are individually
non-interactive and idempotent.

**Randomised admin password.** An appliance sitting on a LAN with `admin/admin`
is indefensible. The password is generated, applied through the API, stored at
`/etc/dns-appliance/admin-password` (0600, lbu-tracked), and printed at the end
of provisioning.

**Explicit bind address.** Technitium binds to the address in `/run/dns-ip`
rather than `0.0.0.0`. Functionally near-identical given a single-address
`eth0`, but it makes the claimed address visible in the web console and means a
misconfigured interface surfaces as a bind failure instead of silent
all-interfaces service.

## Verification

`build-usb.sh` and `provision.sh` are operator-run and destructive or
environment-dependent, so the checks are:

- `shellcheck -s bash build-usb.sh` and `shellcheck -s sh provision.sh
  alpine/*.initd` are clean, with any suppressions carrying an inline reason.
- `build-usb.sh` preflight and disk-validation logic exercised with a
  non-existent and an internal disk identifier, confirming refusal in both cases.
- The ISO mount/copy path exercised against a disk image rather than physical
  hardware where practical.
- End-to-end boot and provisioning is a manual step performed by the operator;
  README carries the checklist of what to verify (claimed address in
  `/run/dns-ip`, `rc-status` showing both services, a `dig @<ip>` resolving, a
  known-ad domain returning `0.0.0.0`, and persistence across a reboot).

## README contents

Architecture diagram and the two-phase flow; why diskless and what that implies
for making changes; full usage; and troubleshooting covering the GRUB label
error, arping variants and DAD exit codes, .NET-on-musl caveats, the
`setup-bootable` recovery path for a stick that is not writable, changing
persisted configuration with `lbu`, and what to do when all seven addresses are
occupied.
