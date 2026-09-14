#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
WORK_DIR=${SCRIPT_DIR:h}
REPO_ROOT=${WORK_DIR:h}
PAYLOAD_DIR="$SCRIPT_DIR/cache/setup-bypass-24A435"
DISABLE_SCRIPT="$REPO_ROOT/patches/disable_screentime.py"

LOCAL_PORT=${USBLITER8_SSH_PORT:-2222}
SSHRD_PASSWORD=${USBLITER8_SSHRD_PASSWORD:-alpine}

typeset -A STOCK_SHA PATCHED_SHA REMOTE_PATH
STOCK_SHA[mobileactivationd]=89233513ce696cd01285f3432f3bcadd065cee07ac73bc5714836d13f24702d8
STOCK_SHA[coreauthd]=b12b67d59787d7235e45a8788e25cb1f45dfaa56aa6cfd413b759178bf8c1a14
STOCK_SHA[ctkd]=2f5861e1deaac8c4490cc4f0753c0d782bdc60408d1a6890f0cee4b78440db73

PATCHED_SHA[mobileactivationd]=0d4ef223a4f25a73f95a50c25a09ebe42c0b5ff977ed9cee69650df2aa48d0ad
PATCHED_SHA[coreauthd]=abe6b84a124a4f12aed7f3366089a9ec4819a3c68264d349589d47ec12c03072
PATCHED_SHA[ctkd]=d6ac0299b83e834dce0a26874c5c1d137ba03a85f7b17f80fc733e28f0843dba

REMOTE_PATH[mobileactivationd]=/mnt1/usr/libexec/mobileactivationd
REMOTE_PATH[coreauthd]=/mnt1/System/Library/Frameworks/LocalAuthentication.framework/Support/coreauthd
REMOTE_PATH[ctkd]=/mnt1/System/Library/Frameworks/CryptoTokenKit.framework/ctkd

components=(mobileactivationd coreauthd ctkd)

die() {
    print -u2 -- "$*"
    exit 1
}

sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

for required in iproxy ssh scp nc shasum python3 plutil codesign; do
    command -v "$required" >/dev/null 2>&1 || die "Missing required command: $required"
done
[[ -x "$DISABLE_SCRIPT" ]] || die "Missing upstream ScreenTime override tool: $DISABLE_SCRIPT"

for component in $components; do
    payload="$PAYLOAD_DIR/$component"
    [[ -f "$payload" ]] || die "Missing signed payload: $payload"
    [[ "$(sha256_of "$payload")" == "${PATCHED_SHA[$component]}" ]] || \
        die "Signed payload hash mismatch: $payload"
    /usr/bin/codesign --verify --strict "$payload" || \
        die "Signed payload does not pass codesign verification: $payload"
done

SSHPASS=${USBLITER8_SSHPASS:-$(command -v sshpass || true)}
if [[ -z "$SSHPASS" ]]; then
    SSHPASS="$REPO_ROOT/tools/sshpass"
fi
[[ -x "$SSHPASS" ]] || die "No runnable sshpass was found; set USBLITER8_SSHPASS"
nc -z 127.0.0.1 "$LOCAL_PORT" >/dev/null 2>&1 && \
    die "Local port $LOCAL_PORT is already occupied; refusing to disturb it"

TEMP_DIR=$(mktemp -d /tmp/usbliter8-setup-bypass.XXXXXX)
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

print "Waiting for the corrected 24A435 SSH ramdisk"
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
test -d /mnt2/db/com.apple.xpc.launchd
'

typeset -a install_components
install_components=()

