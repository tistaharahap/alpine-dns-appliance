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
# A password rotation writes here FIRST, before it is ever sent to the
# server. If the script dies between the API call succeeding and the
# credentials file being updated, this pending file is what makes the new
# password recoverable on the next run instead of lost forever.
CREDS_PENDING="$CREDS_FILE.new"
BLOCKLIST_MAX_URL_LEN=255

# The interface provisioning brings up temporarily to reach the package
# mirrors. Must match DNS_IP_IFACE in alpine/dns-ip.initd, which owns this
# interface once the appliance is running.
PROVISION_IFACE="${PROVISION_IFACE:-eth0}"

# Transport for the upstream forwarders in config/forwarders.txt.
# Valid values per Technitium's API: Udp, Tcp, Tls, Https, Quic.
# Https (DNS-over-HTTPS) is the default because it survives the port-53
# interception that is common on consumer ISP links. If you replace the
# forwarder URLs with plain IP addresses, set this to Udp.
FORWARDER_PROTOCOL="${FORWARDER_PROTOCOL:-Https}"

# Used only if config/forwarders.txt is missing, e.g. a stick built before
# that file existed. The file is the real source of truth.
#
# IP literals, deliberately. Technitium resolves a forwarder's hostname with
# its own resolver, which is pointed at the endpoint being resolved - circular,
# and it fails closed. Verified on Alpine against Technitium 15.4:
# cloudflare-dns.com -> SERVFAIL, 1.1.1.1 -> NOERROR.
DEFAULT_FORWARDERS="https://1.1.1.1/dns-query,https://1.0.0.1/dns-query,https://9.9.9.9/dns-query"

# OpenRC sources this before alpine/technitium.initd. Writing the forwarders
# here means Technitium has them on its FIRST start, which matters because its
# environment-variable config is only read while config/dns.config is absent.
TECHNITIUM_CONFD="/etc/conf.d/technitium"

# Overridable so the test suite can feed a fixture instead of the live kernel.
PROC_MOUNTS="${PROC_MOUNTS:-/proc/mounts}"

# Set to 1 by locate_medium if it remounted the boot medium read-write, so the
# exit trap can put it back the way Alpine intended.
MEDIUM_REMOUNTED_RW=0

# Alpine's musl-native .NET. Microsoft's glibc build will not run here.
# iputils is pinned so that a change in arping's DAD exit-code semantics
# fails at install time rather than silently claiming an occupied address.
APK_PACKAGES="aspnetcore10-runtime libmsquic icu-libs icu-data-full iputils-arping=20250605-r2 curl"

# ------------------------------------------------------------------ logging --
#
# log() and info() record where we are as a side effect. Under `set -e` a
# command failing in an unguarded spot terminates the script with no output
# whatsoever - which is exactly how this script died on real hardware, leaving
# an operator staring at an OpenRC line that had nothing to do with it. The
# EXIT trap turns that silence into a located failure.
CURRENT_STEP="startup"
CURRENT_DETAIL=""
PROVISION_COMPLETE=0

