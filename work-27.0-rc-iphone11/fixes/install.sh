#!/bin/zsh
set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BASE/../.." && pwd)"
PAYLOAD="$BASE/build/payload"
PORT="${USBLITER8_SSH_PORT:-2222}"
PASSWORD="${USBLITER8_SSHRD_PASSWORD:-alpine}"

SSHPASS="${USBLITER8_SSHPASS:-$(command -v sshpass || true)}"
if [[ -z "$SSHPASS" ]]; then
    SSHPASS="$REPO_ROOT/tools/sshpass"
fi
if [[ ! -x "$SSHPASS" ]] || ! "$SSHPASS" -V >/dev/null 2>&1; then
    print -u2 "No runnable sshpass was found; set USBLITER8_SSHPASS"
    exit 1
fi

LOCKDOWN_STOCK_SHA="b42e3a6d87b67d0949fb28b3f07b65e00b4074fd67d5d3f588d01ad3365c2306"
WIFID_STOCK_SHA="a75c43fc82eabf942c659d6dfa3a494162e551b6b5430a66ea32cdd3c8b63322"

MODE="install"
if [[ "${1:-}" == "--rollback" ]]; then
    MODE="rollback"
elif (( $# != 0 )); then
    print -u2 "usage: $0 [--rollback]"
    exit 2
fi

if [[ "$MODE" == "install" ]]; then
    for required_file in \
        "$PAYLOAD/lockdownd" \
        "$PAYLOAD/wifid" \
        "$PAYLOAD/usbliter8-pairing.dylib" \
        "$PAYLOAD/usbliter8-wifi.dylib" \
        "$PAYLOAD/manifest.sha256"; do
        if [[ ! -f "$required_file" ]]; then
            print -u2 "Missing built payload: $required_file"
            print -u2 "Run build.sh first."
            exit 1
        fi
    done
    (
        cd "$PAYLOAD"
        shasum -a 256 -c manifest.sha256
    )
fi

IPROXY="$(command -v iproxy || true)"
if [[ -z "$IPROXY" ]]; then
    print -u2 "iproxy was not found in PATH"
    exit 1
fi
if command -v nc >/dev/null 2>&1 &&
   nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then
    print -u2 "Local port $PORT is already in use; refusing to disturb it"
    exit 1
fi

TEMP_DIR="$(mktemp -d /tmp/usbliter8-install.XXXXXX)"
IPROXY_PID=""
CONTROL_PATH="$TEMP_DIR/ssh-control"
cleanup() {
    if [[ -S "$CONTROL_PATH" ]]; then
        ssh -S "$CONTROL_PATH" -O exit root@127.0.0.1 \
            >/dev/null 2>&1 || true
    fi
    if [[ -n "$IPROXY_PID" ]]; then
        kill "$IPROXY_PID" 2>/dev/null || true
        wait "$IPROXY_PID" 2>/dev/null || true
    fi
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT INT TERM

"$IPROXY" "$PORT:22" >"$TEMP_DIR/iproxy.log" 2>&1 &
IPROXY_PID=$!

SSH_OPTIONS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o ConnectTimeout=3
    -o LogLevel=ERROR
    -o ControlPath="$CONTROL_PATH"
    -p "$PORT"
)
SCP_OPTIONS=(
    -O
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o ConnectTimeout=3
    -o ControlPath="$CONTROL_PATH"
    -P "$PORT"
)

ssh_device() {
    ssh "${SSH_OPTIONS[@]}" root@127.0.0.1 "$@"
}

scp_from_device() {
    scp "${SCP_OPTIONS[@]}" "root@127.0.0.1:$1" "$2"
}

scp_to_device() {
    scp "${SCP_OPTIONS[@]}" "$1" "root@127.0.0.1:$2"
}

print "Waiting for SSH ramdisk on localhost:$PORT"
connected=""
for attempt in {1..60}; do
    if ! kill -0 "$IPROXY_PID" >/dev/null 2>&1; then
        print -u2 "iproxy exited before SSH became available"
        sed -n '1,120p' "$TEMP_DIR/iproxy.log" >&2
        exit 1
    fi
    if "$SSHPASS" -p "$PASSWORD" ssh "${SSH_OPTIONS[@]}" \
        -o ControlMaster=yes -o ControlPersist=no -N -f \
        root@127.0.0.1 >/dev/null 2>&1; then
        connected="yes"
        break
    fi
    sleep 1
done
if [[ -z "$connected" ]]; then
    print -u2 "No SSH ramdisk responded. This script refuses to modify normal iOS."
    sed -n '1,120p' "$TEMP_DIR/iproxy.log" >&2
    exit 1
fi
if ! ssh_device '/sbin/mount | /usr/bin/grep -q "md0 on /"' \
    >/dev/null 2>&1; then
    print -u2 "SSH endpoint is not the expected md0 ramdisk; refusing writes"
    exit 1
fi
print "Mounting the System volume read-write"
ssh_device '
set -e
/bin/mkdir -p /mnt1
if ! /sbin/mount | /usr/bin/grep -q " on /mnt1 "; then
    /sbin/mount_apfs /dev/disk1s1 /mnt1
fi
/sbin/mount -u -o rw /dev/disk1s1
test -f /mnt1/usr/libexec/lockdownd
test -f /mnt1/usr/sbin/wifid
'

if [[ "$MODE" == "rollback" ]]; then
    print "Reading and verifying both backups before rollback"
    ssh_device '
set -e
test -f /mnt1/usr/libexec/lockdownd.usbliter8-stock-24A435
test -f /mnt1/usr/sbin/wifid.usbliter8-stock-24A435
'
    scp_from_device \
        /mnt1/usr/libexec/lockdownd.usbliter8-stock-24A435 \
        "$TEMP_DIR/lockdownd.backup"
    scp_from_device \
        /mnt1/usr/sbin/wifid.usbliter8-stock-24A435 \
        "$TEMP_DIR/wifid.backup"
    [[ "$(shasum -a 256 "$TEMP_DIR/lockdownd.backup" | awk '{print $1}')" == \
        "$LOCKDOWN_STOCK_SHA" ]]
    [[ "$(shasum -a 256 "$TEMP_DIR/wifid.backup" | awk '{print $1}')" == \
        "$WIFID_STOCK_SHA" ]]

    print "Restoring the verified pre-install daemon backups"
    ssh_device '
set -e
/usr/bin/chflags nouchg,noschg /mnt1/usr/libexec/lockdownd /mnt1/usr/sbin/wifid 2>/dev/null || true
/bin/cp /mnt1/usr/libexec/lockdownd.usbliter8-stock-24A435 /mnt1/usr/libexec/lockdownd
/bin/cp /mnt1/usr/sbin/wifid.usbliter8-stock-24A435 /mnt1/usr/sbin/wifid
/bin/chmod 0755 /mnt1/usr/libexec/lockdownd /mnt1/usr/sbin/wifid
/usr/sbin/chown 0:0 /mnt1/usr/libexec/lockdownd /mnt1/usr/sbin/wifid
/bin/sync
'
    scp_from_device /mnt1/usr/libexec/lockdownd "$TEMP_DIR/lockdownd.rollback"
    scp_from_device /mnt1/usr/sbin/wifid "$TEMP_DIR/wifid.rollback"
    [[ "$(shasum -a 256 "$TEMP_DIR/lockdownd.rollback" | awk '{print $1}')" == \
        "$LOCKDOWN_STOCK_SHA" ]]
    [[ "$(shasum -a 256 "$TEMP_DIR/wifid.rollback" | awk '{print $1}')" == \
        "$WIFID_STOCK_SHA" ]]
    print "Rollback verified. The unused dylibs may remain safely on System."
    exit 0
fi

LOCKDOWN_PATCHED_SHA="$(shasum -a 256 "$PAYLOAD/lockdownd" | awk '{print $1}')"
WIFID_PATCHED_SHA="$(shasum -a 256 "$PAYLOAD/wifid" | awk '{print $1}')"

print "Checking exact on-device daemon preimages"
scp_from_device /mnt1/usr/libexec/lockdownd "$TEMP_DIR/lockdownd.device"
scp_from_device /mnt1/usr/sbin/wifid "$TEMP_DIR/wifid.device"
LOCKDOWN_DEVICE_SHA="$(shasum -a 256 "$TEMP_DIR/lockdownd.device" | awk '{print $1}')"
WIFID_DEVICE_SHA="$(shasum -a 256 "$TEMP_DIR/wifid.device" | awk '{print $1}')"

if [[ "$LOCKDOWN_DEVICE_SHA" != "$LOCKDOWN_STOCK_SHA" &&
      "$LOCKDOWN_DEVICE_SHA" != "$LOCKDOWN_PATCHED_SHA" ]]; then
    print -u2 "Refusing unknown lockdownd: $LOCKDOWN_DEVICE_SHA"
    exit 1
fi
if [[ "$WIFID_DEVICE_SHA" != "$WIFID_STOCK_SHA" &&
      "$WIFID_DEVICE_SHA" != "$WIFID_PATCHED_SHA" ]]; then
    print -u2 "Refusing unknown wifid: $WIFID_DEVICE_SHA"
    exit 1
fi

BACKUP_STATE="$(ssh_device '
lockdown=/mnt1/usr/libexec/lockdownd.usbliter8-stock-24A435
wifid=/mnt1/usr/sbin/wifid.usbliter8-stock-24A435
if test -f "$lockdown" && test -f "$wifid"; then
    echo both
elif test ! -e "$lockdown" && test ! -e "$wifid"; then
    echo neither
else
    echo partial
fi
')"
if [[ "$BACKUP_STATE" == "partial" ]]; then
    print -u2 "Refusing to continue with only one daemon backup present"
    exit 1
fi
if [[ "$BACKUP_STATE" == "neither" &&
      ( "$LOCKDOWN_DEVICE_SHA" == "$LOCKDOWN_PATCHED_SHA" ||
        "$WIFID_DEVICE_SHA" == "$WIFID_PATCHED_SHA" ) ]]; then
    print -u2 "Refusing patched daemons without both stock backups"
    exit 1
fi
if [[ "$BACKUP_STATE" == "both" ]]; then
    print "Verifying existing daemon backups before installation"
    scp_from_device \
        /mnt1/usr/libexec/lockdownd.usbliter8-stock-24A435 \
        "$TEMP_DIR/lockdownd.backup.preflight"
    scp_from_device \
        /mnt1/usr/sbin/wifid.usbliter8-stock-24A435 \
        "$TEMP_DIR/wifid.backup.preflight"
    [[ "$(shasum -a 256 "$TEMP_DIR/lockdownd.backup.preflight" | awk '{print $1}')" == \
        "$LOCKDOWN_STOCK_SHA" ]]
    [[ "$(shasum -a 256 "$TEMP_DIR/wifid.backup.preflight" | awk '{print $1}')" == \
        "$WIFID_STOCK_SHA" ]]
fi

print "Uploading signed payloads"
scp_to_device \
    "$PAYLOAD/lockdownd" /mnt1/usr/libexec/.lockdownd.usbliter8-new
scp_to_device "$PAYLOAD/wifid" /mnt1/usr/sbin/.wifid.usbliter8-new
scp_to_device \
    "$PAYLOAD/usbliter8-pairing.dylib" \
    /mnt1/usr/lib/.usbliter8-pairing.dylib.new
scp_to_device \
    "$PAYLOAD/usbliter8-wifi.dylib" \
    /mnt1/usr/lib/.usbliter8-wifi.dylib.new

print "Reading staged payloads back before any replacement"
scp_from_device \
    /mnt1/usr/libexec/.lockdownd.usbliter8-new \
    "$TEMP_DIR/lockdownd.staged"
scp_from_device \
    /mnt1/usr/sbin/.wifid.usbliter8-new "$TEMP_DIR/wifid.staged"
scp_from_device \
    /mnt1/usr/lib/.usbliter8-pairing.dylib.new \
    "$TEMP_DIR/pairing.staged"
scp_from_device \
    /mnt1/usr/lib/.usbliter8-wifi.dylib.new "$TEMP_DIR/wifi.staged"
cmp "$PAYLOAD/lockdownd" "$TEMP_DIR/lockdownd.staged"
cmp "$PAYLOAD/wifid" "$TEMP_DIR/wifid.staged"
cmp "$PAYLOAD/usbliter8-pairing.dylib" "$TEMP_DIR/pairing.staged"
cmp "$PAYLOAD/usbliter8-wifi.dylib" "$TEMP_DIR/wifi.staged"

print "Installing dylibs first, then patched daemons"
ssh_device '
set -e
if test ! -f /mnt1/usr/libexec/lockdownd.usbliter8-stock-24A435; then
    /bin/cp /mnt1/usr/libexec/lockdownd /mnt1/usr/libexec/lockdownd.usbliter8-stock-24A435
fi
if test ! -f /mnt1/usr/sbin/wifid.usbliter8-stock-24A435; then
    /bin/cp /mnt1/usr/sbin/wifid /mnt1/usr/sbin/wifid.usbliter8-stock-24A435
fi
/usr/bin/chflags nouchg,noschg /mnt1/usr/libexec/lockdownd /mnt1/usr/sbin/wifid 2>/dev/null || true
/bin/chmod 0755 /mnt1/usr/lib/.usbliter8-pairing.dylib.new /mnt1/usr/lib/.usbliter8-wifi.dylib.new
/bin/chmod 0755 /mnt1/usr/libexec/.lockdownd.usbliter8-new /mnt1/usr/sbin/.wifid.usbliter8-new
/usr/sbin/chown 0:0 /mnt1/usr/lib/.usbliter8-pairing.dylib.new /mnt1/usr/lib/.usbliter8-wifi.dylib.new
/usr/sbin/chown 0:0 /mnt1/usr/libexec/.lockdownd.usbliter8-new /mnt1/usr/sbin/.wifid.usbliter8-new
/bin/sync
/bin/mv -f /mnt1/usr/lib/.usbliter8-pairing.dylib.new /mnt1/usr/lib/usbliter8-pairing.dylib
/bin/mv -f /mnt1/usr/lib/.usbliter8-wifi.dylib.new /mnt1/usr/lib/usbliter8-wifi.dylib
/bin/sync
/bin/mv -f /mnt1/usr/libexec/.lockdownd.usbliter8-new /mnt1/usr/libexec/lockdownd
/bin/mv -f /mnt1/usr/sbin/.wifid.usbliter8-new /mnt1/usr/sbin/wifid
/bin/sync
'

print "Reading the installed files back for byte-for-byte verification"
scp_from_device /mnt1/usr/libexec/lockdownd "$TEMP_DIR/lockdownd.installed"
scp_from_device /mnt1/usr/sbin/wifid "$TEMP_DIR/wifid.installed"
scp_from_device \
    /mnt1/usr/libexec/lockdownd.usbliter8-stock-24A435 \
    "$TEMP_DIR/lockdownd.backup"
scp_from_device \
    /mnt1/usr/sbin/wifid.usbliter8-stock-24A435 \
    "$TEMP_DIR/wifid.backup"
scp_from_device \
    /mnt1/usr/lib/usbliter8-pairing.dylib "$TEMP_DIR/pairing.installed"
scp_from_device \
    /mnt1/usr/lib/usbliter8-wifi.dylib "$TEMP_DIR/wifi.installed"
cmp "$PAYLOAD/lockdownd" "$TEMP_DIR/lockdownd.installed"
cmp "$PAYLOAD/wifid" "$TEMP_DIR/wifid.installed"
cmp "$PAYLOAD/usbliter8-pairing.dylib" "$TEMP_DIR/pairing.installed"
cmp "$PAYLOAD/usbliter8-wifi.dylib" "$TEMP_DIR/wifi.installed"
[[ "$(shasum -a 256 "$TEMP_DIR/lockdownd.backup" | awk '{print $1}')" == \
    "$LOCKDOWN_STOCK_SHA" ]]
[[ "$(shasum -a 256 "$TEMP_DIR/wifid.backup" | awk '{print $1}')" == \
    "$WIFID_STOCK_SHA" ]]
/usr/bin/codesign --verify --strict "$TEMP_DIR/lockdownd.installed"
/usr/bin/codesign --verify --strict "$TEMP_DIR/wifid.installed"
/usr/bin/codesign --verify --strict "$TEMP_DIR/pairing.installed"
/usr/bin/codesign --verify --strict "$TEMP_DIR/wifi.installed"

print "Both fixes are installed and verified on System."
print "Next: power down, return to PWN DFU, and run the normal tethered boot."
