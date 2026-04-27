# AOSP frameworks/native (Deferred Submodule)

This directory is a placeholder for the AOSP `platform/frameworks/native` submodule.

## Provides
- `libhidlbase` / `libhidltransport` — HIDL runtime libraries
- `libhwbinder` — HwBinder IPC runtime
- `hwservicemanager` — HIDL hwbinder service manager
- `libbinder` — framework Binder IPC runtime (legacy framework only)
- `servicemanager` — framework binder service manager (legacy framework only)
- `lshal` — list registered HIDL services (used by `hwbinder-bridge`)

## Pinned Version
- **Tag**: `android-11.0.0_r48`
  (last upstream tag where HIDL was the canonical vendor ABI; matches
  what Android 8.0–11.0 vendor partitions ship)
- **Repository**: https://android.googlesource.com/platform/frameworks/native
- **License**: Apache License 2.0
- **Copyright**: Copyright (C) The Android Open Source Project

## Initialization

This submodule is large (~400+ MB). Initialize only when you need to build from source:

```bash
git submodule update --init --depth 1 third_party/aosp_frameworks_native
cd third_party/aosp_frameworks_native
git fetch --depth 1 origin tag android-11.0.0_r48
git checkout android-11.0.0_r48
```
