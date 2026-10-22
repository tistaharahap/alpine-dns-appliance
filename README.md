# alpine-dns-stick

`alpine-dns-stick` turns a USB stick into a portable, ad-blocking DNS
resolver: plug it into any UEFI x86_64 machine on any IPv4 LAN and it boots
Alpine Linux in diskless mode, runs [Technitium DNS
Server](https://technitium.com/dns/) under supervision, and claims a
predictable static address in the `.53`–`.59` range of whatever subnet it
finds — refusing to serve DNS at all rather than guess wrong.

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
│    technitium ─ dotnet DnsServerApp.dll, bound to $(cat /run/dns-ip)│
└────────────────────────────────────────────────────────────────┘
```

`build-usb.sh` runs once per stick, on a Mac. `provision.sh` runs once per
appliance, on the booted stick. Everything under "Runtime" then repeats,
unattended, on every subsequent power-on: `dns-ip` discovers the LAN and
claims an address before `technitium` is allowed to start at all, which is
the interlock that keeps this appliance from ever serving DNS from an
address nobody chose.

## Why diskless and immutable

Alpine's "diskless" boot mode loads the entire operating system into a
tmpfs (RAM-backed filesystem) at startup. From that point on, the USB stick
itself is not touched again until you explicitly ask Alpine to save your
changes with `lbu commit`, Alpine's tool for writing the running system's
tracked files back to the stick as a single compressed archive
(`apkovl.tar.gz`, `lbu` stands for "local backup"). Between boots the stick
is read exactly once — at boot, to load that archive back into the fresh
tmpfs — and written exactly when you tell it to.

This buys three things worth having on a box that lives on the edge of a
network, possibly unattended, possibly in a location you don't control:

- **Pulling the plug can't corrupt a running system.** There's no
  filesystem journal to replay on next boot because there was no live
  filesystem being written to in the first place — it was RAM.
- **A compromised resolver is erased by a power cycle.** Anything an
  attacker installs or edits at runtime lives in tmpfs and evaporates the
  moment the appliance restarts, unless it was captured by an explicit
  `lbu commit`.
- **The entire configuration is one auditable tarball.** `dns-appliance.apkovl.tar.gz`
  on the stick *is* the appliance's state. You can inspect it, diff it, or
  copy it to a fresh stick.

The cost, and it is a real one: **any change you make that isn't captured
by `lbu commit -d` is gone on the next reboot.** This includes changes made
through the Technitium web console — adjusting a setting there edits the
live, RAM-resident configuration, not the stick. If you forget to commit,
the appliance will quietly revert to its last-saved state at the next power
cycle. See "Changing configuration later" below for the commands, and
"Verifying it works" for how to prove a change actually stuck.

## Usage

### 1. Build the stick (on macOS)

```
./build-usb.sh
```

The script downloads `alpine-standard-3.24.1-x86_64.iso` into `downloads/`
at the repo root and verifies it against a pinned sha256 checksum before
using it. Downloads are cached: if a checksum-valid copy is already there,
`build-usb.sh` skips fetching it again, so re-running the builder (for a
second stick, or after a failed run) doesn't re-download the ISO. If a
cached file fails its checksum, it's deleted and re-fetched.

It then prints `diskutil list` and prompts for the identifier of the disk
to erase (e.g. `disk4`). Two safeguards apply before anything destructive
happens:

- **Internal disks are refused outright.** If `diskutil info -plist`
  reports the target as internal, or as not a whole disk, or as not
  ejectable, `build-usb.sh` aborts with the specific reason rather than
  proceeding. There is no override flag — an internal disk is never a
  legitimate target for this script.
- **You must type the disk identifier twice.** After the first identifier
  is validated, the script shows exactly what will be destroyed and asks
  you to type the same identifier again to confirm. A mismatch — including
  hitting Ctrl-D at either prompt — aborts with nothing changed.

Once confirmed, the disk is erased and formatted as a single FAT32
partition (MBR partition table, not GPT — see "The appliance will not boot
at all" below for why), then populated with Alpine's boot files, `grub.cfg`,
and this repo's `provision.sh`, `alpine/`, and `config/` directories under
`provision/`. After `sync`, the script re-reads the boot-critical files back
off the stick: the kernel, initramfs, and modloop files are checked against
the source ISO's sizes, while `bootx64.efi` and `.alpine-release` are
checked for presence only. It then declares success, ejects the disk, and
prints a checklist for what to do next.

### 2. Boot the target machine

Plug the stick into the machine that will become the appliance and, in its
firmware setup:

- **Enable UEFI boot.** This stick is UEFI-only; macOS has no tool to
  install a legacy/BIOS bootloader, so there is nothing for CSM/legacy mode
  to boot.
- **Disable Secure Boot.** Alpine's `bootx64.efi` is not signed by
  Microsoft, so Secure Boot will refuse to run it.
- **Put the USB stick first in the boot order.**

Boot it. Log in at the console as `root` — a fresh Alpine boot has no
password set on that account.

### 3. Provision the appliance

From the root shell on the booted appliance:

```
/media/<device>/provision/provision.sh
```

`<device>` is whatever the stick enumerated as — run `ls /media` if you're
not sure; it's typically something like `sda1`. The script installs
packages, fetches and installs Technitium, wires up the `dns-ip` and
`technitium` OpenRC services (OpenRC being Alpine's service manager, the
equivalent of systemd on most other distributions), configures Technitium
over its HTTP API, and persists everything with `lbu commit -d`. It is
idempotent: if it fails partway through (a flaky network fetching a
package, for instance), simply run it again — every step is written to
converge rather than to double-apply.

This relies on eth0 already having a DHCP lease when you run it — nothing in
this repo brings the interface up before that point. Alpine's live boot
image ships with `auto eth0` / `iface eth0 inet dhcp` in
`/etc/network/interfaces` by default, so that lease is already in place from
boot. `provision.sh` overwrites that file with a loopback-only one early on,
but the running lease survives for the rest of this run; only the *next*
reboot uses the new file, by which point the `dns-ip` service owns eth0
instead.

When it finishes, it prints a report with the claimed IP address, the
Technitium web console URL, and the admin password currently in effect —
freshly generated on a first run, or the previously stored one on a re-run
where it already authenticates. Write the password down; it's also saved on
the appliance itself (see "Technitium admin password" below).

## Verifying it works

Run these from the appliance's console right after provisioning, and again
after a `reboot` to confirm persistence actually worked:

```
rc-status                       # dns-ip and technitium should both be started
cat /run/dns-ip                 # the address dns-ip claimed
dig @<ip> example.com           # should resolve normally
dig @<ip> doubleclick.net       # should return 0.0.0.0 - blocked
reboot                          # then re-run the checks above
```

`<ip>` is the address `provision.sh` printed at the end, also visible any
time via `cat /run/dns-ip`. If the second `dig` doesn't come back
`0.0.0.0`, give the blocklist a few minutes to finish its first download,
or check `/var/log/technitium.log`.

If everything above still works identically after the `reboot`, the
appliance's configuration is durable. If it doesn't — most commonly a
setting you changed by hand in the web console instead of through
`provision.sh` — see "Changing configuration later".

## Changing configuration later

Because the appliance is diskless, **nothing you change at runtime survives
a reboot unless you explicitly commit it.**

- **Technitium settings** (blocklists, DNS options, users, anything in the
  web console at `http://<ip>:5380`): change it there, then from the
  appliance's console run:

  ```
  lbu commit -d
  ```

- **Installing another package:**

  ```
  apk add <pkg>
  lbu commit -d
  ```

- **Tracking a new file or directory that `lbu` doesn't watch by default:**

  ```
  lbu add <path>
  lbu commit -d
  ```

  `/opt` — where Technitium lives — is already tracked; `provision.sh` adds
  it (along with `/etc/dns-appliance` and both init scripts) during
  provisioning, so you don't need to add them again.

  One trap deserves its own warning: **`/etc/init.d` is excluded from `lbu`
  even though the rest of `/etc` is included.** apk's backup audit assumes
  init scripts come from packages, so a custom script placed there silently
  vanishes on reboot — leaving a runlevel symlink pointing at nothing and
  `rc-service: service '<name>' does not exist`. If you ever add your own
  service, `lbu add /etc/init.d/<name>` is mandatory, not optional.

Before committing, `lbu status` lists which tracked files have changed
since the last commit, and `lbu diff` shows the actual diff. Both are handy
for confirming a `lbu commit -d` is about to capture what you think it is,
or for noticing you forgot to make a change stick before it's too late.

## Troubleshooting

### "no such package" for everything, including curl

If `apk add` reports *every* package as missing — `curl` included, which lives
in Alpine's main repository and is always available — the problem is not the
packages. It means `/etc/apk/repositories` has no network mirror, only the
stick's local `/media/usb/apks`, which carries just enough to boot Alpine.

`provision.sh` now fails earlier and more clearly than this, at
`setup-apkrepos`. If you see it anyway, check connectivity in this order:

```
ip -4 addr show eth0        # should have a leased address
ip route show default       # should have a gateway
cat /etc/resolv.conf        # should have a nameserver
ping -c1 dl-cdn.alpinelinux.org
```

### Provisioning needs internet; the appliance afterwards does not

Alpine's standard ISO boots with **every network interface down**. Nothing
brings one up until you ask it to. `provision.sh` therefore takes out a
temporary DHCP lease on `eth0` before it installs anything, because the .NET
runtime and Technitium both have to be downloaded — the stick only carries
Alpine's boot packages.

That lease is deliberately not written into `/etc/network/interfaces`. It
lasts for the provisioning run only; from the next boot onward `dns-ip` owns
the interface and does its own discovery. So the appliance needs a working
DHCP server and internet access *while being provisioned*, and only a LAN
afterwards.

If your NIC does not enumerate as `eth0`, `provision.sh` stops and lists the
interfaces it found. Changing it means editing `PROVISION_IFACE` in
`provision.sh` **and** `DNS_IP_IFACE` in `alpine/dns-ip.initd` — both, or the
appliance will provision and then fail to claim an address.

### DNS answers from other machines, but 127.0.0.1 hangs on the appliance

If external `dig @<claimed-ip>` works while, on the appliance itself, `curl
http://127.0.0.1:5380/` (or `dig @127.0.0.1`) hangs, check the loopback
interface:

```
ip link show lo        # state DOWN means nothing ever brought it up
```

A live diskless boot enables Alpine's `networking` service in no runlevel,
so nothing runs `ifup lo`. With `lo` down there is no `127.0.0.0/8` route,
and traffic to `127.0.0.1` falls through to the *default* route — out
`eth0`, to the gateway, dropped. External service keeps working the whole
time, which makes this failure look like anything but what it is.

`provision.sh` brings `lo` up itself and enables `networking` in the boot
runlevel; `dns-ip` also raises it defensively at every start. If you hit
this on an appliance provisioned before that fix: `ip link set lo up`, then
`rc-update add networking boot`, then `lbu commit -d`.

### GRUB prints "error: no such device"

Expected and harmless. The stick's `bootx64.efi` (copied verbatim from the
Alpine ISO) embeds a boot script that starts with:

