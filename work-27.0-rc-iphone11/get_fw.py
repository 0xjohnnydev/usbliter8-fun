#!/usr/bin/env python3
"""Validate and extract the iPhone 11 iOS 27.0 (24A435) IPSW."""

import argparse
import hashlib
import plistlib
import stat
import sys
import zipfile
from pathlib import Path


EXPECTED_FILENAME = "iPhone12,1_27.0_24A435_Restore.ipsw"
EXPECTED_SHA256 = "179435db886454b043575280911f4347783d1d223189e7d44f9a3baaf66e3abd"
EXPECTED_PRODUCT = "iPhone12,1"
EXPECTED_VERSION = "27.0"
EXPECTED_BUILD = "24A435"
OUTPUT_DIR = "iPhone12,1_27.0_24A435_Restore"
REQUIRED_EXTRACTED_PATHS = (
    "BuildManifest.plist",
    "043-69915-775.dmg",
    "Firmware/043-69915-775.dmg.trustcache",
    "Firmware/dfu/iBSS.n104.RELEASE.im4p",
    "Firmware/dfu/iBEC.n104.RELEASE.im4p",
    "Firmware/all_flash/DeviceTree.n104ap.im4p",
    "Firmware/all_flash/sep-firmware.n104.RELEASE.im4p",
    "Firmware/AOP/aopfw-iphone12baop.RELEASE.im4p",
    "Firmware/isp_bni/adc-zelus-n104.im4p",
    "Firmware/WirelessPower/WirelessPower.iphone12b.im4p",
    "Firmware/txm.iphoneos.release.im4p",
    "kernelcache.release.iphone12b",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fp:
        for chunk in iter(lambda: fp.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_ipsw(path: Path) -> None:
    if not path.is_file():
        raise RuntimeError(f"IPSW not found: {path}")

    actual_hash = sha256(path)
    if actual_hash != EXPECTED_SHA256:
        raise RuntimeError(
            f"SHA-256 mismatch for {path.name}:\n"
            f"  expected {EXPECTED_SHA256}\n"
            f"  got      {actual_hash}"
        )

    try:
        with zipfile.ZipFile(path) as archive:
            manifest = plistlib.loads(archive.read("BuildManifest.plist"))
    except (KeyError, plistlib.InvalidFileException, zipfile.BadZipFile) as exc:
        raise RuntimeError(f"invalid IPSW or BuildManifest.plist: {exc}") from exc

    actual = (
        manifest.get("SupportedProductTypes"),
        manifest.get("ProductVersion"),
        manifest.get("ProductBuildVersion"),
    )
    expected = ([EXPECTED_PRODUCT], EXPECTED_VERSION, EXPECTED_BUILD)
    if actual != expected:
        raise RuntimeError(
            "BuildManifest target mismatch:\n"
            f"  expected products/version/build: {expected}\n"
            f"  got products/version/build:      {actual}"
        )

    device_classes = {
        identity.get("Info", {}).get("DeviceClass")
        for identity in manifest.get("BuildIdentities", [])
    }
    chip_ids = {identity.get("ApChipID") for identity in manifest.get("BuildIdentities", [])}
    if device_classes != {"n104ap"} or chip_ids != {"0x8030"}:
        raise RuntimeError(
            f"unexpected BuildIdentity target: DeviceClass={device_classes}, ApChipID={chip_ids}"
        )

    print(
        f"[OK] {EXPECTED_PRODUCT} / iOS {EXPECTED_VERSION} / {EXPECTED_BUILD} / "
        f"n104ap / t8030\n[OK] SHA-256 {actual_hash}"
    )


def make_tools_executable(script_dir: Path) -> None:
    tools_dir = script_dir.parent / "tools"
    for tool in tools_dir.iterdir():
        if tool.is_file():
            tool.chmod(tool.stat().st_mode | stat.S_IXUSR)


def validate_extraction(output: Path) -> None:
    missing = [relative for relative in REQUIRED_EXTRACTED_PATHS if not (output / relative).is_file()]
    if missing:
        raise RuntimeError(
            f"incomplete extraction at {output}; missing: {', '.join(missing)}"
        )

    manifest = plistlib.loads((output / "BuildManifest.plist").read_bytes())
    actual = (
        manifest.get("SupportedProductTypes"),
        manifest.get("ProductVersion"),
        manifest.get("ProductBuildVersion"),
    )
    expected = ([EXPECTED_PRODUCT], EXPECTED_VERSION, EXPECTED_BUILD)
    if actual != expected:
        raise RuntimeError(f"extracted BuildManifest mismatch: expected {expected}, got {actual}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "ipsw",
        nargs="?",
        type=Path,
        default=Path.home() / "Downloads" / EXPECTED_FILENAME,
        help=f"local {EXPECTED_FILENAME} (defaults to ~/Downloads/{EXPECTED_FILENAME})",
    )
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="validate the IPSW without extracting it",
    )
    args = parser.parse_args()

    ipsw = args.ipsw.expanduser().resolve()
    try:
        validate_ipsw(ipsw)
    except RuntimeError as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1

    if args.verify_only:
        return 0

    script_dir = Path(__file__).resolve().parent
    output = script_dir / OUTPUT_DIR
    if output.exists():
        try:
            validate_extraction(output)
        except (RuntimeError, plistlib.InvalidFileException) as exc:
            print(f"[FAIL] {exc}", file=sys.stderr)
            return 1
        print(f"[SKIP] complete target already extracted: {output}")
        return 0

    print(f"[*] extracting {ipsw} -> {output}")
    try:
        with zipfile.ZipFile(ipsw) as archive:
            archive.extractall(output)
    except Exception:
        # Keep an incomplete extraction from being mistaken for a valid one.
        incomplete = output.with_name(output.name + ".incomplete")
        if output.exists() and not incomplete.exists():
            output.rename(incomplete)
        raise

    make_tools_executable(script_dir)
    validate_extraction(output)
    print(f"[OK] extracted {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
