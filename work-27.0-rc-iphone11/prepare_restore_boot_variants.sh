#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
cd "$SCRIPT_DIR"

SOURCE=CFW
RAMDISK=043-69915-775.dmg
DEVICETREE=Firmware/all_flash/DeviceTree.n104ap.im4p
TXM=Firmware/txm.iphoneos.release.im4p
KERNEL=kernelcache.release.iphone12b

for component in "$RAMDISK" "$DEVICETREE" "$TXM" "$KERNEL"; do
    if [[ ! -f "$SOURCE/$component" || ! -f "$SOURCE/$component.bak" ]]; then
        print -u2 "missing current or original component: $SOURCE/$component"
        exit 1
    fi
done

make_variant() {
    local name=$1
    local description=$2
    shift 2

    if [[ -e "$name" ]]; then
        print -u2 "$name already exists; refusing to merge or overwrite it"
        exit 1
    fi

    print "Preparing $name"
    cp -cR "$SOURCE" "$name"

    local component
    for component in "$@"; do
        cp -c "$SOURCE/$component.bak" "$name/$component"
    done

    print -r -- "$description" > "$name/DIAGNOSTIC_VARIANT.txt"
}

# These form a cumulative matrix. Each stage adds one class of 24A435 patch,
# making the first restore-OS component that fails to boot unambiguous.
make_variant CFW_DIAG_1_STOCK_RESTORE \
    "Original ramdisk, DeviceTree, TXM, and kernel; patched iBEC only." \
    "$RAMDISK" "$DEVICETREE" "$TXM" "$KERNEL"

make_variant CFW_DIAG_2_KERNEL \
    "Patched kernel; original ramdisk, DeviceTree, and TXM." \
    "$RAMDISK" "$DEVICETREE" "$TXM"

make_variant CFW_DIAG_3_KERNEL_DT \
    "Patched kernel and DeviceTree; original ramdisk and TXM." \
    "$RAMDISK" "$TXM"

make_variant CFW_DIAG_4_KERNEL_DT_TXM \
    "Patched kernel, DeviceTree, and TXM; original ramdisk." \
    "$RAMDISK"

print
print "Prepared restore-boot variants:"
for variant in CFW_DIAG_{1..4}_*; do
    print "  $variant: $(<"$variant/DIAGNOSTIC_VARIANT.txt")"
done
