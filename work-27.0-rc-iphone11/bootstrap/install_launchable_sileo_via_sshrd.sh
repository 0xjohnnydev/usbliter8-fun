#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
WORK_DIR=${SCRIPT_DIR:h}
REPO_DIR=${WORK_DIR:h}
TARGET_USBMUX_ID='SSHRD_Script Sep 22 2022 18:56:50'
LOCAL_PORT=${USBLITER8_SSH_PORT:-2222}
SSHRD_PASSWORD=${USBLITER8_SSHRD_PASSWORD:-alpine}
ARTIFACT="$SCRIPT_DIR/cache/registration-refresh-24A435/Sileo.launchable-24A435.tar"
ARTIFACT_SHA256=15ce8f5519170204d6f925d962e09b0f199a32f05005ff279d626f839b8b16a5
OLD_MAIN_SHA256=27844fd380614d653cdc0f5e769ba3768bd7b713126b2ab45d4e70787f8f7df7
NEW_MAIN_SHA256=eaed7017c59fa8f89d99912cc5c4e1f8320b96b791fd74242d878a672491b857
REMOTE_APP=/mnt1/Applications/Sileo.app
REMOTE_BACKUP=/mnt1/Applications/Sileo.app.get-task-allow-24A435
REMOTE_STAGE=/mnt1/Applications/.Sileo.app.launchable-24A435.new
REMOTE_TAR=/mnt2/tmp/.usbliter8-Sileo.launchable-24A435.tar

die() {
    print -u2 -- "error: $*"
    exit 1
}

sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

for tool in iproxy ssh scp nc shasum tar; do
    command -v "$tool" >/dev/null || die "missing required tool: $tool"
done
[[ -f "$ARTIFACT" ]] || die "missing launchable Sileo artifact: $ARTIFACT"
[[ "$(sha256_of "$ARTIFACT")" == "$ARTIFACT_SHA256" ]] || \
    die "launchable Sileo artifact hash mismatch"
nc -z 127.0.0.1 "$LOCAL_PORT" >/dev/null 2>&1 && \
    die "local port $LOCAL_PORT is occupied"

SSHPASS=${USBLITER8_SSHPASS:-$(command -v sshpass || true)}
[[ -n "$SSHPASS" ]] || SSHPASS="$REPO_DIR/tools/sshpass"
[[ -x "$SSHPASS" ]] || die "no runnable sshpass found"

TEMP_DIR=$(mktemp -d /tmp/usbliter8-sileo-install.XXXXXX)
REFERENCE_DIR="$TEMP_DIR/reference"
CONTROL_PATH="$TEMP_DIR/ssh-control"
mkdir -p "$REFERENCE_DIR"
tar -xf "$ARTIFACT" -C "$REFERENCE_DIR"
REFERENCE_APP="$REFERENCE_DIR/Sileo.launchable-24A435.app"
[[ "$(sha256_of "$REFERENCE_APP/Sileo")" == "$NEW_MAIN_SHA256" ]] || \
    die "reference Sileo executable hash mismatch"
codesign --verify --deep --strict --verbose=4 "$REFERENCE_APP"

IPROXY_PID=""
cleanup() {
    if [[ -S "$CONTROL_PATH" ]]; then
        /usr/bin/ssh -S "$CONTROL_PATH" -O exit root@127.0.0.1 >/dev/null 2>&1 || true
    fi
    if [[ -n "$IPROXY_PID" ]]; then
        kill "$IPROXY_PID" >/dev/null 2>&1 || true
        wait "$IPROXY_PID" >/dev/null 2>&1 || true
    fi
    print -- "Diagnostic files retained at $TEMP_DIR"
}
trap cleanup EXIT INT TERM HUP

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

iproxy --udid "$TARGET_USBMUX_ID" "$LOCAL_PORT:22" >"$TEMP_DIR/iproxy.log" 2>&1 &
IPROXY_PID=$!

print -- "Waiting for the target SSH ramdisk"
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
(( connected )) || die "target SSH ramdisk did not answer within 60 seconds"

ssh_device '/sbin/mount | /usr/bin/grep -q "md0 on /"' || \
    die "SSH endpoint is not the expected md0 ramdisk"