log()  { CURRENT_STEP="$*"; CURRENT_DETAIL=""; printf '\n==> %s\n' "$*"; }
info() { CURRENT_DETAIL="$*"; printf '    %s\n' "$*"; }
warn() { printf '/!\\ %s\n' "$*" >&2; }
die()  { printf 'ERR %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------ pure helpers ---

# Join the non-comment, non-blank lines of file $1 with commas.
# $2 caps entry length, skipping longer ones with a warning; 0 means no cap.
comma_list() {
    _max="${2:-0}"
    _out=""
    while IFS= read -r _line || [ -n "$_line" ]; do
        _line="${_line%%#*}"
        _line=$(printf '%s' "$_line" | tr -d '[:space:]')
        [ -n "$_line" ] || continue
        if [ "$_max" -gt 0 ] && [ "${#_line}" -gt "$_max" ]; then
            warn "skipping entry over $_max chars: $(printf '%s' "$_line" | cut -c1-40)..."
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

# Blocklist URLs are capped at 255 characters: /api/settings/set rejects the
# entire request if one entry is longer, so an over-length URL is skipped with
# a warning rather than silently breaking blocking altogether.
blocklist_urls() {
    comma_list "$1" "$BLOCKLIST_MAX_URL_LEN"
}

# Forwarders are not length-capped: the 255-char limit is a blockListUrls
# constraint, and silently dropping a forwarder would send queries somewhere
# other than where the operator asked.
forwarder_urls() {
    comma_list "$1" 0
}

# /media/sda1/provision/provision.sh -> /media/sda1
# Resolves physically (pwd -P): if the mount point is reached through a
# symlink, "pwd" alone would yield the symlink's own name rather than the
# real device directory, and that name is what gets passed to setup-lbu.
boot_medium_dir() {
    _dir=$(cd "$(dirname "$1")/.." 2>/dev/null && pwd -P) || return 1
    printf '%s\n' "$_dir"
}

# /media/sda1 -> sda1, /media/sda1/ -> sda1
lbu_media_name() {
    _dir="$1"
    while [ "${_dir%/}" != "$_dir" ]; do
        _dir="${_dir%/}"
    done
    printf '%s\n' "${_dir##*/}"
}

random_password() {
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24
}

# Echo every non-loopback interface name from `ip -o link show` on stdin, one
# per line. Names may carry an @peer suffix (VLANs, veth) which is not part of
# the interface name.
parse_link_names() {
    while IFS= read -r _line; do
        _name="${_line#*: }"
        _name="${_name%%:*}"
        _name="${_name%%@*}"
        [ -n "$_name" ] || continue
        [ "$_name" = "lo" ] && continue
        printf '%s\n' "$_name"
    done
}

# Echo the filesystem type mounted at $1, or return 1 if nothing is mounted
# there. Fields in /proc/mounts are: device mountpoint fstype options ...
medium_fstype() {
    _want="$1"
    while read -r _dev _mnt _type _opts _rest; do
        if [ "$_mnt" = "$_want" ]; then
            printf '%s\n' "$_type"
            return 0
        fi
    done < "$PROC_MOUNTS"
    return 1
}

# Return 0 if the mount at $1 is read-only.
#
# The options must be split on commas and compared whole. A substring match
# would be wrong: a real appliance's boot medium carries
# `errors=remount-ro`, which contains "ro" while saying nothing about the
# mount's current state.
medium_is_ro() {
    _want="$1"
    while read -r _dev _mnt _type _opts _rest; do
        [ "$_mnt" = "$_want" ] || continue
        _oifs="$IFS"
        IFS=,
        for _opt in $_opts; do
            if [ "$_opt" = "ro" ]; then
                IFS="$_oifs"
                return 0
            fi
        done
        IFS="$_oifs"
        return 1
    done < "$PROC_MOUNTS"
    return 1
}

# Validate that $1 is a dotted-quad IPv4 address: four dot-separated numeric
# components, each 0-255, digits only. Rejects whitespace-only content,
# leading/trailing whitespace, and embedded newlines, since a run file
# corrupted or hand-edited must not flow straight into a curl URL or a DNS
# bind address. Mirrors alpine/technitium.initd's valid_ipv4(), so the two
# independent scripts stay consistent for the next reader.
valid_ipv4() {
    case "$1" in
        *.*.*.*.*) return 1 ;;
        *.*.*.*) ;;
        *) return 1 ;;
    esac

    _rest="$1"
    _o1="${_rest%%.*}"
    _rest="${_rest#*.}"
    _o2="${_rest%%.*}"
    _rest="${_rest#*.}"
    _o3="${_rest%%.*}"
    _o4="${_rest#*.}"

    set -- "$_o1" "$_o2" "$_o3" "$_o4"
    for _octet in "$@"; do
        case "$_octet" in
            ''|*[!0-9]*) return 1 ;;
        esac
        if [ "$_octet" -gt 255 ]; then
            return 1
        fi
    done

    return 0
}

# Strip a leading slash so a path matches the format lbu's include list uses
# in /etc/apk/protected_paths.d/lbu.list ("+opt", not "+/opt").
lbu_list_entry() {
    printf '%s\n' "${1#/}"
}

# Extract a top-level "key":"value" string field from a small JSON response
# file. Not a general JSON parser - only matches the flat shape the
# Technitium API actually emits. sed/grep only; jq is not available on a
# minimal Alpine image. Mirrors alpine/technitium.initd's json_field(), so
# the two independent scripts stay consistent for the next reader.
json_field() {
    sed -n 's/.*"'"$2"'":"\([^"]*\)".*/\1/p' "$1" 2>/dev/null
}

# Judge an API response by its body, not by curl's exit code: Technitium
# returns HTTP 200 with {"status":"error","errorMessage":"..."} for
# application-level failures (e.g. a stale token or a rejected setting),
# which "curl -fsS" treats as success since the transport itself succeeded.
# Mirrors alpine/technitium.initd's api_ok().
api_ok() {
    [ -f "$1" ] || return 1
    [ "$(json_field "$1" status)" = "ok" ]
}

