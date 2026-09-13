# iPhone 11 / iOS 27.0 (24A435) port

This directory is the experimental `usbliter8-fun` port for the **iPhone 11**
(`iPhone12,1`, `n104ap`, `t8030`) on **iOS 27.0 build 24A435**.

The IPSW paths and byte offsets have been ported and checked against the local
24A435 restore image. The corrected restore patch set completed a full erase
restore on a physical iPhone 11 on 2026-09-12. Treat this as bring-up code, use a
spare device, and expect the custom image to leave normal SEP, passcode, radio,
and Apple-service functionality unavailable.

## What was verified offline

- The exact IPSW identity and SHA-256.
- Every firmware path used by the build scripts exists in the iPhone 11 IPSW.
- iBSS/iBEC, TXM, kernelcache, restore ramdisk, and userland patch sites were
  matched to their 24A435 instructions. The restore/boot chains also preserve
  the nonce exactly as the hardware-tested beta-2 workflow does, and the two
  beta-2 restore-time baseband predicates were mapped by symbol, function body,
  and caller set to the 24A435 `restored_external`.
- A complete offline `make_cfw.py` build finished successfully. The rebuilt
  IMG4/PAYP metadata parses, all 35 CFW postimages match the requested patches,
  and the repacked DeviceTree matches the verified transform byte-for-byte.
- A device-specific erase ticket was requested from Apple while the test phone
  was in PWN DFU. Its ECID, board/chip IDs, AP nonce, SEP nonce, and all 17 image
  types consumed by the ramdisk/boot builders match this phone and the 24A435
  Customer Erase manifest. The ticket remains ignored by Git.
- A complete `get_rd.py` build finished on Apple Silicon. All 18 expected
  ramdisk outputs are non-empty, every signed IMG4 reports the expected type,
  and a read-only extraction of `RestoreRamdisk.img4` contains executable arm64
  Dropbear and SFTP server binaries.
- Each binary write is guarded by an expected preimage in `checked_patch.py` or
  `userland_patches.py`. A wrong build, stale artifact, or already-patched input
  stops with a mismatch instead of being written again.

## Hardware bring-up status

The first complete hardware validation succeeded on an iPhone 11 (`n104ap`).
With the corrected AMFI branch at kernel file offset `0x1f0897c`, the device
entered `com.apple.mobile.restored` protocol 15, accepted the RootTicket,
validated and restored the filesystem, installed Cryptex, kernelcache, and
DeviceTree, sealed the System volume, and ended with `Status: Restore Finished`,
`DONE`, and host exit status 0. This confirms the restore-time offset set and
the semantic AMFI fix on 24A435.

The first tethered normal-boot attempt after that restore uploaded every image
and made the phone leave iBoot, but the kernel never re-enumerated USB. Review
then found that this RC directory had originally been derived from the repo's
`work-27.0b3` recipe, while the known-working normal-boot additions live only
in `work-27.0b2`. The missing beta-2 DeviceTree behavior and seven kernel
functions are now mapped to 24A435 and guarded by their exact stock bytes.

A hardware retry reached `bootx` but still failed to enumerate. A complete
beta-2-to-RC function audit then found two mislabeled upstream CredentialManager
offsets that the initial RC port had incorrectly moved to named function
entries. Beta 2's odd `0x20f93c9` write crosses the `BTI c` landing pad of
`performLoggingLevelQueryGated`; that stock RC leaf already returns zero and is
left intact. Beta 2's `0x21066b0` write is an internal branch in
`_onEnablePolicy`, not the commented `setPowerStateGated` entry at
`0x2107a5c`. The exact `_onEnablePolicy` basic block is structurally unchanged
in RC and is now patched at `0x20d0724`, reproducing the working binary's actual
control flow while leaving the real `setPowerStateGated` entry intact. All
other active TXM and kernel mappings match their beta-2 instruction and
function context.

An artifact-lineage audit also compared every payload used by `boot.py` with
the CFW that completed the hardware restore. Eleven payloads, including SEP,
SPTM, the restore trust cache, and all unmodified coprocessor firmware, are
byte-for-byte identical. The only differences are the intended normal-boot
deltas: boot arguments and nonce preservation in iBSS/iBEC, eight TXM bytes in
`_allowedBeforeSecureChannelOperational`, one DeviceTree byte for
`/chosen/ephemeral-storage`, and the mapped normal-boot kernel patches. The
image order and personalized sizes match the successful restore log. Before
touching USB, `boot.py` now verifies both the complete tethered-boot set and the
successful CFW base against `boot-artifacts.sha256` and fails closed on drift.

