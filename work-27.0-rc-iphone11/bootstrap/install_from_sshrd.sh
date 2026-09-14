#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
WORK_DIR=${SCRIPT_DIR:h}
REPO_ROOT=${WORK_DIR:h}

BOOTSTRAP_ARCHIVE="$REPO_ROOT/work-27.0b2/bootstrap_1900.tar.zst"
SSH_ARCHIVE="$REPO_ROOT/work-27.0b2/ssh.tar.gz"
LAUNCHD_PLIST="$SCRIPT_DIR/com.usbliter8.dropbear.plist"
LAUNCHD_CACHE_PATCHER="$SCRIPT_DIR/inject_launchd_job.py"
LAUNCHD_CACHE_KEY="/System/Library/LaunchDaemons/com.usbliter8.dropbear.plist"

BOOTSTRAP_SHA256="8354c3aa1ecdad8ebc47d9a76dfca6f830a2b757278068bd33b98bf1d638a9cb"
DROPBEAR_SHA256="89e789cd3ca755daa0cbc9b52a10f2373b021460a7c5a0cbd7a3a705126c5553"
SILEO_VERSION="2.5.1"
SILEO_NAME="org.coolstar.sileo_${SILEO_VERSION}_iphoneos-arm64.deb"
SILEO_SHA256="8e3c90e5a7d32f4ca207a0ac30d3cfa8a13dca86a2b4e11cb3f9e5c68d7bc97a"
SILEO_URL="https://github.com/Sileo/Sileo/releases/download/${SILEO_VERSION}/${SILEO_NAME}"

CACHE_DIR="$SCRIPT_DIR/cache"
SILEO_DEB="$CACHE_DIR/$SILEO_NAME"
KEY_DIR="$SCRIPT_DIR/.device-ssh"
CLIENT_KEY="$KEY_DIR/iphone11-24A435"
LAUNCHER="$CACHE_DIR/normal-ssh-24A435/usbliter8-dropbear-launcher"
LAUNCHER_SHA256="105b989284baef79d9d2884e6070efaaadbdb065b52a4ad27768f4e5cce392e4"

LOCAL_PORT=${USBLITER8_SSH_PORT:-2222}
SSHRD_PASSWORD=${USBLITER8_SSHRD_PASSWORD:-alpine}

die() {
    print -u2 -- "$*"
    exit 1
}

sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

for required in zstd curl iproxy ssh scp ssh-keygen nc python3; do
    command -v "$required" >/dev/null 2>&1 || die "Missing required command: $required"
done
[[ -f "$BOOTSTRAP_ARCHIVE" ]] || die "Missing bootstrap: $BOOTSTRAP_ARCHIVE"
[[ -f "$SSH_ARCHIVE" ]] || die "Missing SSH payload: $SSH_ARCHIVE"
[[ -f "$LAUNCHD_PLIST" ]] || die "Missing launchd plist: $LAUNCHD_PLIST"
[[ -f "$LAUNCHD_CACHE_PATCHER" ]] || die "Missing launchd cache patcher: $LAUNCHD_CACHE_PATCHER"
[[ "$(sha256_of "$BOOTSTRAP_ARCHIVE")" == "$BOOTSTRAP_SHA256" ]] || \
    die "The bootstrap archive does not match the audited SHA-256"
[[ -f "$LAUNCHER" ]] || die "Missing System-resident Dropbear launcher: $LAUNCHER"
[[ "$(sha256_of "$LAUNCHER")" == "$LAUNCHER_SHA256" ]] || \
    die "The System-resident Dropbear launcher failed SHA-256 verification"
/usr/bin/codesign --verify --strict "$LAUNCHER" || \
    die "The System-resident Dropbear launcher failed code-signature verification"
/usr/bin/plutil -lint "$LAUNCHD_PLIST" >/dev/null

mkdir -p "$CACHE_DIR" "$KEY_DIR"
chmod 700 "$KEY_DIR"