print "Checking the three upstream Setup-bypass daemons"
for component in $components; do
    remote="${REMOTE_PATH[$component]}"
    backup="${remote}.usbliter8-stock-24A435"
    scp_from_device "$remote" "$TEMP_DIR/$component.current"
    current_sha=$(sha256_of "$TEMP_DIR/$component.current")

    if [[ "$current_sha" == "${PATCHED_SHA[$component]}" ]]; then
        print "  $component is already the verified 24A435 patched binary"
        continue
    fi
    [[ "$current_sha" == "${STOCK_SHA[$component]}" ]] || \
        die "Refusing unknown on-device $component: $current_sha"

    if ssh_device "test -f '$backup'"; then
        scp_from_device "$backup" "$TEMP_DIR/$component.backup"
        [[ "$(sha256_of "$TEMP_DIR/$component.backup")" == "${STOCK_SHA[$component]}" ]] || \
            die "Existing $component backup is not the exact 24A435 stock binary"
    else
        ssh_device "/bin/cp -p '$remote' '$backup'"
        scp_from_device "$backup" "$TEMP_DIR/$component.backup"
        [[ "$(sha256_of "$TEMP_DIR/$component.backup")" == "${STOCK_SHA[$component]}" ]] || \
            die "New $component backup failed verification"
    fi

    scp_to_device "$PAYLOAD_DIR/$component" "${remote}.usbliter8-new"
    scp_from_device "${remote}.usbliter8-new" "$TEMP_DIR/$component.staged"
    [[ "$(sha256_of "$TEMP_DIR/$component.staged")" == "${PATCHED_SHA[$component]}" ]] || \
        die "Staged $component failed read-back verification"
    install_components+=("$component")
done

REMOTE_DISABLED=/mnt2/db/com.apple.xpc.launchd/disabled.plist
REMOTE_DISABLED_BACKUP=${REMOTE_DISABLED}.usbliter8-before-setup-bypass
if ssh_device "test -f '$REMOTE_DISABLED'"; then
    scp_from_device "$REMOTE_DISABLED" "$TEMP_DIR/disabled.plist"
    if ! ssh_device "test -f '$REMOTE_DISABLED_BACKUP'"; then
        ssh_device "/bin/cp -p '$REMOTE_DISABLED' '$REMOTE_DISABLED_BACKUP'"
    fi
fi

print "Applying 34306's ScreenTime/FamilyControls launchd overrides"
/usr/bin/python3 "$DISABLE_SCRIPT" "$TEMP_DIR/disabled.plist"
/usr/bin/plutil -lint "$TEMP_DIR/disabled.plist" >/dev/null
scp_to_device "$TEMP_DIR/disabled.plist" "${REMOTE_DISABLED}.usbliter8-new"
scp_from_device "${REMOTE_DISABLED}.usbliter8-new" "$TEMP_DIR/disabled.staged.plist"
cmp "$TEMP_DIR/disabled.plist" "$TEMP_DIR/disabled.staged.plist"

print "Installing verified files atomically"
for component in $install_components; do
    remote="${REMOTE_PATH[$component]}"
    ssh_device "
set -e
/usr/bin/chflags nouchg,noschg '$remote' 2>/dev/null || true
/usr/sbin/chown 0:0 '${remote}.usbliter8-new'
/bin/chmod 0755 '${remote}.usbliter8-new'
/bin/mv -f '${remote}.usbliter8-new' '$remote'
"
done

ssh_device "
set -e
/usr/sbin/chown 0:0 '${REMOTE_DISABLED}.usbliter8-new'
/bin/chmod 0644 '${REMOTE_DISABLED}.usbliter8-new'
/bin/mv -f '${REMOTE_DISABLED}.usbliter8-new' '$REMOTE_DISABLED'
/bin/sync
"

print "Reading every installed file back for final verification"
for component in $components; do
    remote="${REMOTE_PATH[$component]}"
    scp_from_device "$remote" "$TEMP_DIR/$component.installed"
    [[ "$(sha256_of "$TEMP_DIR/$component.installed")" == "${PATCHED_SHA[$component]}" ]] || \
        die "Installed $component failed final verification"
done
scp_from_device "$REMOTE_DISABLED" "$TEMP_DIR/disabled.installed.plist"
cmp "$TEMP_DIR/disabled.plist" "$TEMP_DIR/disabled.installed.plist"
/usr/bin/python3 "$DISABLE_SCRIPT" --show "$TEMP_DIR/disabled.installed.plist"

print "Upstream Setup bypass is installed and verified; reboot to PWN DFU for the normal tethered boot"