The repeated post-`bootx` state lights and clears the framebuffer but never
enumerates USB, proving that execution has passed from iBoot into XNU. The
upstream `serial=3` argument makes XNU switch from its video console to the
hardware serial console, which hides the stopping line without a serial capture
cable. The normal-boot iBSS/iBEC arguments now keep `-v`, add `keepsyms=1`, and
omit `serial=3` so the next hardware run exposes kernel progress on screen.

The first restore attempt on an iPhone 11 running iOS 26.6 reached PWN DFU,
obtained a valid 24A435 erase ticket, and uploaded the complete restore boot
chain, but the phone did not re-enumerate after `bootx`. A later non-erasing boot
with the same patched iBSS/iBEC and Apple's stock restore components reached
restored protocol version 15, confirming that the exploit, ticket flow, and
bootstrap can work on this phone and USB path.

Two later attempts used an experimental `codesign`-based ramdisk and a modified
operational sequence (extra USB probes, manual daemon handling, and a resumed
partial iBSS transfer). Both disconnected during the large ramdisk upload, so
they were not clean tests of the upstream workflow. That experiment was
removed before further testing. A subsequent upstream-parity run uploaded every
component, including the complete restore ramdisk and kernel, but the device did
not enumerate as a restored-mode device after `bootx`; no erase or
`StartRestore` occurred.

The initial headless-IDA comparison correctly mapped most instruction sites but
missed a semantic control-flow change in AMFI's `postValidation`. Beta 2 rejects
every hash type except SHA-256 (`CMP W0, #2; B.NE failure`), whereas 24A435 has a
dedicated SHA-1 rejection block (`CMP W0, #1; B.NE continue`). Copying beta 2's
`CMP W0, W0` replacement to the RC comparison made the conditional branch fall
through and forced every validation into the SHA-1 error path. The corrected RC
patch is at `0x1f0897c` and replaces that conditional branch with an
unconditional branch to the continuation block.

A clean hardware retry with the nonce/baseband corrections uploaded every
component but again failed to enumerate after `bootx`. A later retry also ruled
out the suspected restore-ramdisk signature metadata as the root cause: bare
`ldid -S` had changed
`com.apple.restored_external` to `restored_external` and removed the binary's
self launch-constraint slot. The RC build therefore re-signs with macOS `codesign`
while preserving Apple's identifiers, entitlements, requirements, flags, and
launch constraints. It also explicitly retains the stock 4096-byte
CodeDirectory page size and the restore ramdisk's `desc: 0` IM4P metadata. The
rebuilt ramdisk passes `codesign --verify`, retains all eight special slots on
`restored_external`, and still contains every checked binary patch, but that
metadata-preserving image produced the same post-`bootx` failure. The next clean
run included the corrected AMFI branch and completed the restore, confirming
that the inverted RC control flow—not the preserved signature metadata—was the
blocking defect.

Target IPSW SHA-256:

```text
179435db886454b043575280911f4347783d1d223189e7d44f9a3baaf66e3abd
```

## Prepare the local firmware

Install the upstream Python dependencies:

```sh
python3 -m pip install requests pyimg4 pymobiledevice3 pyusb
```

From this directory, validate the local IPSW without extracting it:

```sh
./get_fw.py --verify-only /Users/johnnyfranks/Downloads/iPhone12,1_27.0_24A435_Restore.ipsw
```

Then extract it:

```sh
./get_fw.py /Users/johnnyfranks/Downloads/iPhone12,1_27.0_24A435_Restore.ipsw
```

The later ramdisk and normal-boot builders require a device-specific,
build-compatible `t8030_apticket.der` in this directory. It is intentionally
ignored by Git and is not copied from the upstream beta build. `get_rd.py` uses
the native macOS `/usr/bin/tar` because the inherited `tools/gtar` executable is
x86_64-only. The image is mounted with ownership disabled, so the SSH ramdisk
can be built without `sudo`; extraction is checked so a missing SSH payload
stops the build.

