#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
cd "$SCRIPT_DIR"

EXPECTED_ECID_DEC=7147547156054062
EXPECTED_ECID_HEX=0x001964A80140802E
PYUSB_PYTHON=${USBLITER8_PYTHON:-python3}

usage() {
    print -u2 "usage: $0 {1-stock|2-kernel|3-kernel-dt|4-kernel-dt-txm|5-current}"
}

case ${1:-} in
    1-stock)         CFW_DIR=CFW_DIAG_1_STOCK_RESTORE ;;
    2-kernel)        CFW_DIR=CFW_DIAG_2_KERNEL ;;
    3-kernel-dt)     CFW_DIR=CFW_DIAG_3_KERNEL_DT ;;
    4-kernel-dt-txm) CFW_DIR=CFW_DIAG_4_KERNEL_DT_TXM ;;
    5-current)       CFW_DIR=CFW ;;
    *) usage; exit 2 ;;
esac

if [[ ! -d "$CFW_DIR" ]]; then
    print -u2 "missing $CFW_DIR; run ./prepare_restore_boot_variants.sh first"
    exit 1
fi

if [[ ! -x /opt/homebrew/bin/idevicerestore ]]; then
    print -u2 "missing /opt/homebrew/bin/idevicerestore"
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    print -u2 "missing python3"
    exit 1
fi

if ! "$PYUSB_PYTHON" -c 'import usb.core' >/dev/null 2>&1; then
    print -u2 "Python '$PYUSB_PYTHON' does not have PyUSB."
    print -u2 "Set USBLITER8_PYTHON to a Python interpreter that has pyusb installed."
    exit 1
fi

print "Read-only PWN DFU preflight for ECID $EXPECTED_ECID_HEX"
"$PYUSB_PYTHON" ../tools/usbliter8ctl status --expect-ecid "$EXPECTED_ECID_HEX"

if /usr/bin/nc -z 127.0.0.1 1337 >/dev/null 2>&1; then
    print -u2 "TCP port 1337 is already in use; stop the stale TSS proxy first"
    exit 1
fi

mkdir -p diagnostic-logs
timestamp=$(date +%Y%m%d-%H%M%S)
proxy_log="diagnostic-logs/tss-$timestamp.log"
restore_log="diagnostic-logs/restore-$timestamp.log"

python3 tss_proxy_server.py >"$proxy_log" 2>&1 &
proxy_pid=$!
cleanup() {
    kill "$proxy_pid" >/dev/null 2>&1 || true
    wait "$proxy_pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

for attempt in {1..20}; do
    /usr/bin/nc -z 127.0.0.1 1337 >/dev/null 2>&1 && break
    sleep 0.1
done
if ! /usr/bin/nc -z 127.0.0.1 1337 >/dev/null 2>&1; then
    print -u2 "TSS proxy failed to start; see $proxy_log"
    exit 1
fi

print "Bootstrapping patched iBSS"
"$PYUSB_PYTHON" ../tools/usbliter8ctl boot ./Ramdisk/iBSS.raw
sleep 3

print "Booting diagnostic restore environment from $CFW_DIR"
print "This uses -e only to select the same Customer Erase boot identity."
print "The paired -z exits before StartRestore, so no filesystem restore is sent."

/opt/homebrew/bin/idevicerestore \
    -i "$EXPECTED_ECID_DEC" \
    -s "http://127.0.0.1:1337" \
    -e -y -z -d -P \
    --logfile="$restore_log" \
    "$CFW_DIR"

print
print "SUCCESS: $CFW_DIR reached restored mode without starting a restore."
print "Logs: $restore_log and $proxy_log"
print "The phone is still in the temporary restore environment; reboot it before the next variant."