# Log in to the Technitium API and echo a session token.
# Credentials are sent with `curl -G --data-urlencode`, not interpolated into
# the URL query string: a password containing &, #, +, or a space would be
# corrupted or truncated in transit otherwise, failing auth with no clear
# cause. Mirrors the login call in alpine/technitium.initd's start_post().
api_token() {
    _resp="/tmp/technitium-login.json"
    curl -fsS --connect-timeout 5 --max-time 20 -G "$TECHNITIUM_API/api/user/login" \
        --data-urlencode "user=admin" \
        --data-urlencode "pass=$1" \
        >"$_resp" 2>/dev/null

    if ! api_ok "$_resp"; then
        rm -f "$_resp"
        return 1
    fi

    _tok=$(json_field "$_resp" token)
    rm -f "$_resp"
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

    # Alpine's diskless mode mounts the boot medium READ-ONLY on purpose - its
    # stock /etc/fstab carries `/dev/usbdisk /media/usb vfat noauto,ro` - and
    # lbu remounts it rw only for the duration of a commit. So "is it writable
    # right now" is the wrong question and would reject a perfectly good stick.
    # What actually matters is the filesystem: ISO9660 can never persist
    # anything, vfat can once remounted.
    _fstype=$(medium_fstype "$MEDIUM_DIR") \
        || die "nothing is mounted at $MEDIUM_DIR - cannot locate the boot medium"
    info "filesystem is $_fstype"

    if [ "$_fstype" = "iso9660" ]; then
        die "$MEDIUM_DIR is an ISO9660 filesystem, which is permanently read-only.

This stick cannot persist the appliance configuration. It was not built by
build-usb.sh - most likely the ISO was dd'd onto it. See the 'Read-only stick'
section of README.md for the setup-bootable recovery procedure."
    fi

    # Hold the medium rw for the whole run: setup-apkcache writes to it, and
    # the exit trap puts it back to ro so an unexpected power cut cannot
    # corrupt the stick.
    if medium_is_ro "$MEDIUM_DIR"; then
        mount -o remount,rw "$MEDIUM_DIR" \
            || die "could not remount $MEDIUM_DIR read-write.

The medium is $_fstype, so it should be writable. A stick that refuses to
remount rw is usually failing, or has its physical write-protect switch on."
        MEDIUM_REMOUNTED_RW=1
        info "remounted read-write for provisioning (restored to read-only at the end)"
    else
        info "already mounted read-write"
    fi
}

# Single EXIT handler: restore the medium, and if we are leaving early, say
# where from. A bare `set -e` death prints nothing at all on its own.
on_exit() {
    _rc=$?
    restore_medium_ro
    if [ "$PROVISION_COMPLETE" != "1" ]; then
        printf '\n' >&2
        printf 'ERR provisioning did not finish.\n' >&2
        printf '    step:      %s\n' "$CURRENT_STEP" >&2
        [ -n "$CURRENT_DETAIL" ] && printf '    last note: %s\n' "$CURRENT_DETAIL" >&2
        printf '    exit code: %s\n' "$_rc" >&2
        printf '\n' >&2
        printf '    If nothing above explains it, a command failed where `set -e`\n' >&2
        printf '    terminates the script silently. Re-run with tracing to see the\n' >&2
        printf '    exact last command:\n' >&2
        printf '        sh -x %s >/tmp/prov.log 2>&1; tail -40 /tmp/prov.log\n' "$0" >&2
    fi
    return 0
}

# Put the boot medium back to read-only if we remounted it. Runs on every exit
# path, including failures, so an aborted run does not leave the stick writable.
restore_medium_ro() {
    if [ "$MEDIUM_REMOUNTED_RW" = "1" ]; then
        sync
        mount -o remount,ro "$MEDIUM_DIR" 2>/dev/null \
            && MEDIUM_REMOUNTED_RW=0
    fi
}

