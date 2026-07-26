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
    curl -fsS -G "$TECHNITIUM_API/api/user/login" \
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

    _settings_resp="/tmp/technitium-settings.json"
    curl -fsS -X POST "$TECHNITIUM_API/api/settings/set" \
        --data-urlencode "token=$_token" \
        --data-urlencode "enableBlocking=true" \
        --data-urlencode "blockListUrls=$_lists" \
        --data-urlencode "blockListUrlUpdateIntervalHours=24" \
        --data-urlencode "dnsServerLocalEndPoints=$_endpoints" \
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
    curl -fsS -X POST "$TECHNITIUM_API/api/settings/forceUpdateBlockLists" \
        --data-urlencode "token=$_token" \
        >"$_refresh_resp" 2>/dev/null

    if api_ok "$_refresh_resp"; then
        info "blocklist refresh triggered"
    else
        _err=$(json_field "$_refresh_resp" errorMessage)
        warn "could not force an immediate blocklist refresh (${_err:-no response from server}); lists will update on schedule"
    fi
    rm -f "$_refresh_resp"

    # Rotate the factory password exactly once. The file's presence makes this
    # a no-op on re-runs.
    if [ ! -s "$CREDS_FILE" ]; then
        _new=$(random_password)
        _changepw_resp="/tmp/technitium-changepw.json"
        curl -fsS -X POST "$TECHNITIUM_API/api/user/changePassword" \
            --data-urlencode "token=$_token" \
            --data-urlencode "pass=$_new" \
            >"$_changepw_resp" 2>/dev/null

        if api_ok "$_changepw_resp"; then
            rm -f "$_changepw_resp"
            printf '%s\n' "$_new" > "$CREDS_FILE"
            chmod 0600 "$CREDS_FILE"
            info "admin password rotated and stored at $CREDS_FILE"
        else
            _err=$(json_field "$_changepw_resp" errorMessage)
            rm -f "$_changepw_resp"
            warn "could not rotate the admin password (${_err:-no response from server}) - it is still admin/admin!"
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
