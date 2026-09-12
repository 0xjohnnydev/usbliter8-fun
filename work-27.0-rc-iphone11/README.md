# iPhone 11 / iOS 27.0 (24A435) port

This directory is the experimental `usbliter8-fun` port for the **iPhone 11**
(`iPhone12,1`, `n104ap`, `t8030`) on **iOS 27.0 build 24A435**.

The IPSW paths and byte offsets have been ported and checked against the local
24A435 restore image. They have not yet been validated by a complete restore and
boot on physical hardware. Treat this as bring-up code, use a spare device, and
expect the custom restore to erase it and leave normal SEP, passcode, radio, and
Apple-service functionality unavailable.

## What was verified offline

- The exact IPSW identity and SHA-256.
- Every firmware path used by the build scripts exists in the iPhone 11 IPSW.
- iBSS/iBEC, TXM, kernelcache, restore ramdisk, and userland patch sites were
  matched to their 24A435 instructions.
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

The first restore attempt on an iPhone 11 running iOS 26.6 reached PWN DFU,
obtained a valid 24A435 erase ticket, and uploaded the complete restore boot
chain, but the phone did not re-enumerate after `bootx`. A later non-erasing boot
with the same patched iBSS/iBEC and Apple's stock restore components reached
restored protocol version 15, confirming that the exploit, ticket flow, and
bootstrap can work on this phone and USB path.

Two later attempts used an experimental `codesign`-based ramdisk and a modified
operational sequence (extra USB probes, manual daemon handling, and a resumed
partial iBSS transfer). Both disconnected during the large ramdisk upload, so
they were not clean tests of the upstream workflow. That experiment has been
removed. The active CFW is rebuilt with upstream's `ldid` commands, and
`restore_cfw.sh`, `boot_rd.sh`, `boot.py`, and the working transfer code in
`tools/usbliter8ctl` match upstream again. Only target paths, component names,
and checked 24A435 patch offsets remain different. A full restore has not yet
been retried with this clean build; the phone remains unchanged on iOS 26.6.

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
x86_64-only; extraction is checked so a missing SSH payload stops the build.

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
| TXM | `0x3df48`, `0x3e0b0`, `0x3e244` | module-query signature comparisons |
| TXM | `0x437b0`, `0x437b8` | constraints signature validation |
| TXM | function `0x2fd04` | normal-boot pre-secure-channel allowance |
| kernel | `0x2fec20c`, `0x2f58ed4`, `0x366924c` | root snapshot/seal checks |
| kernel | function `0x1f00bb8` | launch constraints |
| kernel | function `0x39abbfc` | debugger allowance |
| kernel | `0x1f08978`, `0x1f08ee4`, `0x1f08ef0` | code-signing/dyld policy |
| kernel | function `0x1efbe80` | AMFI trust-cache result |
| kernel | `0x2fed640` | unencrypted Data-volume check |
| restored_external | `0x7e848` | FDR restore result |
| asr | `0x1f66c` | image signature result |

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
