#!/bin/zsh
set -e

PYUSB_PYTHON=${USBLITER8_PYTHON:-python3}
if ! "$PYUSB_PYTHON" -c 'import usb' >/dev/null 2>&1; then
    print -u2 "Python '$PYUSB_PYTHON' does not have PyUSB; refusing to touch the device"
    exit 1
fi

"$PYUSB_PYTHON" ../tools/usbliter8ctl boot ./Ramdisk/iBSS.raw
sleep 3

idevicerestore -s "http://127.0.0.1:1337" -e -y CFW
