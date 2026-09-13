#!/bin/zsh
set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BASE/../.." && pwd)"
BUILD="$BASE/build"
STOCK="$BUILD/stock"
PAYLOAD="$BUILD/payload"
TESTS="$BUILD/tests"

LOCKDOWN_SHA="b42e3a6d87b67d0949fb28b3f07b65e00b4074fd67d5d3f588d01ad3365c2306"
WIFID_SHA="a75c43fc82eabf942c659d6dfa3a494162e551b6b5430a66ea32cdd3c8b63322"
PAIRING_LOAD_PATH="/usr/lib/usbliter8-pairing.dylib"
WIFI_LOAD_PATH="/usr/lib/usbliter8-wifi.dylib"

if (( $# > 1 )); then
    print -u2 "usage: $0 [extracted-root]"
    exit 2
fi

EXTRACTED_ROOT="${1:-${USBLITER8_STOCK_ROOT:-}}"
if [[ -z "$EXTRACTED_ROOT" ]]; then
    print -u2 "Pass the directory containing usr/libexec/lockdownd and usr/sbin/wifid."
    exit 2
fi

LOCKDOWN_SOURCE="$EXTRACTED_ROOT/usr/libexec/lockdownd"
WIFID_SOURCE="$EXTRACTED_ROOT/usr/sbin/wifid"
if [[ ! -f "$LOCKDOWN_SOURCE" || ! -f "$WIFID_SOURCE" ]]; then
    print -u2 "Exact daemon files were not found beneath: $EXTRACTED_ROOT"
    exit 1
fi

check_sha() {
    local input_file="$1"
    local expected="$2"
    local actual
    actual="$(shasum -a 256 "$input_file" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        print -u2 "SHA-256 mismatch for $input_file"
        print -u2 "expected: $expected"
        print -u2 "actual:   $actual"
        exit 1
    fi
}

check_sha "$LOCKDOWN_SOURCE" "$LOCKDOWN_SHA"
check_sha "$WIFID_SOURCE" "$WIFID_SHA"

rm -rf "$STOCK" "$PAYLOAD" "$TESTS"
mkdir -p "$STOCK" "$PAYLOAD" "$TESTS"

print "[1/6] Running native storage/key tests"
clang \
    -DUSBLITER8_TESTING=1 -DUSBLITER8_NO_INTERPOSE=1 \
    -Wall -Wextra -Werror \
    -I"$BASE" \
    "$BASE/shim_common.c" "$BASE/test_pairing.c" \
    -framework CoreFoundation -framework Security \
    -o "$TESTS/test-pairing"
clang \
    -DUSBLITER8_TESTING=1 -DUSBLITER8_NO_INTERPOSE=1 \
    -Wall -Wextra -Werror \
    -I"$BASE" \
    "$BASE/shim_common.c" "$BASE/test_wifi.c" \
    -framework CoreFoundation -framework Security \
    -o "$TESTS/test-wifi"
"$TESTS/test-pairing"
"$TESTS/test-wifi"

clang \
    -DUSBLITER8_TESTING=1 \
    -Wall -Wextra -Werror -fvisibility=hidden -dynamiclib \
    -Wl,-not_for_dyld_shared_cache -Wl,-no_warn_inits \
    -install_name @rpath/libusbliter8-pairing-test.dylib \
    -I"$BASE" \
    "$BASE/shim_common.c" "$BASE/pairing_key_shim.c" \
    -framework CoreFoundation -framework Security \
    -o "$TESTS/libusbliter8-pairing-test.dylib"
clang \
    -Wall -Wextra -Werror \
    "$BASE/test_pairing_interpose.c" \
    -L"$TESTS" -lusbliter8-pairing-test \
    -Wl,-rpath,@loader_path \
    -framework CoreFoundation -framework Security \
    -o "$TESTS/test-pairing-interpose"

clang \
    -DUSBLITER8_TESTING=1 \
    -Wall -Wextra -Werror -fvisibility=hidden -dynamiclib \
    -Wl,-not_for_dyld_shared_cache -Wl,-no_warn_inits \
    -install_name @rpath/libusbliter8-wifi-test.dylib \
    -I"$BASE" \
    "$BASE/shim_common.c" "$BASE/wifi_keychain_shim.c" \
    -framework CoreFoundation -framework Security \
    -o "$TESTS/libusbliter8-wifi-test.dylib"
clang \
    -Wall -Wextra -Werror \
    "$BASE/test_wifi_interpose.c" \
    -L"$TESTS" -lusbliter8-wifi-test \
    -Wl,-rpath,@loader_path \
    -framework CoreFoundation -framework Security \
    -o "$TESTS/test-wifi-interpose"

"$TESTS/test-pairing-interpose"
"$TESTS/test-wifi-interpose"

print "[2/6] Building arm64e iOS 27 dylibs"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
IOS_FLAGS=(
    -target arm64e-apple-ios27.0
    -isysroot "$SDK"
    -Os
    -Wall -Wextra -Werror
    -fvisibility=hidden
    -dynamiclib
    -Wl,-not_for_dyld_shared_cache
    -Wl,-no_warn_inits
)
xcrun --sdk iphoneos clang \
    "${IOS_FLAGS[@]}" \
    -install_name "$PAIRING_LOAD_PATH" \
    "$BASE/shim_common.c" "$BASE/pairing_key_shim.c" \
    -framework CoreFoundation -framework Security \
    -o "$PAYLOAD/usbliter8-pairing.dylib"
xcrun --sdk iphoneos clang \
    "${IOS_FLAGS[@]}" \
    -install_name "$WIFI_LOAD_PATH" \
    "$BASE/shim_common.c" "$BASE/wifi_keychain_shim.c" \
    -framework CoreFoundation -framework Security \
    -o "$PAYLOAD/usbliter8-wifi.dylib"

/usr/bin/codesign \
    --force --sign - --timestamp=none --pagesize 4096 \
    --identifier com.0xjohnnydev.usbliter8.pairing \
    "$PAYLOAD/usbliter8-pairing.dylib"
/usr/bin/codesign \
    --force --sign - --timestamp=none --pagesize 4096 \
    --identifier com.0xjohnnydev.usbliter8.wifi \
    "$PAYLOAD/usbliter8-wifi.dylib"

print "[3/6] Injecting weak load commands into exact 24A435 daemons"
cp -p "$LOCKDOWN_SOURCE" "$STOCK/lockdownd"
cp -p "$WIFID_SOURCE" "$STOCK/wifid"
cp -p "$LOCKDOWN_SOURCE" "$PAYLOAD/lockdownd"
cp -p "$WIFID_SOURCE" "$PAYLOAD/wifid"

/usr/bin/codesign \
    -d --entitlements "$TESTS/lockdownd.stock.entitlements" \
    "$STOCK/lockdownd" 2>/dev/null
/usr/bin/codesign \
    -d --entitlements "$TESTS/wifid.stock.entitlements" \
    "$STOCK/wifid" 2>/dev/null

"$REPO_ROOT/tools/optool" install \
    -c weak -p "$PAIRING_LOAD_PATH" -t "$PAYLOAD/lockdownd"
"$REPO_ROOT/tools/optool" install \
    -c weak -p "$WIFI_LOAD_PATH" -t "$PAYLOAD/wifid"

print "[4/6] Re-signing while preserving daemon metadata"
for daemon in lockdownd wifid; do
    /usr/bin/codesign \
        --force --sign - --timestamp=none --pagesize 4096 \
        --preserve-metadata=identifier,entitlements,requirements,flags,launch-constraints,library-constraints \
        "$PAYLOAD/$daemon"
    /usr/bin/codesign --verify --strict --verbose=4 "$PAYLOAD/$daemon"
done
for dylib in usbliter8-pairing.dylib usbliter8-wifi.dylib; do
    /usr/bin/codesign --verify --strict --verbose=4 "$PAYLOAD/$dylib"
done

/usr/bin/codesign \
    -d --entitlements "$TESTS/lockdownd.patched.entitlements" \
    "$PAYLOAD/lockdownd" 2>/dev/null
/usr/bin/codesign \
    -d --entitlements "$TESTS/wifid.patched.entitlements" \
    "$PAYLOAD/wifid" 2>/dev/null
cmp "$TESTS/lockdownd.stock.entitlements" \
    "$TESTS/lockdownd.patched.entitlements"
cmp "$TESTS/wifid.stock.entitlements" \
    "$TESTS/wifid.patched.entitlements"

print "[5/6] Verifying Mach-O architecture, platform, and injection"
file "$PAYLOAD/usbliter8-pairing.dylib" | grep -q 'arm64e'
file "$PAYLOAD/usbliter8-wifi.dylib" | grep -q 'arm64e'
otool -l "$PAYLOAD/usbliter8-pairing.dylib" |
    grep -A4 'LC_BUILD_VERSION' | grep -q 'minos 27.0'
otool -l "$PAYLOAD/usbliter8-wifi.dylib" |
    grep -A4 'LC_BUILD_VERSION' | grep -q 'minos 27.0'
[[ "$(xcrun dyld_info -fixups "$PAYLOAD/usbliter8-pairing.dylib" |
    grep -c '__interpose')" == "10" ]]
[[ "$(xcrun dyld_info -fixups "$PAYLOAD/usbliter8-wifi.dylib" |
    grep -c '__interpose')" == "8" ]]

has_one_weak_load() {
    local binary="$1"
    local load_path="$2"
    otool -l "$binary" | awk -v wanted="$load_path" '
        $1 == "cmd" { weak = ($2 == "LC_LOAD_WEAK_DYLIB") }
        $1 == "name" && $2 == wanted && weak { count++ }
        END { exit count == 1 ? 0 : 1 }
    '
}
has_one_weak_load "$PAYLOAD/lockdownd" "$PAIRING_LOAD_PATH"
has_one_weak_load "$PAYLOAD/wifid" "$WIFI_LOAD_PATH"

print "[6/6] Writing reproducible payload manifest"
(
    cd "$PAYLOAD"
    shasum -a 256 \
        lockdownd \
        wifid \
        usbliter8-pairing.dylib \
        usbliter8-wifi.dylib > manifest.sha256
)

print "Payload ready: $PAYLOAD"
sed 's/^/  /' "$PAYLOAD/manifest.sha256"
