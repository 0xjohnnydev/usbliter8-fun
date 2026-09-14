#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
KEY_DIR="$SCRIPT_DIR/.device-ssh"
CLIENT_KEY="$KEY_DIR/iphone11-24A435"
KNOWN_HOSTS="$KEY_DIR/known_hosts"
DEVICE_UDID=${USBLITER8_DEVICE_UDID:-}
LOCAL_PORT=${USBLITER8_NORMAL_SSH_PORT:-2222}

die() {
    print -u2 -- "$*"
    exit 1
}

for required in idevice_id iproxy ssh nc; do
    command -v "$required" >/dev/null 2>&1 || die "Missing required command: $required"
done
[[ -n "$DEVICE_UDID" ]] || die "Set USBLITER8_DEVICE_UDID to the target's usbmux UDID"
[[ -f "$KEY_DIR/sshrd-install-complete" ]] || \
    die "The SSHRD bootstrap staging marker is missing"
[[ -f "$CLIENT_KEY" && -f "$CLIENT_KEY.pub" ]] || \
    die "The per-device SSH client key is missing"

idevice_id -l 2>/dev/null | /usr/bin/grep -qx "$DEVICE_UDID" || \
    die "The iPhone is not currently enumerated in normal usbmux mode"
if nc -z 127.0.0.1 "$LOCAL_PORT" >/dev/null 2>&1; then
    die "Local port $LOCAL_PORT is already occupied; refusing to disturb it"
fi

TEMP_DIR=$(mktemp -d /tmp/usbliter8-bootstrap-finish.XXXXXX)
IPROXY_PID=""
cleanup() {
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
    -i "$CLIENT_KEY"
    -o IdentitiesOnly=yes
    -o PreferredAuthentications=publickey
    -o PasswordAuthentication=no
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile="$KNOWN_HOSTS"
    -o ConnectTimeout=3
    -o LogLevel=ERROR
    -p "$LOCAL_PORT"
)

print "Waiting for key-only Dropbear on normal iOS"
connected=0
for attempt in {1..45}; do
    if ! kill -0 "$IPROXY_PID" >/dev/null 2>&1; then
        sed -n '1,120p' "$TEMP_DIR/iproxy.log" >&2
        die "iproxy exited before Dropbear became reachable"
    fi
    if /usr/bin/ssh "${SSH_OPTIONS[@]}" root@127.0.0.1 /usr/bin/true \
        >/dev/null 2>&1; then
        connected=1
        break
    fi
    sleep 1
done
(( connected )) || die "Dropbear did not answer within 45 seconds"

print "Finishing Procursus and installing Sileo"
/usr/bin/ssh "${SSH_OPTIONS[@]}" root@127.0.0.1 '
set -e
export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin
test -f /var/jb/.procursus_strapped
test -x /var/jb/usr/bin/dpkg
test -x /var/jb/usr/bin/uicache
test -f /var/jb/sileo.deb

if test -x /var/jb/prep_bootstrap.sh; then
    NO_PASSWORD_PROMPT=1 /var/jb/prep_bootstrap.sh
fi

/var/jb/usr/bin/dpkg -i /var/jb/sileo.deb
test -x /var/jb/Applications/Sileo.app/Sileo
/var/jb/usr/bin/uicache -p /var/jb/Applications/Sileo.app

echo "ROOT_SHELL=$(/var/jb/usr/bin/id -u):$(/var/jb/usr/bin/id -g)"
printf "SILEO="
/var/jb/usr/bin/dpkg-query -W -f="\${Status} \${Version}\n" org.coolstar.sileo
echo "BOOTSTRAP_READY"
'

touch "$KEY_DIR/normal-finish-complete"
print "Normal-mode root SSH, Procursus, arbitrary bootstrap binaries, and Sileo are verified."