# Bring up a temporary DHCP lease so apk can reach a mirror.
#
# Alpine's standard ISO boots with every interface down - it expects you to
# run setup-alpine or ifup by hand - so nothing here has a network until we
# make one. This has to happen before setup-apkrepos and apk, and it is
# deliberately NOT written into /etc/network/interfaces: the lease lives only
# for this run, and on the next boot dns-ip owns the interface instead.
setup_network() {
    log "Bringing up the network for provisioning"

    # A live diskless boot has the `networking` service enabled in no runlevel,
    # so nothing has brought up the loopback interface: lo sits state DOWN.
    # Everything addressed to 127.0.0.1 then falls through to the DEFAULT
    # route - out eth0, to the gateway, dropped - so the Technitium readiness
    # probe and every settings API call hang or time out while external
    # queries to the claimed address keep working. Observed exactly this on
    # real hardware.
    ip link set lo up || die "could not bring up the loopback interface"
    info "loopback up"

    if ! ip link show "$PROVISION_IFACE" >/dev/null 2>&1; then
        _found=$(ip -o link show 2>/dev/null | parse_link_names | tr '\n' ' ')
        die "no interface named $PROVISION_IFACE on this machine.

Interfaces present: ${_found:-<none>}

The appliance's dns-ip service is written against $PROVISION_IFACE. If your
NIC enumerates under a different name, that name has to be set in both
alpine/dns-ip.initd (DNS_IP_IFACE) and this script (PROVISION_IFACE) before
the appliance will work."
    fi

    ip link set "$PROVISION_IFACE" up 2>/dev/null

    if ip route show default 2>/dev/null | grep -q .; then
        info "$PROVISION_IFACE already has a default route; leaving it alone"
        return 0
    fi

    info "requesting a DHCP lease on $PROVISION_IFACE (temporary, for provisioning only)"
    if ! udhcpc -i "$PROVISION_IFACE" -q -n -t 5 >/dev/null 2>&1; then
        die "DHCP failed on $PROVISION_IFACE - provisioning needs internet access.

apk has to download the .NET runtime and Technitium from the network; the
packages on the stick are only enough to boot Alpine. Check the cable, the
switch, and that a DHCP server is reachable, then run this script again."
    fi

    _addr=$(ip -4 -o addr show "$PROVISION_IFACE" 2>/dev/null | awk '{print $4}' | head -1)
    [ -n "$_addr" ] || die "udhcpc reported success but $PROVISION_IFACE has no address"
    info "leased $_addr"
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

    # That interfaces file is only read by the `networking` service - and on a
    # live diskless boot that service is enabled in NO runlevel, which is how
    # this appliance ran with loopback permanently down. Enable it so lo comes
    # up on every boot. eth0 stays absent from the file, so dns-ip still owns
    # it unchallenged. rc-update exits non-zero if the service is already
    # enabled, so the symlink is the source of truth, same as install_services.
    rc-update add networking boot >/dev/null 2>&1 || true
    [ -e /etc/runlevels/boot/networking ] \
        || die "could not enable the networking service - loopback would stay DOWN on every reboot"
    info "networking service enabled in the boot runlevel (brings up lo)"

    # Fatal, not a warning. Without a mirror, /etc/apk/repositories holds only
    # the stick's local /media/usb/apks - enough to boot Alpine and nothing
    # else - and every apk add later fails with a baffling "no such package"
    # for staples like curl. Failing here says what actually went wrong.
    setup-apkrepos -c -1 >/dev/null 2>&1 \
        || die "setup-apkrepos failed - could not add an Alpine mirror.

Without it, apk only has the stick's local package set, which cannot supply
the .NET runtime. This usually means no internet access or no DNS. Check:

    ip -4 addr show $PROVISION_IFACE
    ip route show default
    cat /etc/resolv.conf
    ping -c1 dl-cdn.alpinelinux.org"

    grep -q '^[^#]*alpinelinux\|^[^#]*http' /etc/apk/repositories 2>/dev/null \
        || die "setup-apkrepos reported success but /etc/apk/repositories has no
network mirror - only the stick's local packages. Contents:

$(cat /etc/apk/repositories 2>/dev/null)"
    info "community repository enabled"

    mkdir -p "$MEDIUM_DIR/cache"
    setup-apkcache "$MEDIUM_DIR/cache" >/dev/null 2>&1 || warn "setup-apkcache reported a problem"
    info "apk cache at $MEDIUM_DIR/cache"

    setup-lbu "$MEDIUM_DEV" >/dev/null 2>&1 || warn "setup-lbu reported a problem"
    info "lbu media set to $MEDIUM_DEV"
}

install_packages() {
    log "Installing packages"
    # The lease setup_network() took out is what makes this work. Alpine's
    # standard ISO boots with every interface down, so without that step
    # /etc/apk/repositories holds only the stick's local package set and every
    # name below fails as "no such package" - including staples like curl.
    apk update >/dev/null 2>&1 || die "apk update failed - could not reach the package mirror.

The network was up a moment ago (setup_network leased an address), so this is
most likely DNS or a blocked outbound connection rather than a dead link."
    # shellcheck disable=SC2086  # word splitting of the package list is intended
    apk add $APK_PACKAGES || die "apk add failed

If EVERY package was reported as 'no such package' - including curl - then the
problem is the repositories, not the packages: apk has no working mirror. Check
/etc/apk/repositories for an http(s) line alongside the local $MEDIUM_DIR/apks.

If ONLY iputils-arping=20250605-r2 failed, the pinned version has left the
repository. Do NOT simply drop the pin: dns-ip.initd depends on arping -D
exiting 0 for a free address. Verify those semantics against the new version
first (see README.md, 'arping variants')."
    info "installed: $APK_PACKAGES"
}

