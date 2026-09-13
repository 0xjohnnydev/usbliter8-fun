# 24A435 pairing and encrypted Wi-Fi shims

These two narrowly scoped arm64e dylibs work around system-keychain operations
that are unavailable in the SEP-less iPhone 11 boot:

- `usbliter8-pairing.dylib` handles only the `lockdown-identities` /
  `com.apple.lockdown.pairingkeypair` RSA item used by `lockdownd`. It keeps a
  software RSA private key at
  `/private/var/root/Library/Lockdown/usbliter8_pairing_key.der` with mode
  `0600`.
- `usbliter8-wifi.dylib` handles only generic-password items whose service is
  `AirPort`, matching the exact 24A435 `wifid` calls. It keeps a binary plist at
  `/private/var/preferences/SystemConfiguration/com.usbliter8.wifi-passwords.plist`
  with mode `0600`.

The Wi-Fi file contains passwords without SEP/keychain encryption. Treat this
as an explicit security tradeoff of the experimental SEP-less system. WPA3,
enterprise EAP credentials, passcodes, SEP, and a missing Wi-Fi driver are out
of scope.

The file-backed Wi-Fi approach is the modern equivalent of the keychain shim
integrated into
[surrealra1n in commit `a52b864`](https://github.com/pwnerblu/surrealra1n/commit/a52b864540c3a5013762755cdd73d4f2769308f5)
for jailbroken iOS 7 restores. That package also hooks the old Preferences
`WiFiNetwork` class; the class and selector are absent on iOS 27. Here the
credential shim is loaded directly by the exact 24A435 `wifid`, where this
build performs its `AirPort` keychain operations. Credit to
[DevTweaker](https://github.com/DevTweaker/Tweak) for the earlier iOS 7 design.

The patched daemons use `LC_LOAD_WEAK_DYLIB`, so a missing dylib leaves the
original behavior instead of making the daemon unloadable. The build preserves
the exact stock entitlements and other code-signature metadata.

## Build

Pass the directory containing the exact extracted 24A435 filesystem files:

```sh
./build.sh /path/to/24A435__iPhone12,1
```

The build fails closed unless these stock SHA-256 values match:

```text
lockdownd  b42e3a6d87b67d0949fb28b3f07b65e00b4074fd67d5d3f588d01ad3365c2306
wifid      a75c43fc82eabf942c659d6dfa3a494162e551b6b5430a66ea32cdd3c8b63322
```

It runs native key/storage tests, cross-compiles both dylibs for arm64e and
iOS 27, injects the exact daemon copies, preserves their signing metadata, and
writes `build/payload/manifest.sha256`.

## Install and rollback

Boot the existing SSH ramdisk first. While the ramdisk is running:

```sh
./install.sh
```

The installer verifies that `/` is the `md0` ramdisk, mounts System read-write,
pulls and hashes both on-device daemons before changing anything, creates exact
stock backups, installs the dylibs and patched daemons, then reads all four
files back and verifies them byte-for-byte.

To restore the backed-up daemons from SSHRD:

```sh
./install.sh --rollback
```

After installation, perform the normal exact-ticket tethered boot. Successful
pairing creates the software RSA file; joining a password-protected WPA2
network creates the Wi-Fi credential plist.