```
search --no-floppy --set=root --label "alpine-std 3.24.1 x86_64"
```

That label is 24 characters, and a FAT32 volume label is capped at 11, so
the search can never match anything on our stick. That's fine: GRUB's
`search` command only assigns `$root` on success. When it fails, `$root`
simply keeps its previous value — the partition GRUB was already loaded
from, which is the correct one — so `$prefix` still resolves to `/boot/grub`
on the stick, `grub.cfg` loads, and boot proceeds exactly as if the search
had never run. You'll see the error flash by on a plugged-in monitor; it is
not a fault.

### The appliance will not boot at all

This stick is UEFI-only by design: macOS ships no `syslinux` or equivalent,
so `build-usb.sh` has no way to install a legacy/CSM bootloader, and none is
present on the stick.

- Confirm UEFI boot is enabled in the target machine's firmware and Secure
  Boot is disabled.
- Confirm the USB stick is first in the boot order.
- If the target hardware is CSM/legacy-only with no UEFI boot mode at all,
  this stick cannot boot it. Build the stick on a Linux host instead, using
  Alpine's own `setup-bootable`, which can install a legacy bootloader — or
  use the two-stick approach described under "Read-only stick" below,
  substituting a Linux host for the recovery step.

### "no IP available in .53-.59, refusing to start"

