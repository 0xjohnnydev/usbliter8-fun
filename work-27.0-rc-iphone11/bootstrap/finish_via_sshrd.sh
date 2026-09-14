#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
WORK_DIR=${SCRIPT_DIR:h}
REPO_ROOT=${WORK_DIR:h}

EXPERIMENTAL_PLIST="$SCRIPT_DIR/com.usbliter8.dropbear.plist"
EXPERIMENTAL_LAUNCHER="$SCRIPT_DIR/cache/normal-ssh-24A435/usbliter8-dropbear-launcher"
CLIENT_PUBLIC_KEY="$SCRIPT_DIR/.device-ssh/iphone11-24A435.pub"
SSHRD_ARCHIVE="$WORK_DIR/ssh.tar.gz"
EXPECTED_STOCK_CACHE_SHA256="752739f8224b016b5cee1b37a985995ffcfc1d6f12569fd2191ba5b4a9119c6a"
LOCAL_PORT=${USBLITER8_SSH_PORT:-2222}
SSHRD_PASSWORD=${USBLITER8_SSHRD_PASSWORD:-alpine}

die() {
    print -u2 -- "$*"
    exit 1
}

sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

for required in iproxy ssh scp nc shasum; do
    command -v "$required" >/dev/null 2>&1 || die "Missing required command: $required"
done
[[ -f "$EXPERIMENTAL_PLIST" ]] || die "Missing experimental plist used for rollback validation"
[[ -x "$EXPERIMENTAL_LAUNCHER" ]] || die "Missing experimental launcher used for rollback validation"
[[ -f "$CLIENT_PUBLIC_KEY" ]] || die "Missing experimental authorized key used for rollback validation"
[[ -f "$SSHRD_ARCHIVE" ]] || die "Missing canonical 34306 SSH payload: $SSHRD_ARCHIVE"

