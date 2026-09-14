#!/usr/bin/env python3
"""Checked userland patches for iPhone12,1 / iOS 27.0 (24A435)."""

import argparse
import shutil
import struct
import sys
from pathlib import Path


NOP = 0xD503201F
MOV_X0_0 = 0xD2800000
MOV_W0_1 = 0x52800020
RET = 0xD65F03C0
ADRP_X0_ACTIVATED = 0xD0000620
ADD_X0_ACTIVATED = 0x911BE000

# component -> (file offset, expected instruction, replacement, purpose)
PATCHES = {
    "coreauthd": [
        (0x95C0, 0x9400D118, NOP, "skip BL objc_msgSend$startController"),
    ],
    "ctkd": [
        (0x1B38, 0xD503237F, MOV_X0_0, "serverAttributesOfKey:error: -> nil"),
        (0x1B3C, 0xD10303FF, RET, "return"),
    ],
    "mobileactivationd": [
        (0x2EC368, 0x39405000, MOV_W0_1, "-[DeviceType should_hactivate] -> YES"),
        # Port of 34306's secondary activation-state bypass.  In 24A435 the
        # method moved from 0x327bxx to 0x329bxx, while its control flow stayed
        # identical: ignore an incomplete DataArk migration, then use the
        # local CFString object for "Activated" instead of "Unactivated".
        (
            0x329BE8,
            0x36000576,
            NOP,
            "getActivationStateWithCompletionBlock: ignore migration-unavailable branch",
        ),
        (
            0x329C48,
            0x90000528,
            ADRP_X0_ACTIVATED,
            "load page of local CFString Activated",
        ),
        (
            0x329C4C,
            0x910C4108,
            ADD_X0_ACTIVATED,
            "form address of local CFString Activated",
        ),
        (
            0x329C50,
            0xF9400100,
            NOP,
            "keep direct CFString Activated address instead of dereferencing a global",
        ),
    ],
}


def checked_words(component: str, binary: Path) -> list[tuple[int, int, int, str]]:
    data = binary.read_bytes()
    patches = PATCHES[component]
    for offset, expected, replacement, purpose in patches:
        if offset + 4 > len(data):
            raise RuntimeError(
                f"{binary}: {component} patch offset {offset:#x} is outside the file"
            )
        actual = struct.unpack_from("<I", data, offset)[0]
        if actual != expected:
            raise RuntimeError(
                f"preimage mismatch at {offset:#x}: expected {expected:08x}, "
                f"got {actual:08x} ({purpose})"
            )
    return patches


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("component", choices=PATCHES)
    parser.add_argument("binary", type=Path)
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify build-specific preimages without changing the binary",
    )
    args = parser.parse_args()

    binary = args.binary.expanduser().resolve()
    if not binary.is_file():
        print(f"[FAIL] binary not found: {binary}", file=sys.stderr)
        return 1

    try:
        patches = checked_words(args.component, binary)
    except RuntimeError as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1

    for offset, expected, replacement, purpose in patches:
        print(
            f"[OK] {args.component} @ {offset:#x}: {expected:08x} -> "
            f"{replacement:08x}  # {purpose}"
        )
    if args.check:
        return 0

    backup = binary.with_name(binary.name + ".orig")
    if backup.exists():
        print(f"[FAIL] backup already exists; refusing to overwrite it: {backup}", file=sys.stderr)
        return 1
    shutil.copy2(binary, backup)

    data = bytearray(binary.read_bytes())
    for offset, _expected, replacement, _purpose in patches:
        struct.pack_into("<I", data, offset, replacement)
    binary.write_bytes(data)

    verify = binary.read_bytes()
    for offset, _expected, replacement, purpose in patches:
        actual = struct.unpack_from("<I", verify, offset)[0]
        if actual != replacement:
            print(f"[FAIL] write verification failed at {offset:#x} ({purpose})", file=sys.stderr)
            return 1

    print(
        f"[OK] patched {args.component}; original preserved at {backup}\n"
        "[NEXT] re-sign the patched binary while preserving its original entitlements"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