The ticket must be refreshed after every successful restore. A ticket captured
before the restore can pass the patched early boot chain and still stall after
the verbose kernel log clears, leaving a lit black display and no USB device.
Dump the post-restore ticket from Preboot with the SSH ramdisk as described in
the repository tutorial, then rerun `get_boot.py`. While Apple is still signing
the build, the same ticket can instead be requested with the AP and SEP nonces
recorded by the successful restore log; validate its ECID, `N104AP` target,
build, both nonces, and TSS signature before replacing the old ticket.

## Bring-up order

The inherited workflow is:

```sh
./make_cfw.py
python3 tss_proxy_server.py
# In another terminal, only when a spare phone is ready in PWN DFU:
./restore_cfw.sh

./get_rd.py
./boot_rd.sh

./get_boot.py
./boot.py
```

The restore and tethered-boot launchers deliberately fail before touching USB
unless their selected Python has PyUSB. Activate the dependency environment
first, or set `USBLITER8_PYTHON` to that environment's Python executable.

Do not start `restore_cfw.sh` merely to test the scripts: it invokes an erase
restore. The safe stopping point for offline preparation is after building and
inspecting the CFW/Ramdisk outputs.

For a hardware run, execute the inherited flow once from fresh PWN DFU. Do not
insert a status probe, manually stop macOS USB daemons, or resume a partial
transfer between the Waveshare handoff and `restore_cfw.sh`.

## Ported patch landmarks

| Component | 24A435 file offset | Purpose |
| --- | ---: | --- |
| iBSS + iBEC | `0x236e8`, `0x236ec` | IMG4 property validation return path |
| iBSS + iBEC | `0x2aa0c`, `0x2aa10`, string at `0xd1158` | boot-args pointer and string |
| iBSS + iBEC | `0x366a8` | preserve the recovery nonce (iBEC for restore; both stages for later boots) |
| TXM | `0x3df48`, `0x3e0b0`, `0x3e244` | module-query signature comparisons |
| TXM | `0x437b0`, `0x437b8` | constraints signature validation |
| TXM | function `0x2fd04` | normal-boot pre-secure-channel allowance |
| kernel | `0x2fec20c`, `0x2f58ed4`, `0x366924c` | root snapshot/seal checks |
| kernel | function `0x1f00bb8` | launch constraints |
| kernel | function `0x39abbfc` | debugger allowance |
| kernel | `0x1f0897c`, `0x1f08ee4`, `0x1f08ef0` | code-signing/dyld policy |
| kernel | function `0x1efbe80` | AMFI trust-cache result |
| kernel | function `0x28053d0` | report restore mode so usbmux is available before first unlock |
| kernel | functions `0x2f219fc`, `0x2f1f998`, `0x2f1f7c8`, `0x2f1f45c`, `0x2f1a480` | beta-2 sandbox mmap/mount/rename hooks |
| kernel | `0x2fed640` | unencrypted Data-volume check |
| kernel | function `0x33ad6a4` | permit class opens without content protection |
| DeviceTree | `/chosen/ephemeral-storage = 1` | match the beta-2 normal-boot path |
| restored_external | `0x7e848` | FDR restore result |
| restored_external | functions `0x49ddc`, `0x49e54` | report no legacy/current baseband during custom restore |
| asr | `0x1f670` | conditional image-signature failure branch |

`get_boot.py` also contains the 24A435 AppleSEPManager and
AppleCredentialManager normal-boot patch set. All of those locations have
preimage guards in `checked_patch.py`.

## Userland patches

The three offsets checked for 24A435 are:

| Binary | Offset | Change |
| --- | ---: | --- |
| `coreauthd` | `0x95c0` | NOP `objc_msgSend$startController` call |
| `ctkd` | `0x1b38`, `0x1b3c` | return `nil` from `serverAttributesOfKey:error:` |
| `mobileactivationd` | `0x2ec368` | make `should_hactivate` return true |

Check a binary without changing it:

```sh
./userland_patches.py mobileactivationd /path/to/mobileactivationd --check
```

Omit `--check` to patch it. The tool first verifies the original instructions,
creates a sibling `.orig` backup, writes the patch, and verifies the result.
Re-sign the patched binary while preserving the entitlements extracted from the
`.orig` file.

The older beta-2 script also replaced a secondary
`getActivationStateWithCompletionBlock` path. That path has deliberately not
been guessed here; only the directly verified 24A435 `should_hactivate` method is
included for the first hardware test.

The Setup/ScreenTime launchd workaround remains available at
`../patches/disable_screentime.py`; it is data-driven and has no build-specific
instruction offsets.
