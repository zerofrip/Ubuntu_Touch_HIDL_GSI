# Ubuntu Touch HIDL GSI (Halium-style)

[![Build](https://github.com/zerofrip/Ubuntu_Touch_HIDL_GSI/actions/workflows/build.yml/badge.svg)](https://github.com/zerofrip/Ubuntu_Touch_HIDL_GSI/actions/workflows/build.yml)
[![Lint](https://github.com/zerofrip/Ubuntu_Touch_HIDL_GSI/actions/workflows/lint.yml/badge.svg)](https://github.com/zerofrip/Ubuntu_Touch_HIDL_GSI/actions/workflows/lint.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

Ubuntu Touch for Treble devices with **HIDL-era vendor stacks** (Android 8-11), redesigned to keep stock boot components untouched.

## Design Goals

- Keep **stock `boot.img`** untouched.
- Keep **stock kernel** untouched.
- Flash only:
  - `system.img`
  - `vbmeta-disabled.img`
- Do not flash `boot`, `vendor_boot`, `dtbo`, or `vendor`. `userdata` is opt-in
  (`bash scripts/flash.sh --with-userdata`).

## Current Architecture (Halium-style)

Android boots normally, then launches Ubuntu userspace late in boot:

1. Stock bootloader + stock kernel + stock ramdisk init (PID 1)
2. PHH-based `/system` boots Android framework + vendor HAL services
3. `/system/etc/init/ubuntu-gsi.rc` starts `ubuntu-gsi-launcher`
4. Launcher mounts `rootfs.erofs`, builds overlay on `/data/uhl_overlay`, then `chroot`s into Ubuntu systemd
5. Lomiri/Mir starts from inside the Ubuntu chroot

Authoritative design doc: `docs/halium-architecture.md`

## Repository Roles

- `halium/`
  - `etc/init/ubuntu-gsi.rc` Android init service definitions
  - `bin/ubuntu-gsi-launcher` chroot pivot driver
  - `bin/ubuntu-gsi-stop-android-ui` SurfaceFlinger hand-off helper
  - `compat/` PHH/TrebleDroid-style compatibility engine
  - `lomiri/start-lomiri.sh` Lomiri/libhybris startup scaffold
- `scripts/`
  - `fetch_phh_gsi.sh` PHH base download/prepare
  - `build_rootfs.sh` Ubuntu chroot rootfs build
  - `build_rootfs_erofs.sh` rootfs -> erofs pack
  - `build_vbmeta_disabled.sh` disabled vbmeta build
  - `build_system_img.sh` PHH base + Halium overlay merge
  - `flash.sh` flashes `system + vbmeta` only
- `deprecated/`
  - legacy pre-Halium components kept for reference

## Build Prerequisites

```bash
sudo apt install \
  debootstrap qemu-user-static e2fsprogs erofs-utils jq wget unzip \
  android-sdk-libsparse-utils android-tools-fastboot python3
```

`avbtool` is recommended for production `vbmeta-disabled.img` generation.

## Build

```bash
git clone --recursive https://github.com/zerofrip/Ubuntu_Touch_HIDL_GSI.git
cd Ubuntu_Touch_HIDL_GSI

make build
```

Pipeline:

- PHH fetch -> rootfs build -> erofs pack -> vbmeta-disabled -> system image compose

Artifacts are generated under `builder/out/`:

- `system.img`
- `linux_rootfs.erofs`
- `vbmeta-disabled.img`

## Flash

```bash
make flash
```

or manually:

```bash
fastboot --disable-verity --disable-verification flash vbmeta builder/out/vbmeta-disabled.img
fastboot flash system builder/out/system.img
fastboot reboot
```

Selective flash:

```bash
make flash-system
make flash-vbmeta
bash scripts/flash.sh --with-userdata
```

## Runtime Control

Enable Ubuntu launcher (default is auto-on from init rules):

```bash
adb shell setprop persist.ubuntu_gsi.enable 1
```

Disable launcher and boot Android-only userspace:

```bash
adb shell setprop persist.ubuntu_gsi.enable 0
adb reboot
```

## Compatibility Engine

The compatibility layer is inspired by:

- [phhusson/device_phh_treble](https://github.com/phhusson/device_phh_treble)
- [phhusson/vendor_hardware_overlay](https://github.com/phhusson/vendor_hardware_overlay)
- [TrebleDroid/treble_app](https://github.com/TrebleDroid/treble_app)

Main files:

- `halium/compat/quirks.json`
- `halium/compat/compat-engine.sh`
- `halium/compat/prop-handler.sh`
- `halium/compat/lib/detect-platform.sh`

Engine supports mode-aware execution (`android`, `linux`, `both`) for per-action filtering.

## Vendor Branch Strategy

PHH GSI config is resolved per git branch via `scripts/load_vendor_config.sh`.
Build on the matching `android-X.Y` branch (or export `VENDOR_ANDROID_VERSION`).

| Branch | PHH tag | PHH variant (`system-<variant>.img.xz`) |
|---|---|---|
| `android-8.1`  | `v32`  | `arm64-ab-vanilla-nosu` |
| `android-9.0`  | `v123` | `arm64-ab-vanilla-nosu` |
| `android-10.0` | `v222` | `quack-arm64-ab-vanilla` |
| `android-11.0` | `v313` | `roar-arm64-ab-vanilla` |
| `android-12.0` | `v402` | `squeak-arm64-ab-vanilla` |
| `android-12.1` | `v416` | `squeak-arm64-ab-vanilla` |

All branches use `PHH_GSI_REPO=phhusson/treble_experimentations`.
Only `arm64 A/B` (dynamic partition) PHH variants are supported.

Local source build mode:

- Set `PHH_GSI_SOURCE=custom`
- Set `TREBLE_EXP_PATH` to your local `treble_experimentations` checkout
- Optionally set `PHH_CUSTOM_TARGET` and `PHH_CUSTOM_VARIANT`
- Run `make phh-custom` (or `make build`)

Smaller preset shortcut:

- `make phh-custom-minimal`
- Equivalent to `PHH_CUSTOM_TARGET=android-14.0` + `PHH_CUSTOM_VARIANT=td-arm64-ab-vanilla`

Ultra-light rootfs preset:

- `make build-minimal`
- Uses `GSI_ROOTFS_PROFILE=minimal` and `rootfs/packages.minimal.list`
- Also applies aggressive rootfs pruning by default in minimal mode

Rootfs persistence/self-heal:

- Launcher keeps runtime rootfs in `/data/ubuntu-gsi/rootfs.erofs`
- Backup copy is kept at `/data/ubuntu-gsi/rootfs.erofs.bak`
- SHA-256 is verified at boot; missing/corrupt data copy is auto-restored
- Restore source is system seed `/system/usr/share/ubuntu-gsi/rootfs.erofs`
- `ROOTFS_SEED_IN_SYSTEM=1` (default) embeds the reset-time seed in `system.img`; userdata is flashed only with `--with-userdata` (first boot self-seeds otherwise)

System layout profile:

- `SYSTEM_LAYOUT_PROFILE=android-minimal` (default): keeps `/system` to Android core skeleton + launcher + compat footprint
- `SYSTEM_LAYOUT_PROFILE=full`: keeps the full PHH payload
- Large mutable payload (`rootfs`, app data, caches, overlay upper/work) is placed under `/data`


Quick reference flash guide: `docs/flash_quickstart.md`

## Notes

- Legacy docs/scripts that mention `linux_rootfs.squashfs`, `userdata.img` pivot, or binder bridge daemons are historical and replaced by the Halium-style flow.
- See `docs/boot_flow.md` and `docs/halium-architecture.md` for current behavior.