All seven candidate addresses (`<subnet>.53` through `<subnet>.59`)
answered ARP duplicate-address-detection probes, meaning something else on
the LAN already holds every one of them. This is deliberate: the appliance
would rather refuse to serve DNS than steal an address that belongs to
another host. `technitium` never starts in this case — `dns-ip` fails,
and `technitium`'s `need dns-ip` dependency blocks it from starting at all.

To recover, free one of `.53`–`.59` on that subnet, or move the appliance
to a different one; `dns-ip` will retry on next boot (or via
`rc-service dns-ip restart`).

### "DHCP discovery failed on eth0"

`dns-ip` runs a DHCP client (`udhcpc`) purely to learn the subnet and
gateway it's plugged into — it releases the lease again immediately
afterwards and never keeps it. A failure here means no DHCP server answered
on `eth0` at all. Check the cable and the switch port.

There is deliberately no static-configuration fallback: without a DHCP
response, `dns-ip` has no way to learn the subnet, and without the subnet
it cannot safely choose which `.53`–`.59` candidate belongs to this LAN.
Guessing would risk claiming an address on the wrong network.

### arping variants and DAD exit codes

Two unrelated Linux utilities are both called `arping`. This appliance
requires **iputils'** `arping`, and `provision.sh` pins it to exactly
`iputils-arping=20250605-r2`. In duplicate-address-detection mode (`-D`),
this version exits **0 when the address is free** (no ARP replies were
received) and **1 when it's already in use** (a reply arrived). Thomas
Habets' unrelated `arping` package uses the opposite convention.