stock_backups=("$SCRIPT_DIR"/cache/device-backups/launchd.plist.usbliter8-original.*(N))
(( ${#stock_backups} > 0 )) || die "No host copy of the original device launchd cache exists"
STOCK_CACHE=${stock_backups[1]}
for candidate in "${stock_backups[@]}"; do
    [[ "$(sha256_of "$candidate")" == "$EXPECTED_STOCK_CACHE_SHA256" ]] || \
        die "A saved launchd-cache backup is not the exact stock 24A435 cache: $candidate"
done

SSHPASS=${USBLITER8_SSHPASS:-$(command -v sshpass || true)}
if [[ -z "$SSHPASS" ]]; then
    SSHPASS="$REPO_ROOT/tools/sshpass"
fi
[[ -x "$SSHPASS" ]] || die "No runnable sshpass was found; set USBLITER8_SSHPASS"
nc -z 127.0.0.1 "$LOCAL_PORT" >/dev/null 2>&1 && \
    die "Local port $LOCAL_PORT is already occupied; refusing to disturb it"

TEMP_DIR=$(mktemp -d /tmp/usbliter8-upstream-bootstrap.XXXXXX)
CONTROL_PATH="$TEMP_DIR/ssh-control"
IPROXY_PID=""
cleanup() {
    if [[ -S "$CONTROL_PATH" ]]; then
        /usr/bin/ssh -S "$CONTROL_PATH" -O exit root@127.0.0.1 >/dev/null 2>&1 || true
    fi
    if [[ -n "$IPROXY_PID" ]]; then
        kill "$IPROXY_PID" >/dev/null 2>&1 || true
        wait "$IPROXY_PID" >/dev/null 2>&1 || true
    fi
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT INT TERM HUP

# install_from_sshrd.sh copied this exact Dropbear binary from the canonical
# 34306 SSH payload onto Data.  Extract a comparison copy so rollback refuses
# to remove an unknown user binary at the same path.
/usr/bin/tar -xOf "$SSHRD_ARCHIVE" usr/local/bin/dropbear > "$TEMP_DIR/source-dropbear"
[[ -s "$TEMP_DIR/source-dropbear" ]] || die "Could not extract Dropbear from $SSHRD_ARCHIVE"

iproxy "$LOCAL_PORT:22" >"$TEMP_DIR/iproxy.log" 2>&1 &
IPROXY_PID=$!

SSH_OPTIONS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o ConnectTimeout=3
    -o LogLevel=ERROR
    -o ControlPath="$CONTROL_PATH"
    -p "$LOCAL_PORT"
)
SCP_OPTIONS=(
    -O
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o ConnectTimeout=3
    -o LogLevel=ERROR
    -o ControlPath="$CONTROL_PATH"
    -P "$LOCAL_PORT"
)

ssh_device() {
    /usr/bin/ssh "${SSH_OPTIONS[@]}" root@127.0.0.1 "$@"
}

scp_to_device() {
    /usr/bin/scp "${SCP_OPTIONS[@]}" "$1" "root@127.0.0.1:$2"
}

scp_from_device() {
    /usr/bin/scp "${SCP_OPTIONS[@]}" "root@127.0.0.1:$1" "$2"
}

print "Waiting for the 34306-style SSH ramdisk"
connected=0
for attempt in {1..60}; do
    if ! kill -0 "$IPROXY_PID" >/dev/null 2>&1; then
        sed -n '1,120p' "$TEMP_DIR/iproxy.log" >&2
        die "iproxy exited before SSH became available"
    fi
    if "$SSHPASS" -p "$SSHRD_PASSWORD" /usr/bin/ssh \
        "${SSH_OPTIONS[@]}" -o ControlMaster=yes -o ControlPersist=no \
        -N -f root@127.0.0.1 >/dev/null 2>&1; then
        connected=1
        break
    fi
    sleep 1
done
(( connected )) || die "The SSH ramdisk did not answer within 60 seconds"

ssh_device '/sbin/mount | /usr/bin/grep -q "md0 on /"' || \
    die "SSH endpoint is not the expected md0 ramdisk"

print "Mounting System and Data read-write"
ssh_device '
set -e
/bin/mkdir -p /mnt1 /mnt2
/sbin/mount | /usr/bin/grep -q " on /mnt1 " || /sbin/mount_apfs /dev/disk1s1 /mnt1
/sbin/mount | /usr/bin/grep -q " on /mnt2 " || /sbin/mount_apfs /dev/disk1s2 /mnt2
/sbin/mount -u -o rw /dev/disk1s1
/sbin/mount -u -o rw /dev/disk1s2
test -d /mnt1/Applications
test -d /mnt1/private/var
test -f /mnt2/jb/.procursus_strapped
test -x /mnt1/Applications/Sileo.app/Sileo
'

print "Restoring the byte-identical stock 24A435 launchd cache"
REMOTE_CACHE=/mnt1/System/Library/xpc/launchd.plist
REMOTE_BACKUP=${REMOTE_CACHE}.usbliter8-original
if ssh_device "test -f '$REMOTE_BACKUP'"; then
    scp_from_device "$REMOTE_BACKUP" "$TEMP_DIR/device-stock-cache.plist"
    cmp "$STOCK_CACHE" "$TEMP_DIR/device-stock-cache.plist"
fi
scp_to_device "$STOCK_CACHE" "${REMOTE_CACHE}.usbliter8-rollback-new"
scp_from_device "${REMOTE_CACHE}.usbliter8-rollback-new" "$TEMP_DIR/cache-staged-readback.plist"
cmp "$STOCK_CACHE" "$TEMP_DIR/cache-staged-readback.plist"

REMOTE_EXPERIMENTAL_PLIST=/mnt1/System/Library/LaunchDaemons/com.usbliter8.dropbear.plist
REMOTE_EXPERIMENTAL_LAUNCHER=/mnt1/usr/local/libexec/usbliter8-dropbear-launcher
if ssh_device "test -e '$REMOTE_EXPERIMENTAL_PLIST'"; then
    scp_from_device "$REMOTE_EXPERIMENTAL_PLIST" "$TEMP_DIR/device-experimental.plist"
    cmp "$EXPERIMENTAL_PLIST" "$TEMP_DIR/device-experimental.plist" || \
        die "The experimental plist changed unexpectedly; refusing rollback"
fi
if ssh_device "test -e '$REMOTE_EXPERIMENTAL_LAUNCHER'"; then
    scp_from_device "$REMOTE_EXPERIMENTAL_LAUNCHER" "$TEMP_DIR/device-experimental-launcher"
    cmp "$EXPERIMENTAL_LAUNCHER" "$TEMP_DIR/device-experimental-launcher" || \
        die "The experimental launcher changed unexpectedly; refusing rollback"
fi

# These Data files were installed only by our failed normal-SSH experiment;
# none is present in 34306's bootstrap archive or normal-boot recipe.
REMOTE_DATA_DROPBEAR=/mnt2/jb/usr/local/bin/dropbear
REMOTE_AUTHORIZED_KEYS=/mnt2/root/.ssh/authorized_keys
if ssh_device "test -e '$REMOTE_DATA_DROPBEAR'"; then
    scp_from_device "$REMOTE_DATA_DROPBEAR" "$TEMP_DIR/device-data-dropbear"
    cmp "$TEMP_DIR/source-dropbear" "$TEMP_DIR/device-data-dropbear" || \
        die "The staged Data Dropbear changed unexpectedly; refusing rollback"
fi
if ssh_device "test -e '$REMOTE_AUTHORIZED_KEYS'"; then
    scp_from_device "$REMOTE_AUTHORIZED_KEYS" "$TEMP_DIR/device-authorized_keys"
    cmp "$CLIENT_PUBLIC_KEY" "$TEMP_DIR/device-authorized_keys" || \
        die "authorized_keys contains data other than the experimental key; refusing rollback"
fi
root_ssh_entries=$(ssh_device 'if test -d /mnt2/root/.ssh; then /bin/ls -1A /mnt2/root/.ssh; fi')
[[ -z "$root_ssh_entries" || "$root_ssh_entries" == "authorized_keys" ]] || \
    die "The experimental root SSH directory contains unknown data; refusing rollback"
dropbear_etc_entries=$(ssh_device 'if test -d /mnt2/jb/etc/dropbear; then /bin/ls -1A /mnt2/jb/etc/dropbear; fi')
[[ -z "$dropbear_etc_entries" || "$dropbear_etc_entries" == "dropbear_ecdsa_host_key" ]] || \
    die "The experimental Dropbear config directory contains unknown data; refusing rollback"

ssh_device "
set -e
/usr/sbin/chown 0:0 '${REMOTE_CACHE}.usbliter8-rollback-new'
/bin/chmod 0644 '${REMOTE_CACHE}.usbliter8-rollback-new'
/bin/mv -f '${REMOTE_CACHE}.usbliter8-rollback-new' '$REMOTE_CACHE'
if test -e '$REMOTE_EXPERIMENTAL_PLIST'; then
    /bin/rm '$REMOTE_EXPERIMENTAL_PLIST'
fi
if test -e '$REMOTE_EXPERIMENTAL_LAUNCHER'; then
    /bin/rm '$REMOTE_EXPERIMENTAL_LAUNCHER'
fi
/bin/sync
"
scp_from_device "$REMOTE_CACHE" "$TEMP_DIR/cache-final-readback.plist"
cmp "$STOCK_CACHE" "$TEMP_DIR/cache-final-readback.plist"

print "Removing only the byte-validated normal-SSH experiment"
ssh_device "
set -e
/bin/rm -f '$REMOTE_BACKUP'
/bin/rm -f '$REMOTE_DATA_DROPBEAR'
/bin/rm -f /mnt2/jb/etc/dropbear/dropbear_ecdsa_host_key
/bin/rmdir /mnt2/jb/etc/dropbear 2>/dev/null || true
/bin/rm -f '$REMOTE_AUTHORIZED_KEYS'
/bin/rmdir /mnt2/root/.ssh 2>/dev/null || true
/bin/rm -f /mnt2/run/usbliter8-dropbear.pid
/bin/rm -f /mnt2/tmp/usbliter8-launcher-test.log
/bin/rm -f /mnt2/jb/.usbliter8-finish-via-sshrd.sh
/bin/rm -f /mnt1/cores/.usbliter8-chroot
/bin/rm -rf /mnt1/cores/.usbliter8-chroot-libs
/bin/rmdir /mnt2/jb/usr/local/bin 2>/dev/null || true
/bin/rmdir /mnt2/jb/usr/local 2>/dev/null || true
/bin/sync
test ! -e '$REMOTE_BACKUP'
test ! -e '$REMOTE_EXPERIMENTAL_PLIST'
test ! -e '$REMOTE_EXPERIMENTAL_LAUNCHER'
test ! -e '$REMOTE_DATA_DROPBEAR'
test ! -e '$REMOTE_AUTHORIZED_KEYS'
test -x /mnt1/Applications/Sileo.app/Sileo
"

scp_from_device /mnt1/Applications/Sileo.app/Info.plist "$TEMP_DIR/Sileo-Info.plist"
/usr/bin/plutil -lint "$TEMP_DIR/Sileo-Info.plist" >/dev/null
sileo_identifier=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$TEMP_DIR/Sileo-Info.plist")
[[ "$sileo_identifier" == "org.coolstar.SileoStore" ]] || \
    die "Unexpected installed Sileo bundle identifier: $sileo_identifier"

touch "$SCRIPT_DIR/.device-ssh/upstream-sshrd-finish-complete"
print "Source-parity rollback complete; Sileo remains installed at /Applications/Sileo.app"
