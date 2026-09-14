#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
WORK_DIR=${SCRIPT_DIR:h}
REPO_DIR=${WORK_DIR:h}
LDID="$REPO_DIR/tools/ldid_macosx_arm64"
DEB="$SCRIPT_DIR/cache/org.coolstar.sileo_2.5.1_iphoneos-arm64.deb"
OUTPUT_DIR="$SCRIPT_DIR/cache/registration-refresh-24A435"
OUTPUT_TAR="$OUTPUT_DIR/Sileo.launchable-24A435.tar"
EXPECTED_DEB_SHA256=8e3c90e5a7d32f4ca207a0ac30d3cfa8a13dca86a2b4e11cb3f9e5c68d7bc97a

die() {
    print -u2 -- "error: $*"
    exit 1
}

for tool in dpkg-deb codesign plutil shasum tar; do
    command -v "$tool" >/dev/null || die "missing required tool: $tool"
done
[[ -x "$LDID" ]] || die "missing ldid: $LDID"
[[ -f "$DEB" ]] || die "missing Sileo package: $DEB"

actual_deb_sha256=$(shasum -a 256 "$DEB" | awk '{print $1}')
[[ "$actual_deb_sha256" == "$EXPECTED_DEB_SHA256" ]] || \
    die "Sileo package hash mismatch: $actual_deb_sha256"

TEMP_DIR=$(mktemp -d /tmp/usbliter8-sileo-launchable.XXXXXX)
EXTRACT_DIR="$TEMP_DIR/extracted"
APP_DIR="$TEMP_DIR/Sileo.launchable-24A435.app"
ENTITLEMENTS="$TEMP_DIR/Sileo.entitlements.plist"
OUTPUT_TMP="$OUTPUT_DIR/.Sileo.launchable-24A435.tar.$$.new"

mkdir -p "$EXTRACT_DIR" "$OUTPUT_DIR"
dpkg-deb -x "$DEB" "$EXTRACT_DIR"
SOURCE_APP="$EXTRACT_DIR/var/jb/Applications/Sileo.app"
[[ -x "$SOURCE_APP/Sileo" ]] || die "package did not contain Sileo.app/Sileo"
[[ -x "$SOURCE_APP/giveMeRoot" ]] || die "package did not contain giveMeRoot"

ditto "$SOURCE_APP" "$APP_DIR"

# First create a complete, internally consistent ad-hoc bundle signature.  This
# signs the nested helper and rebuilds CodeResources while preserving the
# package's bundle identifiers and entitlements.
codesign \
    --force \
    --deep \
    --sign - \
    --timestamp=none \
    --pagesize 4096 \
    --preserve-metadata=identifier,entitlements \
    "$APP_DIR"

# 34306's source notes that iOS kills ad-hoc app processes that retain either
# get-task-allow entitlement.  Preserve every other Sileo entitlement, but
# remove both spellings before re-signing the main executable.
"$LDID" -e "$APP_DIR/Sileo" >"$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c 'Delete :get-task-allow' "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' "$ENTITLEMENTS"

codesign \
    --force \
    --sign - \
    --timestamp=none \
    --pagesize 4096 \
    --preserve-metadata=identifier,requirements,flags \
    --entitlements "$ENTITLEMENTS" \
    "$APP_DIR/Sileo"

if "$LDID" -e "$APP_DIR/Sileo" | grep -q 'get-task-allow'; then
    die "Sileo still contains get-task-allow after re-signing"
fi
if "$LDID" -e "$APP_DIR/giveMeRoot" | grep -q 'get-task-allow'; then
    die "giveMeRoot unexpectedly contains get-task-allow"
fi

bundle_id=$(plutil -extract CFBundleIdentifier raw -o - "$APP_DIR/Info.plist")
[[ "$bundle_id" == "org.coolstar.SileoStore" ]] || \
    die "unexpected Sileo bundle identifier: $bundle_id"
codesign --verify --deep --strict --verbose=4 "$APP_DIR"

tar -C "$TEMP_DIR" -cf "$OUTPUT_TMP" "${APP_DIR:t}"
mv "$OUTPUT_TMP" "$OUTPUT_TAR"

print -- "OUTPUT=$OUTPUT_TAR"
print -- "SHA256=$(shasum -a 256 "$OUTPUT_TAR" | awk '{print $1}')"
print -- "MAIN_CDHASH=$(codesign -d --verbose=6 "$APP_DIR/Sileo" 2>&1 | sed -n 's/^CandidateCDHash sha256=//p')"
print -- "TEMP_DIR=$TEMP_DIR"
