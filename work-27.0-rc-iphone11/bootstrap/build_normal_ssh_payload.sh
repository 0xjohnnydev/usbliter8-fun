#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
WORK_DIR=${SCRIPT_DIR:h}
STOCK_CACHE=${1:-}
OUTPUT_DIR="$SCRIPT_DIR/cache/normal-ssh-24A435"
SOURCE="$SCRIPT_DIR/normal_dropbear_launcher.c"
PLIST="$SCRIPT_DIR/com.usbliter8.dropbear.plist"
INJECTOR="$SCRIPT_DIR/inject_launchd_job.py"
CACHE_KEY=/System/Library/LaunchDaemons/com.usbliter8.dropbear.plist

STOCK_CACHE_SHA256=752739f8224b016b5cee1b37a985995ffcfc1d6f12569fd2191ba5b4a9119c6a
SOURCE_SHA256=22a4e3ab55e849279fb7002b6818734969b28d08b37693a3959b0df0fc064ba8
PLIST_SHA256=bb9e2548d70619ecd7dba4115dae50a9cab12a9792070f35a1d235bb8f455949
LAUNCHER_SHA256=105b989284baef79d9d2884e6070efaaadbdb065b52a4ad27768f4e5cce392e4
PATCHED_CACHE_SHA256=f01b11c010ae867c325bdfb2cc448023e90d0bd1083565d97f7d78dee6e1690d

die() {
    print -u2 -- "$*"
    exit 1
}

sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

[[ -n "$STOCK_CACHE" ]] || die "usage: $0 /path/to/stock-24A435-launchd.plist"
for required in xcrun codesign plutil shasum python3; do
    command -v "$required" >/dev/null 2>&1 || die "Missing required command: $required"
done
[[ "$(sha256_of "$STOCK_CACHE")" == "$STOCK_CACHE_SHA256" ]] || \
    die "Refusing a launchd cache that is not exact stock 24A435"
[[ "$(sha256_of "$SOURCE")" == "$SOURCE_SHA256" ]] || \
    die "Launcher source changed without updating its audited hash"
[[ "$(sha256_of "$PLIST")" == "$PLIST_SHA256" ]] || \
    die "LaunchDaemon plist changed without updating its audited hash"
/usr/bin/plutil -lint "$PLIST" >/dev/null

TEMP_DIR=$(mktemp -d /tmp/usbliter8-normal-ssh-build.XXXXXX)
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT INT TERM HUP

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang \
    -target arm64e-apple-ios27.0 \
    -isysroot "$SDK" \
    -Os -Wall -Wextra -Werror -fvisibility=hidden \
    -Wl,-not_for_dyld_shared_cache \
    "$SOURCE" \
    -o "$TEMP_DIR/usbliter8-dropbear-launcher"
/usr/bin/codesign \
    --force --sign - --timestamp=none --pagesize 4096 \
    --identifier com.0xjohnnydev.usbliter8.dropbear-launcher \
    "$TEMP_DIR/usbliter8-dropbear-launcher"
/usr/bin/codesign --verify --strict "$TEMP_DIR/usbliter8-dropbear-launcher"
[[ "$(sha256_of "$TEMP_DIR/usbliter8-dropbear-launcher")" == "$LAUNCHER_SHA256" ]] || \
    die "Built launcher differs from the verified 24A435 postimage"

/usr/bin/python3 "$INJECTOR" \
    --key "$CACHE_KEY" \
    "$STOCK_CACHE" "$PLIST" "$TEMP_DIR/launchd.plist"
/usr/bin/plutil -lint "$TEMP_DIR/launchd.plist" >/dev/null
[[ "$(sha256_of "$TEMP_DIR/launchd.plist")" == "$PATCHED_CACHE_SHA256" ]] || \
    die "Patched launchd cache differs from the verified 24A435 postimage"

mkdir -p "$OUTPUT_DIR"
cp -p "$TEMP_DIR/usbliter8-dropbear-launcher" "$OUTPUT_DIR/"
cp -p "$TEMP_DIR/launchd.plist" "$OUTPUT_DIR/"

print "Built and verified the normal SSH payload at $OUTPUT_DIR"
