# Standard iPhone 11 / iOS 27 jailbreak with usbliter8

> **CAUTION!**
>
> Running this custom-firmware restore erases the device and leaves SEP,
> passcode, Wi-Fi, baseband, Bluetooth, and Apple services partly or completely
> unavailable. Use only a spare **standard iPhone 11**.

This is **0xjohnny's standard-iPhone-11 port** of Huy's original
[`34306/usbliter8-fun`](https://github.com/34306/usbliter8-fun) work. Huy's
repository is the upstream source of truth; this fork maps and validates that
workflow for the **standard 6.1-inch iPhone 11** (`iPhone12,1`, `n104ap`, A13),
not the Pro or Pro Max. The iOS 27.0 build 24A435 port is in
[`work-27.0-rc-iphone11`](work-27.0-rc-iphone11/README.md). Its corrected
restore path completed a full hardware erase restore, and its tethered normal
boot now carries the beta-2-only kernel and DeviceTree behavior with
fail-closed offset checks. Post-restore SSHRD diagnostics recovered and
validated the exact RootTicket installed in Preboot. The normal chain has been
rebuilt with that ticket, and all 17 inner boot payloads match the previously
audited bundle byte-for-byte. A clean exact-ticket hardware run now completes
`bootx`, enumerates in normal usbmux mode, and launches Sileo 2.5.1 on iOS 27.0
build 24A435.

## Hardware setup

This port was tested with the
[**Waveshare RP2350-USB-A**](https://www.waveshare.com/wiki/RP2350-USB-A)
running compatible `usbliter8` firmware. It has an onboard USB-A host port, so
the iPhone connects with a normal USB-A-to-Lightning cable.

Flash the compatible `usbliter8` firmware through the board's USB-C programming
port, then use its USB-A port for the iPhone DFU connection.

## Downloads

- iOS 27.0 build 24A435 restore IPSW for the standard iPhone 11:
  `iPhone12,1_27.0_24A435_Restore.ipsw`.

Install requirements:

```shell
pip3 install requests pyimg4 pymobiledevice3
```

Work inside `work-27.0-rc-iphone11` for this target.

## Ported patches

The exact 24A435 offsets, preimage guards, verified artifact hashes, restore
status, and Sileo bootstrap details are documented in the
[`iPhone12,1` port README](work-27.0-rc-iphone11/README.md). Do not use the
upstream beta-2 offsets on this build.

## Tutorial

Put the standard iPhone 11 in DFU mode, then connect it to the Waveshare
RP2350-USB-A's USB-A port.

Reconnect the phone directly to the Mac after the exploit. Verify the state with
`irecovery -q`; it must report `MODE: DFU`, `PRODUCT: iPhone12,1`, and
`PWND: usbliter8` before continuing.

### 1. Flash the Custom Firmware

After PWN DFU mode is done, plug the device back into the Mac, then:

```shell
cd work-27.0-rc-iphone11
./make_cfw.py            # requires sudo, enter your password
python3 tss_proxy_server.py && ./restore_cfw.sh
```

You'll see the restore progress bar on screen. Wait until the script is done and the device returns to recovery mode.

### 2. SSHRD boot

Re-enter DFU mode and PWN mode, plug it back into the Mac, then:

```shell
./get_rd.py
./boot_rd.sh
iproxy 2222 22 && ../tools/sshpass -p alpine ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 root@localhost
```

On the SSH'd device, run:

```shell
/sbin/mount_apfs -o rdonly /dev/disk1s6 /mnt6
find /mnt6 -name sep-firmware.img4
```

`scp`/`cat` the file back to the Mac and name it `dev_sep.img4`. Back on the Mac:

```shell
../tools/img4tool -e -m t8030_apticket.der dev_sep.img4
```

Repeat this ticket dump after every successful restore. Reusing the ticket from
before a restore can let the patched boot chain reach verbose kernel output but
then leave the phone on a lit black screen with no normal USB enumeration.

The SSHRD log will print on screen, that means SSHRD succeeded.

### 3. Normal boot

```shell
./get_boot.py
./boot.py
```

That starts the tethered normal boot. Use the guarded SSHRD bootstrap workflow
documented in the port README; normal-mode root SSH is not part of the verified
configuration.

### 4. Get past Setup

On the first normal boot the device lands in Setup and stays there. Two separate things are blocking it.

**a) Activation.**

```shell
./patches/userland_patches.py mobileactivationd mobileactivationd
./patches/userland_patches.py coreauthd coreauthd
./patches/userland_patches.py ctkd ctkd
# re-sign each one, keeping its original entitlements (keep a .orig backup first):
ldid -e mobileactivationd.orig > ents.plist
ldid -S ents.plist -Cadhoc mobileactivationd
```

**b) ScreenTime deadlock.** Setup still hangs on the loading spinner.

`ScreenTimeAgent` is an on-demand job (MachServices, has `.setup`). The fix is to make launchd refuse the launch, so Setup's XPC fails fast instead of hanging:

```shell
scp root@10.7.0.2:/var/db/com.apple.xpc.launchd/disabled.plist .
./patches/disable_screentime.py disabled.plist
scp disabled.plist root@10.7.0.2:/var/db/com.apple.xpc.launchd/disabled.plist
```

### 5. Internet + bootstrap

Wifi and baseband are all broken, so if you need internet to install things:

```shell
./net_up.sh
```

This automatically shares your Mac's internet to the device over USB. After that, do the bootstrap and Sileo will show up.

If Sileo does not show up, re-enter SSHRD mode and move `/var/jb/Applications/Sileo.app` to the `/Applications/` folder in `mnt1` (or `mnt2` depending on your apfs mount). Once you boot back to normal, `uicache` the device to let Sileo appear. The hook already works for the entire system.

You also need to fix symlinks for the bootstrap, check `bootstrap_1900.tar.zst`.

If you only get 3 apps on screen (Settings, Phone and Feedback), move all staged apps to `/Applications/` in the system folder (in SSHRD):

```shell
for a in /mnt2/staged_system_apps/*.app; do
  b=${a##*/}; [ -e /mnt1/Applications/$b ] || cp -R "$a" /mnt1/Applications/
done
```

Enjoy!

## Credits

This port by **0xjohnny** builds on the following work:

- [**Huy (34306)**](https://github.com/34306) for
  [`34306/usbliter8-fun`](https://github.com/34306/usbliter8-fun), the upstream
  implementation and source of truth that this iPhone 11 / 24A435 port follows
- [**usbliter8-fun**](https://github.com/wh1te4ever/usbliter8-fun) by [**wh1te4ever**](https://github.com/wh1te4ever) for CFW and Ramdisk patched for iOS 27.0 beta 2 (24A5370h)
- [**khanhduytran0**](https://github.com/khanhduytran0) for idea on DeviceTree and USB Restriction in kernel
- **img4/img4tool** by [**tihmstar**](https://github.com/tihmstar) for sign IMG4 with APTicket
- **pyimg4/pymobiledevice3** by [**m1stadev**](https://github.com/m1stadev)/[**doronz88**](https://github.com/doronz88) for Export kernelcache, forward usbmux port
- **trollvnc** by [**Lakr233**](https://github.com/Lakr233) for Control device over USB
