#!/usr/bin/env python3
"""Add the already-validated normal-boot /var/jb hooks to an SSHRD kernel."""

from __future__ import annotations

import argparse
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from checked_patch import checked_patch


HOOKS = (
    0x2F219FC,
    0x2F1F998,
    0x2F1F7C8,
    0x2F1F45C,
    0x2F1A480,
)
MOV_X0_0 = struct.pack("<I", 0xD2800000)
RET = struct.pack("<I", 0xD65F03C0)


def run(*args: str) -> None:
    subprocess.run(args, check=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pyimg4", type=Path, required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--stock-im4p", type=Path, required=True)
    parser.add_argument("--ticket", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    for path in (args.pyimg4, args.input, args.stock_im4p, args.ticket):
        if not path.is_file():
            raise SystemExit(f"missing input: {path}")
    if args.output.exists():
        raise SystemExit(f"refusing to overwrite existing output: {args.output}")

    with tempfile.TemporaryDirectory(prefix="usbliter8-sshrd-kernel.") as temp:
        temp_dir = Path(temp)
        old_im4p = temp_dir / "old.im4p"
        raw = temp_dir / "kcache.raw"
        patched_im4p = temp_dir / "patched.im4p"
        candidate = temp_dir / "candidate.img4"

        run(
            str(args.pyimg4),
            "img4",
            "extract",
            "-i",
            str(args.input),
            "-p",
            str(old_im4p),
        )
        run(
            str(args.pyimg4),
            "im4p",
            "extract",
            "-i",
            str(old_im4p),
            "-o",
            str(raw),
        )

        before = raw.read_bytes()
        with raw.open("r+b") as stream:
            for offset in HOOKS:
                checked_patch(stream, offset, MOV_X0_0)
                checked_patch(stream, offset + 4, RET)
        after = raw.read_bytes()

        changed = {
            index for index, (old, new) in enumerate(zip(before, after)) if old != new
        }
        expected_changed = {
            index
            for offset in HOOKS
            for index in range(offset, offset + 8)
            if before[index] != after[index]
        }
        if changed != expected_changed or len(before) != len(after):
            raise SystemExit("raw-kernel delta escaped the five guarded hook sites")

        run(
            str(args.pyimg4),
            "im4p",
            "create",
            "-i",
            str(raw),
            "-o",
            str(patched_im4p),
            "-d",
            "KernelManagement_host-514.2.2",
            "-f",
            "rkrn",
            "--lzfse",
        )

        stock = args.stock_im4p.read_bytes()
        payp_offset = stock.rfind(b"PAYP")
        if payp_offset < 10:
            raise SystemExit("stock kernel IM4P has no usable PAYP trailer")
        trailer = stock[payp_offset - 10 :]
        rebuilt = bytearray(patched_im4p.read_bytes())
        rebuilt.extend(trailer)
        rebuilt[2:6] = (int.from_bytes(rebuilt[2:6], "big") + len(trailer)).to_bytes(
            4, "big"
        )
        patched_im4p.write_bytes(rebuilt)

        run(
            str(args.pyimg4),
            "img4",
            "create",
            "-p",
            str(patched_im4p),
            "-o",
            str(candidate),
            "-m",
            str(args.ticket),
        )
        shutil.copyfile(candidate, args.output)

    print(f"rebuilt SSHRD sandbox kernel: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
