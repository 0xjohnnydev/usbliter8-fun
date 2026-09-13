#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
cd "$SCRIPT_DIR"

LOCAL_PORT=${SSHRD_LOCAL_PORT:-2222}
SSHRD_PASSWORD=${SSHRD_PASSWORD:-alpine}
RUN_ID=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="$SCRIPT_DIR/diagnostic-logs/sshrd-$RUN_ID"
CONTROL_SOCKET="/tmp/usbliter8-ssh-$$.sock"
mkdir -p "$OUTPUT_DIR/tickets" "$OUTPUT_DIR/crash-files"

for required in iproxy nc ssh scp; do
    if ! command -v "$required" >/dev/null 2>&1; then
        print -u2 "Missing required command: $required"
        exit 1
    fi
done
if [[ ! -x ./sshrd_expect.exp ]]; then
    print -u2 "Missing executable helper: ./sshrd_expect.exp"
    exit 1
fi
if nc -z 127.0.0.1 "$LOCAL_PORT" >/dev/null 2>&1; then
    print -u2 "Local port $LOCAL_PORT is already in use; refusing to disturb it"
    exit 1
fi

IPROXY_PID=""
cleanup() {
    set +e
    if [[ -S "$CONTROL_SOCKET" ]]; then
        /usr/bin/ssh -S "$CONTROL_SOCKET" -O exit root@127.0.0.1 >/dev/null 2>&1
    fi
    if [[ -n "$IPROXY_PID" ]] && kill -0 "$IPROXY_PID" >/dev/null 2>&1; then
        kill "$IPROXY_PID" >/dev/null 2>&1
        wait "$IPROXY_PID" >/dev/null 2>&1
    fi
    rm -f "$CONTROL_SOCKET"
}
trap cleanup EXIT INT TERM HUP

iproxy "$LOCAL_PORT" 22 >"$OUTPUT_DIR/iproxy.log" 2>&1 &
IPROXY_PID=$!

SSH_OPTIONS=(
    -S "$CONTROL_SOCKET"
    -p "$LOCAL_PORT"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=5
)

print "Waiting for the SSH ramdisk on localhost:$LOCAL_PORT ..."
authenticated=0
for attempt in {1..30}; do
    if ! kill -0 "$IPROXY_PID" >/dev/null 2>&1; then
        print -u2 "iproxy exited before SSH became available"
        sed -n '1,120p' "$OUTPUT_DIR/iproxy.log" >&2
        exit 1
    fi

    if SSHRD_PASSWORD="$SSHRD_PASSWORD" ./sshrd_expect.exp \
        /usr/bin/ssh -M -fN "${SSH_OPTIONS[@]}" -o ControlPersist=120 root@127.0.0.1; then
        authenticated=1
        break
    fi
    sleep 2
done
if (( ! authenticated )); then
    print -u2 "The SSH ramdisk did not become reachable after 60 seconds"
    exit 1
fi

ssh_remote() {
    /usr/bin/ssh "${SSH_OPTIONS[@]}" root@127.0.0.1 "$@"
}

print "Connected. Capturing the APFS layout ..."
ssh_remote '/bin/ls -l /dev/disk*; /usr/sbin/diskutil apfs list 2>&1 || true; /sbin/mount' \
    >"$OUTPUT_DIR/device-layout.txt"

print "Mounting Preboot read-only and locating the installed SEP ticket ..."
ssh_remote '/bin/mkdir -p /mnt6; /sbin/mount | /usr/bin/grep -q " on /mnt6 " || /sbin/mount_apfs -o rdonly /dev/disk1s6 /mnt6'
ticket_listing=$(ssh_remote '/usr/bin/find /mnt6 -type f -name sep-firmware.img4 -print')
print -r -- "$ticket_listing" >"$OUTPUT_DIR/preboot-sep-files.txt"
if [[ -z "$ticket_listing" ]]; then
    print -u2 "No sep-firmware.img4 was found on Preboot"
    exit 1
fi