If `apk add iputils-arping=20250605-r2` ever fails because that exact
version has aged out of the Alpine repository, **do not simply drop the
version pin.** Check `man arping` for the replacement version's DAD exit
codes first. Getting this backwards makes `dns-ip` treat "an occupied
address" as free and claim it anyway — silently colliding with whatever
already holds it.

### .NET on musl

Alpine is built on musl libc, not glibc. Microsoft's official downloadable
.NET tarballs are linked against glibc and simply will not run here — the
only .NET runtime that works is Alpine's own `aspnetcore10-runtime`
package, which `provision.sh` installs from the community repository.
Technitium DNS Server v15 requires .NET 10, hence that specific package.

Two more packages ride along with it: `libmsquic` provides the QUIC
transport Technitium needs for DoQ and DoH3, and `icu-libs` plus
`icu-data-full` provide ICU globalisation data. Without ICU, .NET falls
back to invariant-globalization mode (`DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1`),
under which Technitium misbehaves on internationalised domain names.

### The boot medium is mounted read-only — this is normal

On a booted appliance, `/media/usb` is mounted **read-only**:

```
/dev/sda1 /media/usb vfat ro,relatime,...
```

That is Alpine's deliberate design, not a fault. Its stock `/etc/fstab`
carries `/dev/usbdisk /media/usb vfat noauto,ro`, and `lbu` remounts the
medium read-write only for the moments it is actually committing, then puts
it back. Keeping it read-only most of the time is what makes the appliance
tolerant of having its power cut — there is no window in which a write can
be interrupted mid-flight.

`provision.sh` remounts the medium read-write for the duration of its run
(it needs to write the apk cache) and restores read-only on exit, including
when it exits with an error. If a run is interrupted so violently that the
trap never fires, the stick is simply left writable; the next run puts it
back. You can also restore it by hand:

```
mount -o remount,ro /media/usb
```

### Read-only stick / "this stick cannot persist the appliance configuration"

`provision.sh` refuses to continue if the boot medium is an **ISO9660**
filesystem, which is permanently read-only and leaves `lbu commit` nowhere
to persist anything. That is what `dd`-ing the Alpine ISO directly onto a
drive produces. `build-usb.sh` never produces a stick like this; if you hit
this error, the stick in hand wasn't built with it.

Note the distinction from the section above: a `vfat` medium mounted `ro` is
fine and expected — `provision.sh` remounts it. Only `iso9660` is fatal. You
can tell which you have with:

```
grep /media/usb /proc/mounts
```

To recover a `dd`'d stick without re-imaging it, you need a **second** USB
stick:

1. Boot the `dd`'d stick as far as it will go (it can still boot Alpine
   live from the ISO9660 filesystem — it just can't persist anything).
