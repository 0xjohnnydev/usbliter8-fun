#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
WORK_DIR=${SCRIPT_DIR:h}
SOURCE_ROOT=${1:-${USBLITER8_USERLAND_ROOT:-}}
OUTPUT_DIR="$SCRIPT_DIR/cache/setup-bypass-24A435"

die() {
    print -u2 -- "$*"
    exit 1
}

sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

[[ -n "$SOURCE_ROOT" ]] || \
    die "usage: $0 /path/to/extracted/24A435/root"

for required in ldid codesign plutil shasum; do
    command -v "$required" >/dev/null 2>&1 || die "Missing required command: $required"
done

typeset -A SOURCE_PATH STOCK_SHA PATCHED_SHA
SOURCE_PATH[mobileactivationd]="$SOURCE_ROOT/usr/libexec/mobileactivationd"
SOURCE_PATH[coreauthd]="$SOURCE_ROOT/System/Library/Frameworks/LocalAuthentication.framework/Support/coreauthd"
SOURCE_PATH[ctkd]="$SOURCE_ROOT/System/Library/Frameworks/CryptoTokenKit.framework/ctkd"

STOCK_SHA[mobileactivationd]=89233513ce696cd01285f3432f3bcadd065cee07ac73bc5714836d13f24702d8
STOCK_SHA[coreauthd]=b12b67d59787d7235e45a8788e25cb1f45dfaa56aa6cfd413b759178bf8c1a14
STOCK_SHA[ctkd]=2f5861e1deaac8c4490cc4f0753c0d782bdc60408d1a6890f0cee4b78440db73

PATCHED_SHA[mobileactivationd]=0d4ef223a4f25a73f95a50c25a09ebe42c0b5ff977ed9cee69650df2aa48d0ad
PATCHED_SHA[coreauthd]=abe6b84a124a4f12aed7f3366089a9ec4819a3c68264d349589d47ec12c03072
PATCHED_SHA[ctkd]=d6ac0299b83e834dce0a26874c5c1d137ba03a85f7b17f80fc733e28f0843dba

components=(mobileactivationd coreauthd ctkd)
TEMP_DIR=$(mktemp -d /tmp/usbliter8-setup-payload.XXXXXX)
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT INT TERM HUP

for component in $components; do
    source_binary="${SOURCE_PATH[$component]}"
    [[ -f "$source_binary" ]] || die "Missing 24A435 source binary: $source_binary"
    [[ "$(sha256_of "$source_binary")" == "${STOCK_SHA[$component]}" ]] || \
        die "Refusing non-stock 24A435 source binary: $source_binary"
    cp -p "$source_binary" "$TEMP_DIR/$component"
    "$WORK_DIR/userland_patches.py" "$component" "$TEMP_DIR/$component"

    ldid -e "$TEMP_DIR/$component.orig" >"$TEMP_DIR/$component.entitlements.plist"
    plutil -lint "$TEMP_DIR/$component.entitlements.plist" >/dev/null
    ldid -S"$TEMP_DIR/$component.entitlements.plist" -Cadhoc "$TEMP_DIR/$component"
    ldid -e "$TEMP_DIR/$component" >"$TEMP_DIR/$component.patched.entitlements.plist"
    cmp "$TEMP_DIR/$component.entitlements.plist" \
        "$TEMP_DIR/$component.patched.entitlements.plist"
    codesign --verify --strict "$TEMP_DIR/$component"
    [[ "$(sha256_of "$TEMP_DIR/$component")" == "${PATCHED_SHA[$component]}" ]] || \
        die "Signed $component postimage differs from the verified payload"
done

mkdir -p "$OUTPUT_DIR"
for component in $components; do
    cp -p "$TEMP_DIR/$component" "$OUTPUT_DIR/$component"
    [[ "$(sha256_of "$OUTPUT_DIR/$component")" == "${PATCHED_SHA[$component]}" ]] || \
        die "Copied $component payload failed verification"
done

print "Built and verified the 24A435 upstream Setup-bypass payload at $OUTPUT_DIR"