ticket_paths=("${(@f)ticket_listing}")
selected_ticket=""
index=0
for remote_path in "${ticket_paths[@]}"; do
    (( index += 1 ))
    if [[ "$remote_path" != /mnt6/* || "$remote_path" == *[[:space:]]* ]]; then
        print -u2 "Skipping an unsafe Preboot path: $remote_path"
        continue
    fi

    prefix=$(printf 'candidate-%02d' "$index")
    sep_path="$OUTPUT_DIR/tickets/$prefix.sep-firmware.img4"
    ticket_path="$OUTPUT_DIR/tickets/$prefix.apticket.der"
    details_path="$OUTPUT_DIR/tickets/$prefix.apticket.txt"
    verify_path="$OUTPUT_DIR/tickets/$prefix.verify.txt"

    /usr/bin/scp -O -q \
        -o "ControlPath=$CONTROL_SOCKET" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -P "$LOCAL_PORT" \
        "root@127.0.0.1:$remote_path" "$sep_path"

    if ! ../tools/img4tool -e -m "$ticket_path" "$sep_path" \
        >"$OUTPUT_DIR/tickets/$prefix.extract.txt" 2>&1; then
        print -u2 "Could not extract an IM4M from $remote_path"
        continue
    fi
    ../tools/img4tool -a "$ticket_path" >"$details_path" 2>&1
    ../tools/img4tool --verify=CFW/BuildManifest.plist "$ticket_path" \
        >"$verify_path" 2>&1 || true

    valid=1
    expected_fields=(
        '[BNCH]: BNCH: 7fc8be52e2dd6ba8a446bacc35773b48b01ca2b4679a137fac5f1ea7c0277f05'
        '[BORD]: BORD: 4'
        '[CHIP]: CHIP: 32816'
        '[ECID]: ECID: 7147547156054062'
        '[love]: love: 24.1.435.0.0,0'
        '[prtp]: prtp: iPhone12,1'
        '[snon]: snon: e6e9d383525b15d1bb0613b662fa0e4de468ac4a'
        '[tagt]: tagt: N104AP'
        '[tatp]: tatp: n104'
    )
    for expected in "${expected_fields[@]}"; do
        if ! grep -Fq "$expected" "$details_path"; then
            valid=0
            print -u2 "$prefix is missing expected field: $expected"
        fi
    done
    if ! grep -Fq 'IM4M signature is verified by TssAuthority' "$verify_path"; then
        valid=0
        print -u2 "$prefix did not pass the TssAuthority signature check"
    fi

    if (( valid )) && [[ -z "$selected_ticket" ]]; then
        selected_ticket="$ticket_path"
        cp "$ticket_path" "$OUTPUT_DIR/device-apticket.der"
    fi
done

if [[ -z "$selected_ticket" ]]; then
    print -u2 "No extracted ticket matched the successful restore identity and nonces"
    exit 1
fi

{
    print 'Exact ticket embedded in the restored Preboot SEP wrapper:'
    shasum -a 256 "$OUTPUT_DIR/device-apticket.der"
    print 'Current locally regenerated ticket:'
    shasum -a 256 t8030_apticket.der
    if cmp -s "$OUTPUT_DIR/device-apticket.der" t8030_apticket.der; then
        print 'Comparison: byte-identical'
    else
        print 'Comparison: DIFFERENT'
    fi
    ../tools/img4tool -a "$OUTPUT_DIR/device-apticket.der" 2>&1 | \
        grep -E '\[(BNCH|BORD|CHIP|ECID|snon|srvn|tagt|tatp|love|prtp)\]'
} >"$OUTPUT_DIR/ticket-summary.txt"

print "Trying to mount Data read-only for recent failure evidence ..."
if ssh_remote '/bin/mkdir -p /mnt2; /sbin/mount | /usr/bin/grep -q " on /mnt2 " || /sbin/mount_apfs -o rdonly /dev/disk1s2 /mnt2' \
    >"$OUTPUT_DIR/data-mount.txt" 2>&1; then
    ssh_remote '
        : > /tmp/usbliter8-diagnostic-paths.txt
        for directory in \
            /mnt2/mobile/Library/Logs/CrashReporter \
            /mnt2/logs/CrashReporter \
            /mnt2/Library/Logs/CrashReporter \
            /mnt2/root/Library/Logs/CrashReporter
        do
            if [ -d "$directory" ]; then
                /usr/bin/find "$directory" -type f -mtime -2 \
                    \( -name "*.ips" \
                    -o -name "panic-full*" \
                    -o -name "*SpringBoard*" \
                    -o -name "*launchd*" \
                    -o -name "*watchdog*" \
                    -o -name "*resetcounter*" \
                    -o -name "*kernel*" \) -print
            fi
        done | /usr/bin/head -n 100 > /tmp/usbliter8-diagnostic-paths.txt
        /bin/cat /tmp/usbliter8-diagnostic-paths.txt
    ' >"$OUTPUT_DIR/crash-paths.txt"

    if [[ -s "$OUTPUT_DIR/crash-paths.txt" ]]; then
        ssh_remote '/usr/bin/tar -cf /tmp/usbliter8-diagnostics.tar -T /tmp/usbliter8-diagnostic-paths.txt' \
            >"$OUTPUT_DIR/device-tar.txt" 2>&1
        /usr/bin/scp -O -q \
            -o "ControlPath=$CONTROL_SOCKET" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -P "$LOCAL_PORT" \
            root@127.0.0.1:/tmp/usbliter8-diagnostics.tar \
            "$OUTPUT_DIR/recent-diagnostics.tar"
        /usr/bin/tar -xf "$OUTPUT_DIR/recent-diagnostics.tar" \
            -C "$OUTPUT_DIR/crash-files"
    fi
else
    print 'Data could not be mounted read-only; the ticket was still recovered.' \
        >"$OUTPUT_DIR/crash-paths.txt"
fi

print "Collection complete: $OUTPUT_DIR"
sed -n '1,40p' "$OUTPUT_DIR/ticket-summary.txt"
