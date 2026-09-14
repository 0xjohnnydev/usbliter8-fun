#!/usr/bin/env python3
"""Inject one LaunchDaemon into an existing iOS launchd cache plist."""

from __future__ import annotations

import argparse
import plistlib
import sys
from pathlib import Path


def load_plist(path: Path):
    try:
        with path.open("rb") as stream:
            return plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as exc:
        raise ValueError(f"could not parse {path}: {exc}") from exc


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("cache", type=Path)
    parser.add_argument("daemon", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--key", required=True)
    args = parser.parse_args()

    try:
        raw_cache = args.cache.read_bytes()
        cache = load_plist(args.cache)
        daemon = load_plist(args.daemon)
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if not isinstance(cache, dict):
        print("error: launchd cache is not a dictionary", file=sys.stderr)
        return 1
    jobs = cache.get("LaunchDaemons")
    if not isinstance(jobs, dict):
        print("error: launchd cache has no LaunchDaemons dictionary", file=sys.stderr)
        return 1
    if not isinstance(daemon, dict):
        print("error: daemon plist is not a dictionary", file=sys.stderr)
        return 1

    label = daemon.get("Label")
    if not isinstance(label, str) or not label:
        print("error: daemon plist has no valid Label", file=sys.stderr)
        return 1

    existing = jobs.get(args.key)
    if existing is not None and existing != daemon:
        print(f"error: {args.key} already contains an unknown job", file=sys.stderr)
        return 1

    for key, job in jobs.items():
        if key == args.key or not isinstance(job, dict):
            continue
        if job.get("Label") == label:
            print(
                f"error: label {label!r} already belongs to cache key {key!r}",
                file=sys.stderr,
            )
            return 1

    jobs[args.key] = daemon
    output_format = (
        plistlib.FMT_BINARY if raw_cache.startswith(b"bplist00") else plistlib.FMT_XML
    )
    try:
        with args.output.open("wb") as stream:
            plistlib.dump(cache, stream, fmt=output_format, sort_keys=False)
    except OSError as exc:
        print(f"error: could not write {args.output}: {exc}", file=sys.stderr)
        return 1

    verified = load_plist(args.output)
    if verified.get("LaunchDaemons", {}).get(args.key) != daemon:
        print("error: output verification failed", file=sys.stderr)
        return 1

    state = "already present" if existing == daemon else "injected"
    print(f"{state}: {args.key} ({label})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