print -- "Mounting System and Data read-write"
ssh_device '
set -e
/bin/mkdir -p /mnt1 /mnt2
/sbin/mount | /usr/bin/grep -q " on /mnt1 " || /sbin/mount_apfs /dev/disk1s1 /mnt1
/sbin/mount | /usr/bin/grep -q " on /mnt2 " || /sbin/mount_apfs /dev/disk1s2 /mnt2
/sbin/mount -u -o rw /dev/disk1s1
/sbin/mount -u -o rw /dev/disk1s2
test -d /mnt1/Applications
test -d /mnt2/tmp
test -d /mnt2/jb/var/mobile
test -x /mnt1/Applications/Sileo.app/Sileo
# The 34306 bootstrap archive assigns this one directory to mobile. An older
# installer flattened it to root, making the first Sileo database creation fail.
/usr/sbin/chown 501:501 /mnt2/jb/var/mobile
test "$(/usr/bin/stat -f "%u:%g" /mnt2/jb/var/mobile)" = "501:501"
'

scp_from_device "$REMOTE_APP/Sileo" "$TEMP_DIR/current-Sileo"
current_main_sha256=$(sha256_of "$TEMP_DIR/current-Sileo")
if [[ "$current_main_sha256" == "$NEW_MAIN_SHA256" ]]; then
    print -- "Launchable Sileo is already installed"
elif [[ "$current_main_sha256" != "$OLD_MAIN_SHA256" ]]; then
    die "refusing unknown current Sileo executable: $current_main_sha256"
else
    ssh_device "test ! -e '$REMOTE_BACKUP'" || \
        die "Sileo backup path already exists: $REMOTE_BACKUP"
    ssh_device "test ! -e '$REMOTE_STAGE'" || \
        die "Sileo staging path already exists: $REMOTE_STAGE"

    print -- "Uploading and independently verifying the corrected bundle"
    scp_to_device "$ARTIFACT" "$REMOTE_TAR"
    scp_from_device "$REMOTE_TAR" "$TEMP_DIR/artifact.readback.tar"
    cmp "$ARTIFACT" "$TEMP_DIR/artifact.readback.tar"

    ssh_device "
set -e
/bin/mkdir '$REMOTE_STAGE'
/usr/bin/tar -xf '$REMOTE_TAR' -C '$REMOTE_STAGE' --strip-components=1
test -x '$REMOTE_STAGE/Sileo'
test -x '$REMOTE_STAGE/giveMeRoot'
test -f '$REMOTE_STAGE/Info.plist'
test -f '$REMOTE_STAGE/_CodeSignature/CodeResources'
/usr/sbin/chown -R 0:0 '$REMOTE_STAGE'
/bin/chmod 0755 '$REMOTE_STAGE/Sileo' '$REMOTE_STAGE/giveMeRoot'
"

    scp_from_device "$REMOTE_STAGE/Sileo" "$TEMP_DIR/staged-Sileo"
    scp_from_device "$REMOTE_STAGE/giveMeRoot" "$TEMP_DIR/staged-giveMeRoot"
    scp_from_device "$REMOTE_STAGE/Info.plist" "$TEMP_DIR/staged-Info.plist"
    scp_from_device "$REMOTE_STAGE/_CodeSignature/CodeResources" "$TEMP_DIR/staged-CodeResources"
    cmp "$REFERENCE_APP/Sileo" "$TEMP_DIR/staged-Sileo"
    cmp "$REFERENCE_APP/giveMeRoot" "$TEMP_DIR/staged-giveMeRoot"
    cmp "$REFERENCE_APP/Info.plist" "$TEMP_DIR/staged-Info.plist"
    cmp "$REFERENCE_APP/_CodeSignature/CodeResources" "$TEMP_DIR/staged-CodeResources"

    print -- "Atomically replacing Sileo while preserving the prior bundle"
    ssh_device "
set -e
/bin/mv '$REMOTE_APP' '$REMOTE_BACKUP'
if ! /bin/mv '$REMOTE_STAGE' '$REMOTE_APP'; then
    /bin/mv '$REMOTE_BACKUP' '$REMOTE_APP'
    exit 1
fi
/bin/sync
test -x '$REMOTE_APP/Sileo'
test -x '$REMOTE_BACKUP/Sileo'
"
fi

scp_from_device "$REMOTE_APP/Sileo" "$TEMP_DIR/installed-Sileo"
[[ "$(sha256_of "$TEMP_DIR/installed-Sileo")" == "$NEW_MAIN_SHA256" ]] || \
    die "installed Sileo executable failed readback verification"
cmp "$REFERENCE_APP/Sileo" "$TEMP_DIR/installed-Sileo"

print -- "Unmounting cleanly"
ssh_device '
set -e
/bin/sync
/sbin/umount /mnt2
/sbin/umount /mnt1
'

print -- "SILEO_LAUNCH_FIX_INSTALLED"
