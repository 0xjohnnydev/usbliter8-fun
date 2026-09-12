#!/usr/bin/env python3
"""Fail-closed byte patching for iPhone12,1 / iOS 27.0 (24A435).

Every patch site is checked against the unmodified 24A435 preimage before it
is written.  This prevents the build scripts from silently corrupting another
IPSW, an already-patched artifact, or a future Apple rebuild.
"""

from pathlib import Path


_EXPECTED_HEX = {
    "iBSS.raw": {
        0x236E8: "01070054",
        0x236EC: "e00314aa",
        0x2AA0C: "620800f0",
        0x2AA10: "423c3091",
        0xD1158: "00" * 64,
    },
    "iBEC.raw": {
        0x236E8: "01070054",
        0x236EC: "e00314aa",
        0x2AA0C: "620800f0",
        0x2AA10: "423c3091",
        0xD1158: "00" * 64,
    },
    "TXM.raw": {
        0x2FD04: "a90200b0",
        0x2FD08: "29c13691",
        0x3DF48: "65faff97",
        0x3E0B0: "0bfaff97",
        0x3E244: "a6f9ff97",
        0x437B0: "a3000054",
        0x437B8: "690000b4",
    },
    "kcache.raw": {
        0x3F2BE: "2f52454c454153455f41524d36345f5438303330",
        0x3F324: "2f52454c454153455f41524d36345f5438303330",
        0x1EFBE80: "5f2403d5",
        0x1EFBE84: "7f2303d5",
        0x1EFBE88: "ffc300d1",
        0x1EFBE8C: "f44f01a9",
        0x1EFBE90: "fd7b02a9",
        0x1F00BB8: "7f2303d5",
        0x1F00BBC: "ff0306d1",
        0x1F08978: "1f040071",
        0x1F08EE4: "c5620094",
        0x1F08EF0: "8bdeff97",
        0x20BFD50: "7f2303d5",
        0x20BFD54: "ff0301d1",
        0x20C0434: "7f2303d5",
        0x20C0438: "ff8301d1",
        0x20C04BC: "7f2303d5",
        0x20C04C0: "ff8301d1",
        0x20C0548: "7f2303d5",
        0x20C054C: "ff4302d1",
        0x20C0824: "7f2303d5",
        0x20C0828: "ff4305d1",
        0x20C1314: "7f2303d5",
        0x20C1318: "ff4302d1",
        0x20C16D4: "7f2303d5",
        0x20C16D8: "ffc302d1",
        0x20C1900: "7f2303d5",
        0x20C1904: "ff8301d1",
        0x20C1B30: "7f2303d5",
        0x20C1B34: "ff4301d1",
        0x20C1C54: "7f2303d5",
        0x20C1C58: "ff8301d1",
        0x20C1DBC: "7f2303d5",
        0x20C1DC0: "ff0302d1",
        0x20C2084: "7f2303d5",
        0x20C2088: "ff4304d1",
        0x20C2B00: "7f2303d5",
        0x20C2B04: "ff0302d1",
        0x20C2F8C: "7f2303d5",
        0x20C2F90: "ff4301d1",
        0x20C307C: "5f2403d5",
        0x20C3080: "c10000b4",
        0x20C34B8: "7f2303d5",
        0x20C34BC: "ffc301d1",
        0x20C36E8: "7f2303d5",
        0x20C36EC: "ff8301d1",
        0x20C3BAC: "7f2303d5",
        0x20C3BB0: "ff0302d1",
        0x20C3E98: "7f2303d5",
        0x20C3E9C: "ff8301d1",
        0x20C3FFC: "7f2303d5",
        0x20C4000: "ff4302d1",
        0x20C43A8: "7f2303d5",
        0x20C43AC: "ff4302d1",
        0x20C45E4: "7f2303d5",
        0x20C45E8: "ff8301d1",
        0x20C4784: "7f2303d5",
        0x20C4788: "ff4302d1",
        0x20C53D0: "7f2303d5",
        0x20C53D4: "ff0302d1",
        0x20C5688: "7f2303d5",
        0x20C568C: "ff0302d1",
        0x20D1B2C: "7f2303d5",
        0x20D1B30: "ffc301d1",
        0x20E629C: "10093fd7",
        0x20F13A0: "7f2303d5",
        0x20F13A4: "ff8306d1",
        0x20F15D8: "01990094",
        0x2139AA4: "7f2303d5",
        0x2139AA8: "ffc300d1",
        0x213A43C: "7f2303d5",
        0x213A440: "ff4305d1",
        0x213D194: "200d00b4",
        0x213D340: "7f2303d5",
        0x213D344: "f44fbea9",
        0x213E1FC: "801200b4",
        0x213E22C: "201100b4",
        0x213E7C4: "80010054",
        0x2F58ED4: "60017037",
        0x2FEC20C: "28062837",
        0x2FED640: "a8000037",
        0x366924C: "00130035",
        0x39ABBFC: "0896fed0",
        0x39ABC00: "e00000b4",
    },
    "restored_external": {0x7E848: "e0031aaa"},
    "asr": {0x1F66C: "895f0094"},
}

EXPECTED = {
    filename: {offset: bytes.fromhex(value) for offset, value in offsets.items()}
    for filename, offsets in _EXPECTED_HEX.items()
}


def checked_patch(fp, offset: int, data: bytes) -> None:
    """Validate and patch one byte sequence in an already-open binary."""

    filename = Path(fp.name).name
    try:
        expected = EXPECTED[filename][offset]
    except KeyError as exc:
        raise RuntimeError(
            f"unregistered patch site: {filename} @ {offset:#x}"
        ) from exc

    if len(expected) < len(data):
        raise RuntimeError(
            f"preimage for {filename} @ {offset:#x} is shorter than patch"
        )

    fp.seek(offset)
    actual = fp.read(len(data))
    wanted = expected[: len(data)]
    if actual != wanted:
        raise RuntimeError(
            f"preimage mismatch for {filename} @ {offset:#x}: "
            f"expected {wanted.hex()}, got {actual.hex()}"
        )

    fp.seek(offset)
    fp.write(data)
    fp.flush()
    print(f"checked {filename} @ {offset:#x}: {actual.hex()} -> {data.hex()}")