if [[ ! -f "$SILEO_DEB" ]]; then
    download="$SILEO_DEB.download.$$"
    curl -fL --retry 3 -o "$download" "$SILEO_URL"
    if [[ "$(sha256_of "$download")" != "$SILEO_SHA256" ]]; then
        die "Downloaded Sileo package failed SHA-256 verification: $download"
    fi
    mv "$download" "$SILEO_DEB"
fi
[[ "$(sha256_of "$SILEO_DEB")" == "$SILEO_SHA256" ]] || \
    die "Cached Sileo package failed SHA-256 verification"

if [[ -e "$CLIENT_KEY" && ! -e "$CLIENT_KEY.pub" ]] || \
   [[ ! -e "$CLIENT_KEY" && -e "$CLIENT_KEY.pub" ]]; then
    die "Only one half of the device SSH client key exists in $KEY_DIR"
fi
if [[ ! -e "$CLIENT_KEY" ]]; then
    ssh-keygen -q -t ecdsa -b 256 -N "" -C "usbliter8-iphone11-24A435" -f "$CLIENT_KEY"
fi
chmod 600 "$CLIENT_KEY"
chmod 644 "$CLIENT_KEY.pub"
ssh-keygen -l -f "$CLIENT_KEY.pub"

SSHPASS=${USBLITER8_SSHPASS:-$(command -v sshpass || true)}
if [[ -z "$SSHPASS" ]]; then
    SSHPASS="$REPO_ROOT/tools/sshpass"
fi
[[ -x "$SSHPASS" ]] || die "No runnable sshpass was found; set USBLITER8_SSHPASS"

if nc -z 127.0.0.1 "$LOCAL_PORT" >/dev/null 2>&1; then
    die "Local port $LOCAL_PORT is already occupied; refusing to disturb it"
fi

