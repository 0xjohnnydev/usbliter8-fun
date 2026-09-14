#!/usr/bin/env python3
"""Inspect or reset a partial DFU download without rebooting the device."""

import argparse
import time

import usb.core
import usb.util


DFU_GETSTATUS = 3
DFU_CLRSTATUS = 4
DFU_GETSTATE = 5
DFU_ABORT = 6

DFU_IDLE = 2
DFU_DNLOAD_SYNC = 3
DFU_DNBUSY = 4
DFU_DNLOAD_IDLE = 5
DFU_ERROR = 10

STATE_NAMES = {
    0: "appIDLE",
    1: "appDETACH",
    DFU_IDLE: "dfuIDLE",
    DFU_DNLOAD_SYNC: "dfuDNLOAD-SYNC",
    DFU_DNBUSY: "dfuDNBUSY",
    DFU_DNLOAD_IDLE: "dfuDNLOAD-IDLE",
    6: "dfuMANIFEST-SYNC",
    7: "dfuMANIFEST",
    8: "dfuMANIFEST-WAIT-RESET",
    9: "dfuUPLOAD-IDLE",
    DFU_ERROR: "dfuERROR",
}


def read_serial(device):
    try:
        return device.serial_number or ""
    except (usb.core.USBError, ValueError):
        # macOS can expose the newly enumerated device before its language/string
        # descriptors are readable.  Treat that as transient, not as lost PWND.
        return None


def open_pwned_device(timeout_seconds=8.0):
    deadline = time.monotonic() + timeout_seconds
    saw_dfu = False
    while time.monotonic() < deadline:
        devices = usb.core.find(
            find_all=True, idVendor=0x05AC, idProduct=0x1227
        )
        for device in devices or ():
            saw_dfu = True
            serial = read_serial(device)
            if serial is not None and "PWND:[usbliter8]" in serial:
                return device
        time.sleep(0.1)

    if saw_dfu:
        raise RuntimeError("Apple DFU is present but its PWND marker is unreadable")
    raise RuntimeError("no Apple DFU device is connected")


def reopen_pwned_device(previous_device, timeout_seconds=12.0):
    # Apple's DFU_ABORT implementation may reset the USB connection even though
    # the SoC stays in DFU and the in-memory usbliter8 patch remains installed.
    try:
        usb.util.dispose_resources(previous_device)
    except usb.core.USBError:
        pass

    deadline = time.monotonic() + timeout_seconds
    last_error = None
    while time.monotonic() < deadline:
        devices = usb.core.find(
            find_all=True, idVendor=0x05AC, idProduct=0x1227
        )
        for device in devices or ():
            try:
                serial = device.serial_number or ""
                if "PWND:[usbliter8]" in serial:
                    return device
            except (usb.core.USBError, ValueError) as error:
                last_error = error
        time.sleep(0.1)

    if last_error is not None:
        raise RuntimeError("PWND DFU re-enumerated but could not be opened") from last_error
    raise RuntimeError("PWND DFU did not re-enumerate after DFU_ABORT")


def get_state(device):
    result = device.ctrl_transfer(0xA1, DFU_GETSTATE, 0, 0, 1, 1000)
    if len(result) != 1:
        raise RuntimeError(f"DFU_GETSTATE returned {len(result)} bytes, expected 1")
    return int(result[0])


def get_status(device):
    result = device.ctrl_transfer(0xA1, DFU_GETSTATUS, 0, 0, 6, 1000)
    if len(result) != 6:
        raise RuntimeError(f"DFU_GETSTATUS returned {len(result)} bytes, expected 6")
    poll_timeout_ms = int(result[1]) | (int(result[2]) << 8) | (int(result[3]) << 16)
    return int(result[0]), poll_timeout_ms, int(result[4]), int(result[5])


def describe_state(state):
    return f"{STATE_NAMES.get(state, 'unknown')} ({state})"


def print_status(device):
    state = get_state(device)
    status, poll_timeout_ms, status_state, status_string = get_status(device)
    print(f"GETSTATE:  {describe_state(state)}")
    print(
        "GETSTATUS: "
        f"status={status} state={describe_state(status_state)} "
        f"poll_timeout_ms={poll_timeout_ms} string={status_string}"
    )
    return state, status, poll_timeout_ms, status_state


def reset_partial_download(device):
    state, status, poll_timeout_ms, status_state = print_status(device)

    if state == DFU_ERROR or status_state == DFU_ERROR or status != 0:
        print("Clearing dfuERROR with DFU_CLRSTATUS (request 4)")
        device.ctrl_transfer(0x21, DFU_CLRSTATUS, 0, 0, None, 1000)
    else:
        if state == DFU_DNLOAD_SYNC:
            # GETSTATUS advances DNLOAD-SYNC to DNLOAD-IDLE on a completed block.
            state = status_state
        if state == DFU_DNBUSY:
            deadline = time.monotonic() + 5.0
            while state == DFU_DNBUSY and time.monotonic() < deadline:
                time.sleep(min(max(poll_timeout_ms / 1000.0, 0.001), 0.25))
                _, poll_timeout_ms, state, _ = get_status(device)

        if state == DFU_IDLE:
            print("DFU download state is already clean; no write request was sent")
        elif state in (DFU_DNLOAD_SYNC, DFU_DNLOAD_IDLE):
            print("Aborting the partial download with DFU_ABORT (request 6)")
            device.ctrl_transfer(0x21, DFU_ABORT, 0, 0, None, 1000)
        else:
            raise RuntimeError(
                f"refusing to reset unexpected DFU state {describe_state(state)}"
            )

    try:
        final_state = get_state(device)
    except usb.core.USBError:
        print("DFU_ABORT reset the USB connection; waiting for PWND DFU to re-enumerate")
        device = reopen_pwned_device(device)
        final_state = get_state(device)
    if final_state != DFU_IDLE:
        raise RuntimeError(
            f"DFU state did not return to dfuIDLE: {describe_state(final_state)}"
        )
    serial = read_serial(device)
    if serial is None:
        device = reopen_pwned_device(device)
        serial = read_serial(device)
    if serial is None or "PWND:[usbliter8]" not in serial:
        raise RuntimeError("DFU became idle but the usbliter8 PWND marker disappeared")
    print("DFU download state is clean and PWND is preserved")


def main():
    parser = argparse.ArgumentParser(
        description="Inspect or reset the current usbliter8 DFU download state"
    )
    parser.add_argument(
        "action",
        choices=("status", "reset-partial-download"),
        help="status is read-only; reset sends only the state-appropriate DFU request",
    )
    args = parser.parse_args()

    device = open_pwned_device()
    if args.action == "status":
        print_status(device)
    else:
        reset_partial_download(device)


if __name__ == "__main__":
    main()