2. Plug in the second, blank stick.
3. From the booted system:

   ```
   apk add alpine-conf
   setup-bootable /media/cdrom /dev/sdb
   ```

   (adjust `/dev/sdb` to whatever the second stick enumerated as). This
   writes a writable FAT32 layout — the same shape `build-usb.sh` produces
   — to the second stick.
4. Reboot into the second stick and run `provision.sh` from there.

### Technitium admin password

Generated during provisioning and stored at
`/etc/dns-appliance/admin-password`, mode `0600`, tracked by `lbu` so it
survives reboots once committed.

The rotation itself is written to survive being interrupted midway. Before
`provision.sh` ever calls Technitium's change-password API, it writes the
candidate password to `/etc/dns-appliance/admin-password.new`. Only after
the server confirms the change *and* the script successfully logs back in
with the new password does that file get renamed onto
`/etc/dns-appliance/admin-password`. Two things follow from that:

- If a run is interrupted between the API call succeeding and the rename
  happening, the new password is not lost — it's sitting in
  `/etc/dns-appliance/admin-password.new`. Re-running `provision.sh`
  detects and recovers it automatically on your behalf.
- If `provision.sh` prints a warning that rotation failed outright (as
  opposed to being interrupted), Technitium is still on the factory
  `admin` / `admin` credentials. Log in and change the password from the
  web console immediately, then run `lbu commit -d` so the fact that
  you're no longer on the default doesn't get lost either.

### Moving the stick to a different subnet

Supported, with no manual step required. `dns-ip` re-discovers the local
subnet fresh on every boot (it never trusts a previously-claimed address)
and claims whichever `.53`–`.59` candidate is free on the new LAN.
`technitium`'s `start_post` hook then re-applies that address as
Technitium's bind address whenever it differs from what's currently
configured, so the DNS server automatically follows the stick to its new
home.

## Repository layout

| File | Responsibility |
| --- | --- |
| `tests/assert.sh` | Assertion primitives and pass/fail counters. Sourced by every test file. |
| `tests/test_harness.sh` | Exercises `assert.sh` itself, including that a failing assertion is actually counted as a failure. |
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

Design rationale beyond what's captured here — including the reasoning
behind decisions like the FAT32 copy instead of `dd`, the explicit bind
address, and dropping `setup-alpine` in favor of individual `setup-*`
helpers — lives in
`docs/superpowers/specs/2026-07-26-alpine-dns-stick-design.md`.

## Development

```
./tests/run-tests.sh
```

runs the whole test suite: every `tests/test_*.sh` file, followed by a
shellcheck pass over every script when `shellcheck` is installed
(`brew install shellcheck` on macOS). If `shellcheck` isn't on `PATH`, that
gate is skipped with an explicit notice rather than silently passing —
`run-tests.sh` doesn't pretend a skipped check is a passed one.

A couple of things worth knowing before touching the scripts:

- **Dialect differs by file.** `build-usb.sh` targets macOS's stock bash
  3.2 (no bash 4+ features — no associative arrays, no `readarray`, and so
  on) and is shellchecked with `-s bash`. Everything else —
  `provision.sh`, `alpine/dns-ip.initd`, `alpine/technitium.initd`, and the
  test scripts — is POSIX `sh` / busybox `ash`, and is shellchecked with
  `-s sh`.
- **Scripts are sourced by their own tests**, with the environment variable
  `ADS_SOURCE_ONLY=1` set. `build-usb.sh` and `provision.sh` both guard
  their `main` entry point behind a check of that variable, so sourcing
  them for testing does not also run their destructive top-level flow. This
  means any new top-level code added to either script (outside a function
  definition or a plain variable assignment) will execute the instant a
  test file sources it — keep top-level statements limited to the
  established pattern.

## Releasing

Push a version tag:

```
git tag v1.0.0
git push origin v1.0.0
```

`.github/workflows/release.yml` then runs the test suite on a macOS runner
(without shellcheck, which the tree doesn't pass yet) and, if it passes, publishes a GitHub Release carrying
`alpine-dns-appliance-v1.0.0.tar.gz` and its `.sha256`. The tarball holds
exactly what `build-usb.sh` needs — `build-usb.sh`, `provision.sh`,
`alpine/`, `config/` — plus this README, so a user can download it, verify
it, extract it, and run `./build-usb.sh` without cloning the repo. A failing
test means no release; fix it, then delete and re-push the tag.

