# System Layout (Halium-style, HIDL)

## Flash artifacts

Built under `builder/out/`:

- `system.img` (PHH base + Halium overlay + `rootfs.erofs` payload)
- `vbmeta-disabled.img`
- `linux_rootfs.erofs` (intermediate payload used inside `system.img`)

## Partition usage

- `system`: flashed with project-built `system.img` (android-minimal profile by default)
- `vbmeta`: flashed with `vbmeta-disabled.img`
- `boot` / `vendor_boot` / `dtbo` / `vendor` / `userdata`: untouched

`android-minimal` profile keeps `/system` focused on Android core boot skeleton + launcher + compat layer.

## Runtime mount model

1. Android mounts `/system` (our PHH+overlay system image).
2. `ubuntu-gsi-launcher` mounts `/system/usr/share/ubuntu-gsi/rootfs.erofs` read-only.
3. Overlay upper/work reside under `/data/uhl_overlay/{upper,work}`.
4. Large mutable payload stays on `/data` (`/data/ubuntu-gsi/rootfs.erofs*`, app data, caches, overlay delta).
5. Launcher bind-mounts `/vendor`, `/dev`, `/proc`, `/sys`, `/data` into chroot view.
6. `chroot` to Ubuntu systemd.

## Core paths

- `/system/etc/init/ubuntu-gsi.rc`
- `/system/bin/ubuntu-gsi-launcher`
- `/system/bin/ubuntu-gsi-stop-android-ui`
- `/system/usr/lib/ubuntu-gsi/compat/`
- `/system/usr/share/ubuntu-gsi/rootfs.erofs`

For design details and constraints, see `docs/halium-architecture.md`.