install_technitium() {
    log "Installing Technitium DNS Server"
    mkdir -p "$TECHNITIUM_DIR" "$CREDS_DIR"
    chmod 0700 "$CREDS_DIR"

    _tarball="/tmp/DnsServerPortable.tar.gz"
    curl -fsSL --connect-timeout 10 --max-time 900 -o "$_tarball" "$TECHNITIUM_URL" || die "could not download Technitium"

    # The upstream URL is unversioned, so the checksum is observed here rather
    # than pinned in the script. Recording it makes an unexpected upstream
    # change visible on the next run.
    _sha=$(sha256sum "$_tarball" | awk '{print $1}')
    if [ -f "$CREDS_DIR/technitium.sha256" ]; then
        _prev=$(cat "$CREDS_DIR/technitium.sha256")
        [ "$_prev" = "$_sha" ] || info "Technitium tarball changed upstream ($_prev -> $_sha)"
    fi
    printf '%s\n' "$_sha" > "$CREDS_DIR/technitium.sha256"

    # The upstream tarball is flat: its files (DnsServerApp.dll, start.sh,
    # the runtimes/ and www/ subdirectories, ...) sit at the archive root
    # with no wrapping top-level directory. --strip-components=1 would
    # discard every one of those root-level files - including
    # DnsServerApp.dll, which alpine/technitium.initd invokes directly as
    # command_args - and misplace the subdirectories underneath it.
    # Confirmed by downloading the real tarball: `tar -tzf` lists 95 entries
    # at the archive root (no common prefix), and extracting with
    # --strip-components=1 yields only 47 files with DnsServerApp.dll gone,
    # versus 95 files including DnsServerApp.dll without it.
    #
    # A re-run must not leave a mix of a previous install's files and this
    # one's, so clear $TECHNITIUM_DIR first - except its "config"
    # subdirectory. "config" is never in the tarball at all: it is created
    # by alpine/technitium.initd's start_pre() (checkpath --directory) and
    # populated by Technitium itself the first time it starts, holding the
    # settings database and the operator's live DNS configuration. It is
    # tracked via `lbu add /opt`, so on a diskless boot it is restored to
    # $TECHNITIUM_DIR before provision.sh ever runs again. Deleting it here
    # would silently wipe that configuration on every re-provision.
    for _entry in "$TECHNITIUM_DIR"/*; do
        [ -e "$_entry" ] || continue
        [ "$(basename "$_entry")" = "config" ] && continue
        rm -rf "$_entry"
    done

    tar -xzf "$_tarball" -C "$TECHNITIUM_DIR" \
        || die "could not extract Technitium"
    rm -f "$_tarball"

    # Extraction reporting success is not proof the layout is what
    # technitium.initd needs: verify the exact file it runs as command_args
    # actually landed and is non-empty, so a future change to the tarball's
    # layout fails loudly here instead of as a mysterious boot failure.
    [ -s "$TECHNITIUM_DIR/DnsServerApp.dll" ] \
        || die "Technitium extraction did not produce $TECHNITIUM_DIR/DnsServerApp.dll (missing or empty) - alpine/technitium.initd requires this exact path to start the DNS server; the upstream tarball layout may have changed"

    info "extracted to $TECHNITIUM_DIR (sha256 $_sha)"
}

install_services() {
    log "Installing OpenRC services"
    _src="$MEDIUM_DIR/provision/alpine"
    for _svc in dns-ip technitium; do
        cp "$_src/${_svc}.initd" "/etc/init.d/$_svc" || die "could not install $_svc"
        chmod +x "/etc/init.d/$_svc"
        rc-update add "$_svc" default >/dev/null 2>&1 \
            || die "rc-update add $_svc default failed - it will not autostart on reboot"
        # rc-update's exit code alone is not proof: verify the runlevel
        # symlink actually landed, so a failure here is caught tonight
        # instead of discovered after the next reboot.
        [ -e "/etc/runlevels/default/$_svc" ] \
            || die "$_svc was not registered in the default runlevel despite rc-update reporting success"
        info "$_svc installed and added to the default runlevel"
    done

    write_technitium_confd
}

# Resolve the forwarder list and hand it to the service before its first
# start. Technitium reads its environment-variable config ONLY while
# config/dns.config is absent, so this is the one chance to have working
# upstream resolution on the very first start. configure_technitium() applies
# the same values through the API afterwards, which is what makes a re-run
# converge once that window has closed.
write_technitium_confd() {
    _fwd_file="$MEDIUM_DIR/provision/config/forwarders.txt"
    if [ -f "$_fwd_file" ]; then
        FORWARDERS=$(forwarder_urls "$_fwd_file")
    else
        FORWARDERS="$DEFAULT_FORWARDERS"
        warn "$_fwd_file not found; using built-in default forwarders"
    fi

    {
        printf '# Written by provision.sh. Sourced by OpenRC before technitium.initd.\n'
        printf 'TECHNITIUM_WEB_ADDRESSES="0.0.0.0"\n'
        printf 'TECHNITIUM_FORWARDERS="%s"\n' "$FORWARDERS"
        printf 'TECHNITIUM_FORWARDER_PROTOCOL="%s"\n' "$FORWARDER_PROTOCOL"
    } > "$TECHNITIUM_CONFD"

    if [ -n "$FORWARDERS" ]; then
        info "first-start forwarders ($FORWARDER_PROTOCOL): $FORWARDERS"
    else
        info "no forwarders configured - Technitium will resolve recursively"
    fi
    info "web console will bind 0.0.0.0:5380 (IPv4)"
}

start_services() {
    log "Starting services"

    rc-service dns-ip restart || die "dns-ip failed to claim an address

This is the same failure the appliance would hit at boot. Check the output
above: either DHCP discovery failed, or all of .53-.59 are already taken."

    [ -s /run/dns-ip ] || die "dns-ip reported success but /run/dns-ip is empty"
    CLAIMED_IP=$(cat /run/dns-ip)
    # dns-ip just restarted moments ago above, so this is expected to always
    # hold - but /run/dns-ip is a plain file, and alpine/technitium.initd's
    # claimed_ip() validates the very same file before trusting it. Do the
    # same here rather than passing it straight into curl URLs and the DNS
    # bind address unchecked.
    valid_ipv4 "$CLAIMED_IP" \
        || die "/run/dns-ip does not contain a valid IPv4 address (got '$CLAIMED_IP') - dns-ip reported success but wrote something unexpected"
    info "claimed $CLAIMED_IP"

    rc-service technitium restart || die "technitium failed to start - see /var/log/technitium.log"

    # Probe for the HTTP server answering at all, independent of whether
    # credentials are already stored - a stored-credentials check here would
    # make this loop a no-op on every re-run, and the old probe additionally
    # sent "pass=admin" unencoded in a URL query string, which is exactly the
    # pattern eliminated everywhere else in this file. No credentials are
    # sent at all: any response from the web root proves Kestrel is up.
    _wait=0
    _api_up=0
    while [ "$_wait" -lt 90 ]; do
        if curl -fsS --connect-timeout 2 --max-time 5 -o /dev/null "$TECHNITIUM_API/" 2>/dev/null; then
            _api_up=1
            break
        fi
        _wait=$((_wait + 3))
        sleep 3
    done

    if [ "$_api_up" -eq 1 ]; then
        info "Technitium API is responding"
    else
        warn "Technitium API did not respond within 90s; continuing anyway - the login attempt next may fail"
    fi
}

configure_technitium() {
    log "Configuring Technitium"

    # Which password actually authenticates - not whether a creds file
    # happens to exist - is what decides whether a rotation is needed below.
    # A stale creds file from a reused stick must not be trusted blindly: if
    # it doesn't work but the factory default does, the server really is on
    # admin/admin and must be rotated regardless of what's on disk.
    #
    # A pending file (see CREDS_PENDING) is also tried: it means a previous
    # run's changePassword call reached the server but the script died
    # before promoting it to CREDS_FILE, so the "old" stored/factory
    # password no longer works but the pending one does.
    _stored_pass=""
    [ -s "$CREDS_FILE" ] && _stored_pass=$(cat "$CREDS_FILE")

    _pending_pass=""
    [ -s "$CREDS_PENDING" ] && _pending_pass=$(cat "$CREDS_PENDING")

    _authed_pass=""
    if [ -n "$_stored_pass" ] && _token=$(api_token "$_stored_pass"); then
        _authed_pass="$_stored_pass"
    elif [ -n "$_pending_pass" ] && _token=$(api_token "$_pending_pass"); then
        _authed_pass="$_pending_pass"
        mv "$CREDS_PENDING" "$CREDS_FILE" \
            || die "authenticated with the pending password but could not promote $CREDS_PENDING to $CREDS_FILE - recover the password from that file manually"
        chmod 0600 "$CREDS_FILE"
        warn "recovered an interrupted password rotation from $CREDS_PENDING"
    elif _token=$(api_token "admin"); then
        _authed_pass="admin"
        [ -n "$_stored_pass" ] && warn "stored password did not work; the factory default did"
    else
        die "could not log in to the Technitium API with the stored password, a pending rotation, or the factory default - see /var/log/technitium.log"
    fi

    _lists=$(blocklist_urls "$MEDIUM_DIR/provision/config/blocklists.txt")
    _endpoints="${CLAIMED_IP}:53,127.0.0.1:53"

    # Forwarders. Technitium's default is full recursion, which breaks on any
    # network that intercepts outbound port 53 - the hijacked responses come
    # back without DNSSEC records and every lookup SERVFAILs with "Missing
    # non-existence proof". Forwarding over DoH is encrypted on 443, so no
    # middlebox can rewrite it.
    #
    # An empty list is NOT the same as no forwarders: the API needs the
    # literal string "false" to drop existing ones and go back to recursion.
    # FORWARDERS was resolved by write_technitium_confd() before the service
    # first started. Re-applying it here is what makes a re-run converge: the
    # environment-variable path is dead once config/dns.config exists.
    #
    # An empty list is NOT the same as no forwarders: the API needs the
    # literal string "false" to drop existing ones and go back to recursion.
    if [ -z "${FORWARDERS:-}" ]; then
        _forwarders="false"
        info "no forwarders configured - Technitium will resolve recursively"
    else
        _forwarders="$FORWARDERS"
        info "forwarding over $FORWARDER_PROTOCOL to $_forwarders"
    fi

    _settings_resp="/tmp/technitium-settings.json"
    curl -fsS --connect-timeout 5 --max-time 30 -X POST "$TECHNITIUM_API/api/settings/set" \
        --data-urlencode "token=$_token" \
        --data-urlencode "enableBlocking=true" \
        --data-urlencode "blockListUrls=$_lists" \
        --data-urlencode "blockListUrlUpdateIntervalHours=24" \
        --data-urlencode "dnsServerLocalEndPoints=$_endpoints" \
        --data-urlencode "webServiceLocalAddresses=0.0.0.0" \
        --data-urlencode "forwarders=$_forwarders" \
        --data-urlencode "forwarderProtocol=$FORWARDER_PROTOCOL" \
        --data-urlencode "concurrentForwarding=true" \
        --data-urlencode "dnssecValidation=true" \
        >"$_settings_resp" 2>/dev/null

    if ! api_ok "$_settings_resp"; then
        _err=$(json_field "$_settings_resp" errorMessage)
        rm -f "$_settings_resp"
        die "could not apply Technitium settings: ${_err:-no response from server}"
    fi
    rm -f "$_settings_resp"
    info "blocking enabled, listening on $_endpoints"
    info "blocklists: $_lists"

    _refresh_resp="/tmp/technitium-blocklist-refresh.json"
    curl -fsS --connect-timeout 5 --max-time 30 -X POST "$TECHNITIUM_API/api/settings/forceUpdateBlockLists" \
        --data-urlencode "token=$_token" \
        >"$_refresh_resp" 2>/dev/null

    if api_ok "$_refresh_resp"; then
        info "blocklist refresh triggered"
    else
        _err=$(json_field "$_refresh_resp" errorMessage)
        warn "could not force an immediate blocklist refresh (${_err:-no response from server}); lists will update on schedule"
    fi
    rm -f "$_refresh_resp"

    # Rotate whenever the password that actually authenticated was the
    # factory default - not merely when CREDS_FILE is empty (see above).
    # This block is what report() below reflects via ADMIN_PASSWORD, so
    # every exit path must set ADMIN_PASSWORD/ADMIN_PASSWORD_NOTE to
    # something that matches what actually happened on the server.
    if [ "$_authed_pass" = "admin" ]; then
        _new=$(random_password)

        # Persist the candidate password BEFORE it is ever sent to the
        # server. This is the crash-safety invariant: once this write
        # succeeds, the new password is durably recoverable from disk no
        # matter what happens next - including set -eu killing the script
        # the instant after the API call below succeeds.
        rm -f "$CREDS_PENDING"
        if ! ( umask 077 && printf '%s\n' "$_new" > "$CREDS_PENDING" ); then
            die "could not persist the pending password to $CREDS_PENDING - refusing to rotate; the server is still on admin/admin"
        fi
        chmod 0600 "$CREDS_PENDING"

        _changepw_resp="/tmp/technitium-changepw.json"
        curl -fsS --connect-timeout 5 --max-time 30 -X POST "$TECHNITIUM_API/api/user/changePassword" \
            --data-urlencode "token=$_token" \
            --data-urlencode "pass=$_new" \
            >"$_changepw_resp" 2>/dev/null

        if api_ok "$_changepw_resp"; then
            rm -f "$_changepw_resp"
            # Verify by actually authenticating with the new password rather
            # than trusting the API's "status":"ok" alone.
            if api_token "$_new" >/dev/null; then
                mv "$CREDS_PENDING" "$CREDS_FILE" \
                    || die "the new password authenticates but could not be promoted from $CREDS_PENDING to $CREDS_FILE - recover it from that file manually"
                chmod 0600 "$CREDS_FILE"
                ADMIN_PASSWORD="$_new"
                ADMIN_PASSWORD_NOTE="rotated and stored at $CREDS_FILE"
                info "admin password rotated, verified, and stored at $CREDS_FILE"
            else
                ADMIN_PASSWORD="(unknown - see $CREDS_PENDING)"
                ADMIN_PASSWORD_NOTE="changePassword reported success but the new password did not authenticate; recover it from $CREDS_PENDING immediately"
                warn "changePassword reported success but the new password did not authenticate"
                warn "the new password is saved at $CREDS_PENDING - recover it manually; do not delete this file"
            fi
        else
            _err=$(json_field "$_changepw_resp" errorMessage)
            rm -f "$_changepw_resp"
            rm -f "$CREDS_PENDING"
            ADMIN_PASSWORD="admin"
            ADMIN_PASSWORD_NOTE="rotation failed (${_err:-no response from server}) - still admin/admin, change it in the web console immediately"
            warn "could not rotate the admin password (${_err:-no response from server}) - it is still admin/admin!"
            warn "change it in the web console immediately."
        fi
    else
        ADMIN_PASSWORD="$_authed_pass"
        ADMIN_PASSWORD_NOTE="stored at $CREDS_FILE"
        info "stored password already authenticates; leaving it alone"
    fi
}

persist() {
    log "Persisting configuration with lbu"
    # /opt is NOT in lbu's default include list. Without this, Technitium
    # disappears on the next reboot.
    #
    # Unlike setup-apkrepos/setup-apkcache/setup-lbu above (reasonably left
    # as warnings: a genuine failure there surfaces downstream when lbu
    # commit fails, which is already fatal), a failed lbu add here has no
    # such catch. lbu commit only packages whatever is in the include list;
    # it succeeds regardless of whether these two adds landed in it. Without
    # this being fatal, a failed lbu add produces an appliance that
    # provisions "successfully", reports success, and comes up without
    # Technitium after the next reboot - so it must die here, not warn.
    lbu add /opt >/dev/null 2>&1 \
        || die "lbu add /opt failed - Technitium will NOT survive a reboot; re-run provision.sh"
    lbu add "$CREDS_DIR" >/dev/null 2>&1 \
        || die "lbu add $CREDS_DIR failed - the admin password will NOT survive a reboot; re-run provision.sh"

    # The init scripts must be added EXPLICITLY, and this is the least obvious
    # persistence trap in the whole appliance: apk's backup audit - which lbu
    # uses to decide what to package - has a BUILT-IN exclusion for
    # /etc/init.d, on the assumption that init scripts come from packages.
    # Ours do not. Without these entries the apkovl restores the hostname,
    # the runlevel symlinks, /opt, everything - except the two scripts the
    # symlinks point at, so the appliance boots to 'service does not exist'
    # and serves nothing. Observed on real hardware; verified against lbu:
    # a custom file in /etc is captured, the same file in /etc/init.d is not.
    lbu add /etc/init.d/dns-ip /etc/init.d/technitium >/dev/null 2>&1 \
        || die "lbu add for the init scripts failed - the services will NOT survive a reboot; re-run provision.sh"

    # lbu add exiting 0 is not proof either - the same "reported success"
    # gap this whole fix closes. Verify against lbu's own persisted include
    # list (/etc/apk/protected_paths.d/lbu.list, where `lbu add` records
    # "+opt" and "+etc/dns-appliance") rather than trusting the
    # add-then-commit sequence blindly, the same way install_services()
    # above double-checks rc-update's exit code against the runlevel
    # symlink it's supposed to have created.
    #
    # This check runs before `lbu commit -d`, not after: the include list is
    # what commit reads to decide what to package, and commit does not
    # modify it, so a path missing from the list now will still be missing
    # from it after a successful commit. Re-parsing the committed apkovl
    # itself to double-check would add real fragility (its filename is
    # dynamic, derived from hostname/mount point, and undocumented here) for
    # no additional coverage over checking the include list directly.
    _lbu_include_list="/etc/apk/protected_paths.d/lbu.list"
    _opt_entry=$(lbu_list_entry "/opt")
    _creds_entry=$(lbu_list_entry "$CREDS_DIR")
    grep -qxF "+$_opt_entry" "$_lbu_include_list" 2>/dev/null \
        || die "lbu add /opt reported success but +$_opt_entry is not in $_lbu_include_list - Technitium will NOT survive a reboot"
    grep -qxF "+$_creds_entry" "$_lbu_include_list" 2>/dev/null \
        || die "lbu add $CREDS_DIR reported success but +$_creds_entry is not in $_lbu_include_list - the admin password will NOT survive a reboot"
    for _svc in dns-ip technitium; do
        grep -qxF "+etc/init.d/$_svc" "$_lbu_include_list" 2>/dev/null \
            || die "lbu add reported success but +etc/init.d/$_svc is not in $_lbu_include_list - the $_svc service will NOT survive a reboot"
    done
    info "tracking /opt, $CREDS_DIR, and both init scripts"

    lbu commit -d || die "lbu commit failed - the configuration will NOT survive a reboot"
    info "committed to $MEDIUM_DIR"
}

report() {
    # ADMIN_PASSWORD/ADMIN_PASSWORD_NOTE are set by configure_technitium to
    # reflect what actually happened this run - never re-derived from
    # CREDS_FILE here, since a stale file (e.g. a failed rotation that left
    # the server on admin/admin) would make this report claim a rotation
    # that did not happen.

    cat <<REPORT

============================================================================
  dns-appliance is provisioned.
============================================================================

  DNS server      ${CLAIMED_IP}:53
  Web console     http://${CLAIMED_IP}:5380
  Admin user      admin
  Admin password  ${ADMIN_PASSWORD}
                  (${ADMIN_PASSWORD_NOTE})

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
    trap on_exit EXIT INT TERM
    require_root
    locate_medium
    setup_network
    setup_base
    install_packages
    install_technitium
    install_services
    start_services
    configure_technitium
    persist
    PROVISION_COMPLETE=1
    report
}

if [ "${ADS_SOURCE_ONLY:-0}" != "1" ]; then
    main "$@"
fi