TEMP_DIR=$(mktemp -d /tmp/usbliter8-bootstrap-install.XXXXXX)
CONTROL_PATH="$TEMP_DIR/ssh-control"
IPROXY_PID=""
TEST_IPROXY_PID=""
cleanup() {
    if [[ -S "$CONTROL_PATH" ]]; then
        /usr/bin/ssh -S "$CONTROL_PATH" -O exit root@127.0.0.1 \
            >/dev/null 2>&1 || true
    fi
    if [[ -n "$IPROXY_PID" ]]; then
        kill "$IPROXY_PID" >/dev/null 2>&1 || true
        wait "$IPROXY_PID" >/dev/null 2>&1 || true
    fi
    if [[ -n "$TEST_IPROXY_PID" ]]; then
        kill "$TEST_IPROXY_PID" >/dev/null 2>&1 || true
        wait "$TEST_IPROXY_PID" >/dev/null 2>&1 || true
    fi
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT INT TERM HUP

/usr/bin/tar -xzf "$SSH_ARCHIVE" -C "$TEMP_DIR" usr/local/bin/dropbear
DROPBEAR_LOCAL="$TEMP_DIR/usr/local/bin/dropbear"
[[ "$(sha256_of "$DROPBEAR_LOCAL")" == "$DROPBEAR_SHA256" ]] || \
    die "Bundled Dropbear failed SHA-256 verification"

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

print "Waiting for the SSH ramdisk on localhost:$LOCAL_PORT"
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
    die "SSH endpoint is not the expected md0 ramdisk; refusing all writes"
ssh_device '/usr/bin/tar --help 2>&1 | /usr/bin/grep -q strip-components' || \
    die "The SSHRD tar lacks --strip-components; refusing an unsafe extraction"
ssh_device 'test -x /usr/local/bin/dropbearkey' || \
    die "The SSHRD is missing dropbearkey"

print "Mounting the restored System and Data volumes read-write"
ssh_device '
set -e
/bin/mkdir -p /mnt1 /mnt2
/sbin/mount | /usr/bin/grep -q " on /mnt1 " || /sbin/mount_apfs /dev/disk1s1 /mnt1
/sbin/mount | /usr/bin/grep -q " on /mnt2 " || /sbin/mount_apfs /dev/disk1s2 /mnt2
/sbin/mount -u -o rw /dev/disk1s1
/sbin/mount -u -o rw /dev/disk1s2
test -d /mnt1/System/Library/LaunchDaemons
test -d /mnt2/mobile
test -d /mnt2/root
test -d /mnt2/preferences
'

if ssh_device 'test -x /bin/df && test -x /usr/bin/awk'; then
    free_kb=$(ssh_device "/bin/df -k /mnt2 | /usr/bin/awk 'END {print \$4}'")
    [[ "$free_kb" == <-> ]] || die "Could not parse Data-volume free space"
    (( free_kb >= 262144 )) || die "Data has less than 256 MiB free; refusing bootstrap install"
    print "Data-volume free space: $(( free_kb / 1024 )) MiB"
else
    print "SSHRD has no df/awk; relying on verified atomic staging for ENOSPC safety"
fi

REMOTE_PLIST="/mnt1/System/Library/LaunchDaemons/com.usbliter8.dropbear.plist"
REMOTE_LAUNCHER="/mnt1/usr/local/libexec/usbliter8-dropbear-launcher"
if ssh_device "test -e '$REMOTE_PLIST'"; then
    scp_from_device "$REMOTE_PLIST" "$TEMP_DIR/existing-dropbear.plist"
    cmp -s "$LAUNCHD_PLIST" "$TEMP_DIR/existing-dropbear.plist" || \
        die "An unknown $REMOTE_PLIST already exists; refusing to replace it"
fi
if ssh_device "test -e '$REMOTE_LAUNCHER'"; then
    scp_from_device "$REMOTE_LAUNCHER" "$TEMP_DIR/existing-dropbear-launcher"
    cmp -s "$LAUNCHER" "$TEMP_DIR/existing-dropbear-launcher" || \
        die "An unknown $REMOTE_LAUNCHER already exists; refusing to replace it"
fi

bootstrap_state=$(ssh_device '
if test -f /mnt2/jb/.procursus_strapped; then
    echo installed
elif test -e /mnt2/jb; then
    echo unknown
else
    echo absent
fi
')
if [[ "$bootstrap_state" == "unknown" ]]; then
    die "Data already contains /mnt2/jb without the Procursus marker; refusing to overwrite it"
fi

if [[ "$bootstrap_state" == "absent" ]]; then
    print "Staging the audited Procursus bootstrap"
    ssh_device '
        test ! -e /mnt2/.usbliter8-jb.new
        /bin/mkdir /mnt2/.usbliter8-jb.new
    '
    zstd -dc "$BOOTSTRAP_ARCHIVE" | \
        /usr/bin/ssh "${SSH_OPTIONS[@]}" root@127.0.0.1 \
        '/usr/bin/tar -xpf - --strip-components 3 -C /mnt2/.usbliter8-jb.new'
    ssh_device '
        set -e
        test -f /mnt2/.usbliter8-jb.new/.procursus_strapped
        test -x /mnt2/.usbliter8-jb.new/usr/bin/dpkg
        test -x /mnt2/.usbliter8-jb.new/usr/bin/apt
        test -x /mnt2/.usbliter8-jb.new/usr/bin/uicache
        test -x /mnt2/.usbliter8-jb.new/prep_bootstrap.sh
        /usr/sbin/chown -R 0:0 /mnt2/.usbliter8-jb.new
        # The audited 34306 archive has exactly one non-root-owned entry. Sileo
        # runs as mobile and must be able to create its cache/database tree.
        /usr/sbin/chown 501:501 /mnt2/.usbliter8-jb.new/var/mobile
        /bin/mv /mnt2/.usbliter8-jb.new /mnt2/jb
        /bin/sync
    '
else
    print "A marked Procursus bootstrap already exists; verifying it for an idempotent resume"
    ssh_device '
        test -x /mnt2/jb/usr/bin/dpkg
        test -x /mnt2/jb/usr/bin/apt
        test -x /mnt2/jb/usr/bin/uicache
    '
fi

# Repair installs made by older revisions of this script, which flattened the
# archive's mobile ownership to root and made Sileo's first launch fatal.
ssh_device '
    set -e
    test -d /mnt2/jb/var/mobile
    /usr/sbin/chown 501:501 /mnt2/jb/var/mobile
    test "$(/usr/bin/stat -f "%u:%g" /mnt2/jb/var/mobile)" = "501:501"
'

print "Staging the verified Sileo package for normal-mode dpkg"
scp_to_device "$SILEO_DEB" /mnt2/jb/.sileo.deb.new
scp_from_device /mnt2/jb/.sileo.deb.new "$TEMP_DIR/sileo.readback"
cmp "$SILEO_DEB" "$TEMP_DIR/sileo.readback"
ssh_device '
    /usr/sbin/chown 0:0 /mnt2/jb/.sileo.deb.new
    /bin/chmod 0644 /mnt2/jb/.sileo.deb.new
    /bin/mv -f /mnt2/jb/.sileo.deb.new /mnt2/jb/sileo.deb
'

print "Installing key-only Dropbear into the bootstrap"
ssh_device '/bin/mkdir -p /mnt2/jb/usr/local/bin /mnt2/jb/etc/dropbear /mnt2/root/.ssh'
scp_to_device "$DROPBEAR_LOCAL" /mnt2/jb/usr/local/bin/.dropbear.new
scp_to_device "$CLIENT_KEY.pub" /mnt2/root/.ssh/.usbliter8-authorized-key.new
ssh_device '
set -e
/usr/sbin/chown 0:0 /mnt2/jb/usr/local/bin/.dropbear.new
/bin/chmod 0755 /mnt2/jb/usr/local/bin/.dropbear.new
/bin/mv -f /mnt2/jb/usr/local/bin/.dropbear.new /mnt2/jb/usr/local/bin/dropbear

if test ! -s /mnt2/jb/etc/dropbear/dropbear_ecdsa_host_key; then
    /usr/local/bin/dropbearkey -t ecdsa -s 256 \
        -f /mnt2/jb/etc/dropbear/dropbear_ecdsa_host_key >/dev/null
fi
/usr/sbin/chown 0:0 /mnt2/jb/etc/dropbear/dropbear_ecdsa_host_key
/bin/chmod 0600 /mnt2/jb/etc/dropbear/dropbear_ecdsa_host_key

key_type=""
key_blob=""
key_comment=""
IFS=" " read -r key_type key_blob key_comment < /mnt2/root/.ssh/.usbliter8-authorized-key.new
test -n "$key_blob"
/usr/bin/grep -Fq "$key_blob" /mnt2/root/.ssh/authorized_keys 2>/dev/null || \
    /bin/cat /mnt2/root/.ssh/.usbliter8-authorized-key.new >> /mnt2/root/.ssh/authorized_keys
/bin/rm -f /mnt2/root/.ssh/.usbliter8-authorized-key.new
/usr/sbin/chown -R 0:0 /mnt2/root/.ssh
/bin/chmod 0700 /mnt2/root/.ssh
/bin/chmod 0600 /mnt2/root/.ssh/authorized_keys
'

print "Installing the System-resident launch shim and normal-boot Dropbear job"
ssh_device '/bin/mkdir -p /mnt1/usr/local/libexec'
scp_to_device "$LAUNCHER" /mnt1/usr/local/libexec/.usbliter8-dropbear-launcher.new
scp_to_device "$LAUNCHD_PLIST" /mnt1/System/Library/LaunchDaemons/.com.usbliter8.dropbear.plist.new
scp_from_device \
    /mnt1/usr/local/libexec/.usbliter8-dropbear-launcher.new \
    "$TEMP_DIR/dropbear-launcher.staged"
scp_from_device \
    /mnt1/System/Library/LaunchDaemons/.com.usbliter8.dropbear.plist.new \
    "$TEMP_DIR/dropbear-plist.staged"
cmp "$LAUNCHER" "$TEMP_DIR/dropbear-launcher.staged"
cmp "$LAUNCHD_PLIST" "$TEMP_DIR/dropbear-plist.staged"
ssh_device '
set -e
/usr/sbin/chown 0:0 /mnt1/usr/local/libexec/.usbliter8-dropbear-launcher.new
/bin/chmod 0755 /mnt1/usr/local/libexec/.usbliter8-dropbear-launcher.new
/bin/mv -f /mnt1/usr/local/libexec/.usbliter8-dropbear-launcher.new \
    /mnt1/usr/local/libexec/usbliter8-dropbear-launcher
/usr/sbin/chown 0:0 /mnt1/System/Library/LaunchDaemons/.com.usbliter8.dropbear.plist.new
/bin/chmod 0644 /mnt1/System/Library/LaunchDaemons/.com.usbliter8.dropbear.plist.new
/bin/mv -f /mnt1/System/Library/LaunchDaemons/.com.usbliter8.dropbear.plist.new \
    /mnt1/System/Library/LaunchDaemons/com.usbliter8.dropbear.plist
/bin/sync
test -x /mnt2/jb/usr/local/bin/dropbear
test -s /mnt2/jb/etc/dropbear/dropbear_ecdsa_host_key
test -s /mnt2/root/.ssh/authorized_keys
test -f /mnt2/jb/sileo.deb
test -x /mnt1/usr/local/libexec/usbliter8-dropbear-launcher
test -f /mnt1/System/Library/LaunchDaemons/com.usbliter8.dropbear.plist
'

scp_from_device /mnt2/jb/usr/local/bin/dropbear "$TEMP_DIR/dropbear.readback"
scp_from_device "$REMOTE_LAUNCHER" "$TEMP_DIR/dropbear-launcher.readback"
scp_from_device "$REMOTE_PLIST" "$TEMP_DIR/dropbear-plist.readback"
cmp "$DROPBEAR_LOCAL" "$TEMP_DIR/dropbear.readback"
cmp "$LAUNCHER" "$TEMP_DIR/dropbear-launcher.readback"
cmp "$LAUNCHD_PLIST" "$TEMP_DIR/dropbear-plist.readback"

print "Registering Dropbear in the iOS launchd cache"
REMOTE_CACHE="/mnt1/System/Library/xpc/launchd.plist"
REMOTE_CACHE_BACKUP="${REMOTE_CACHE}.usbliter8-original"
ssh_device "test -f '$REMOTE_CACHE'" || die "The device has no $REMOTE_CACHE"

if ! ssh_device "test -f '$REMOTE_CACHE_BACKUP'"; then
    ssh_device "
        set -e
        /bin/cp -p '$REMOTE_CACHE' '$REMOTE_CACHE_BACKUP'
        /bin/sync
        test -f '$REMOTE_CACHE_BACKUP'
    "
fi

scp_from_device "$REMOTE_CACHE" "$TEMP_DIR/launchd.current.plist"
scp_from_device "$REMOTE_CACHE_BACKUP" "$TEMP_DIR/launchd.original.plist"
/usr/bin/plutil -lint "$TEMP_DIR/launchd.current.plist" >/dev/null || \
    die "The current launchd cache failed host-side plist validation"
/usr/bin/plutil -lint "$TEMP_DIR/launchd.original.plist" >/dev/null || \
    die "The backed-up launchd cache failed host-side plist validation"

backup_stamp=$(date -u +%Y%m%dT%H%M%SZ)
backup_dir="$CACHE_DIR/device-backups"
mkdir -p "$backup_dir"
/bin/cp "$TEMP_DIR/launchd.current.plist" \
    "$backup_dir/launchd.plist.before-cache-injection.$backup_stamp"
/bin/cp "$TEMP_DIR/launchd.original.plist" \
    "$backup_dir/launchd.plist.usbliter8-original.$backup_stamp"

/usr/bin/python3 "$LAUNCHD_CACHE_PATCHER" \
    --key "$LAUNCHD_CACHE_KEY" \
    "$TEMP_DIR/launchd.current.plist" "$LAUNCHD_PLIST" \
    "$TEMP_DIR/launchd.patched.plist"
/usr/bin/plutil -lint "$TEMP_DIR/launchd.patched.plist" >/dev/null || \
    die "The patched launchd cache failed host-side plist validation"

scp_to_device "$TEMP_DIR/launchd.patched.plist" "${REMOTE_CACHE}.usbliter8-new"
scp_from_device "${REMOTE_CACHE}.usbliter8-new" "$TEMP_DIR/launchd.staged.readback"
cmp "$TEMP_DIR/launchd.patched.plist" "$TEMP_DIR/launchd.staged.readback"
ssh_device "
    set -e
    /usr/sbin/chown 0:0 '${REMOTE_CACHE}.usbliter8-new'
    /bin/chmod 0644 '${REMOTE_CACHE}.usbliter8-new'
    /bin/mv -f '${REMOTE_CACHE}.usbliter8-new' '$REMOTE_CACHE'
    /bin/sync
    test -f '$REMOTE_CACHE'
"
scp_from_device "$REMOTE_CACHE" "$TEMP_DIR/launchd.final.readback"
cmp "$TEMP_DIR/launchd.patched.plist" "$TEMP_DIR/launchd.final.readback"

print "Proving the System launcher and Data-backed Dropbear work together"
TEST_LOCAL_PORT=${USBLITER8_LAUNCHER_TEST_PORT:-2223}
nc -z 127.0.0.1 "$TEST_LOCAL_PORT" >/dev/null 2>&1 && \
    die "Local launcher-test port $TEST_LOCAL_PORT is already occupied"
ssh_device '
set -e
/sbin/umount /mnt2
/sbin/mount_apfs /dev/disk1s2 /private/var
/sbin/mount -u -o rw /dev/disk1s2
test -f /var/jb/.procursus_strapped
test -x /var/jb/usr/local/bin/dropbear
test -s /var/jb/etc/dropbear/dropbear_ecdsa_host_key
test -s /var/root/.ssh/authorized_keys
/mnt1/usr/local/libexec/usbliter8-dropbear-launcher 2222 \
    >/private/var/tmp/usbliter8-launcher-test.log 2>&1 &
'
iproxy "$TEST_LOCAL_PORT:2222" >"$TEMP_DIR/iproxy-test.log" 2>&1 &
TEST_IPROXY_PID=$!
TEST_SSH_OPTIONS=(
    -i "$CLIENT_KEY"
    -o IdentitiesOnly=yes
    -o PreferredAuthentications=publickey
    -o PasswordAuthentication=no
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=3
    -o LogLevel=ERROR
    -p "$TEST_LOCAL_PORT"
)
launcher_tested=0
for attempt in {1..20}; do
    if /usr/bin/ssh "${TEST_SSH_OPTIONS[@]}" root@127.0.0.1 \
        'test "$(/usr/bin/id -u)" = 0 && test -x /var/jb/usr/bin/uicache' \
        >/dev/null 2>&1; then
        launcher_tested=1
        break
    fi
    sleep 1
done
if (( ! launcher_tested )); then
    ssh_device '/bin/cat /private/var/tmp/usbliter8-launcher-test.log 2>/dev/null || true' >&2
    die "The installed System launcher did not produce a working Dropbear server"
fi
print "System launcher test passed with key-only root SSH"
ssh_device '
if test -f /var/run/usbliter8-dropbear.pid; then
    /bin/kill "$(/bin/cat /var/run/usbliter8-dropbear.pid)" 2>/dev/null || true
fi
'

touch "$KEY_DIR/sshrd-install-complete"
print "Bootstrap staging verified. Boot normal iOS, then run:"
print "  $SCRIPT_DIR/finish_normal.sh"
