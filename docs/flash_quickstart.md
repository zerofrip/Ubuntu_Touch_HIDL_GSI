# Flash Quickstart (Halium-style, HIDL)

This quickstart assumes you want to keep stock `boot.img` and stock kernel unchanged.

## 1) Build

```bash
cd Ubuntu_Touch_HIDL_GSI
make build
```

Expected artifacts in `builder/out/`:

- `system.img`
- `vbmeta-disabled.img`

## 2) Reboot device to fastboot

```bash
adb reboot bootloader
```

or use hardware keys.

## 3) Flash only system + vbmeta

```bash
fastboot --disable-verity --disable-verification flash vbmeta builder/out/vbmeta-disabled.img
fastboot flash system builder/out/system.img
fastboot reboot
```

Do **not** flash `boot`, `vendor_boot`, `dtbo`, or `vendor`. `userdata` is
opt-in (see below).

## 4) Runtime toggle

Enable launcher:

```bash
adb shell setprop persist.ubuntu_gsi.enable 1
```

Disable launcher (boot Android userspace only):

```bash
adb shell setprop persist.ubuntu_gsi.enable 0
adb reboot
```

## 5) Recovery path

If the UI does not come up, return to Android-only userspace:

```bash
adb shell setprop persist.ubuntu_gsi.enable 0
adb reboot
```

If system partition is broken, reflash stock system from OEM package.

## Verifying apt upgrade safety

From the second boot onward, `apt upgrade`/`apt dist-upgrade` can be used
inside the chroot to update all packages. Because this environment runs on
top of the unmodified Android kernel (there is no real `/boot`, no
initramfs-tools-managed initrd, and no bootloader for the chroot to manage),
the rootfs ships an apt pin (`/etc/apt/preferences.d/90-ubuntu-gsi-no-kernel.pref`)
that prevents `linux-image*`, `linux-headers*`, `initramfs-tools*`, `grub*`,
and related packages from ever being installed or upgraded, even
transitively.

To confirm the safeguard is active:

```bash
adb shell
apt-get update
apt-get dist-upgrade --dry-run
```

Check the dry-run output: packages matching `linux-image*`, `linux-headers*`,
`linux-modules*`, `linux-base`, `initramfs-tools*`, `grub*`, `flash-kernel`,
`u-boot*`, `shim*`, or `systemd-boot` must **not** appear in the list of
packages to be installed or upgraded. If any do appear, the pin file is
missing or was overridden; do not proceed with the upgrade.

### When userdata is (not) flashed

| Situation | userdata |
|-----------|----------|
| Normal first-time flash | Not flashed (self-seeded from `system.img` on first boot) |
| Corrupted `/data/ubuntu-gsi` you want to rebuild without self-heal | Optional (`--with-userdata`) |
| Build with `ROOTFS_SEED_IN_SYSTEM=0` (smaller `system.img`) | Required (`--with-userdata`) |

```bash
bash scripts/flash.sh                  # default — no userdata
bash scripts/flash.sh --with-userdata  # system + vbmeta + userdata
bash scripts/flash.sh --no-userdata    # default; kept for compatibility
bash scripts/flash.sh --userdata-only  # userdata only
```

### Escape hatch: flashing userdata (opt-in)

`userdata.img` is no longer part of the default flow. It is still built and can be
flashed when needed (e.g. `ROOTFS_SEED_IN_SYSTEM=0` builds where the system image
carries no rootfs seed — `userdata.img` is then the only provisioning path).

```bash
make userdata                              # build it if not present
bash scripts/flash.sh --with-userdata      # system + vbmeta + userdata
bash scripts/flash.sh --userdata-only      # userdata only
```

Flashing `userdata` **wipes Android `/data`** (apps, Wi-Fi, settings).

On MediaTek devices, fastboot-flashing `userdata` makes stock recovery show an
"erase data" confirmation prompt on next boot. This is a stock recovery
security gate independent of the image content.

