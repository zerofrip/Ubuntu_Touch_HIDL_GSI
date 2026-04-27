#!/bin/bash
# =============================================================================
# hidl/fingerprint/fingerprint_hal.sh — Fingerprint HIDL HAL Wrapper
# =============================================================================
# Bridges fprintd / libfprint to Android vendor Fingerprint HAL via HIDL
# (android.hardware.biometrics.fingerprint@2.3::IBiometricsFingerprint).
#
# Detection flow:
#   1. Probe for fingerprint device nodes (/dev/goodix_fp, /dev/fpsensor, ...)
#   2. Probe USB / I2C / SPI fingerprint sensors via libfprint
#   3. Set permissions, start fprintd, expose to Lomiri
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/hidl_hal_base.sh"

hidl_hal_init "fingerprint" "android.hardware.biometrics.fingerprint@2.3::IBiometricsFingerprint" "optional"

FP_DEVICES=""
FP_COUNT=0
FP_VENDOR="unknown"

# ---------------------------------------------------------------------------
# Fingerprint device discovery
# ---------------------------------------------------------------------------
detect_fp_devices() {
    FP_DEVICES=""
    FP_COUNT=0

    for dev in /dev/goodix_fp /dev/fpsensor /dev/fpc1020 /dev/fpc_irq \
               /dev/silead_fp /dev/qbt1000 /dev/qfp /dev/synaptics_dsx \
               /dev/elan-spi /dev/egis_fp; do
        if [ -e "$dev" ]; then
            FP_DEVICES="${FP_DEVICES} ${dev}"
            FP_COUNT=$((FP_COUNT + 1))
            case "$dev" in
                *goodix*)    FP_VENDOR="goodix" ;;
                *fpc*)       FP_VENDOR="fpc" ;;
                *silead*)    FP_VENDOR="silead" ;;
                *qbt*|*qfp*) FP_VENDOR="qualcomm" ;;
                *synaptics*) FP_VENDOR="synaptics" ;;
                *elan*)      FP_VENDOR="elan" ;;
                *egis*)      FP_VENDOR="egis" ;;
            esac
            hal_info "Fingerprint device: $dev (vendor: $FP_VENDOR)"
        fi
    done

    hal_set_state "vendor" "$FP_VENDOR"
    hal_set_state "fp_count" "$FP_COUNT"
}

set_fp_permissions() {
    for dev in $FP_DEVICES; do
        chmod 0660 "$dev" 2>/dev/null || true
        chgrp plugdev "$dev" 2>/dev/null || true
    done
}

start_fprintd() {
    if ! command -v fprintd >/dev/null 2>&1 && ! [ -x /usr/libexec/fprintd ]; then
        hal_warn "fprintd not installed"
        return 1
    fi

    if systemctl list-unit-files fprintd.service >/dev/null 2>&1; then
        systemctl enable fprintd.service 2>/dev/null || true
        hal_info "fprintd D-Bus service enabled (activated on demand)"
    fi
    return 0
}

probe_libfprint() {
    if command -v fprintd-list >/dev/null 2>&1; then
        local users
        users=$(fprintd-list 2>/dev/null || true)
        hal_info "fprintd known users: ${users:-<none>}"
    fi
}

# ---------------------------------------------------------------------------
# Native handler — vendor fingerprint HIDL HAL available
# ---------------------------------------------------------------------------
fingerprint_native() {
    hal_info "Fingerprint HIDL HAL detected — initializing fprintd bridge"

    detect_fp_devices

    if [ "$FP_COUNT" -eq 0 ]; then
        local retries=0
        while [ "$FP_COUNT" -eq 0 ] && [ "$retries" -lt 5 ]; do
            sleep 2
            retries=$((retries + 1))
            detect_fp_devices
        done
    fi

    if [ "$FP_COUNT" -gt 0 ]; then
        set_fp_permissions
        start_fprintd
        probe_libfprint
        hal_set_state "status" "active"
    else
        hal_warn "No vendor fingerprint device — falling back to libfprint USB"
        start_fprintd
        probe_libfprint
        hal_set_state "status" "libfprint_only"
    fi

    while true; do
        sleep 60
    done
}

# ---------------------------------------------------------------------------
# Mock handler — no vendor HAL but USB sensor might exist
# ---------------------------------------------------------------------------
fingerprint_mock() {
    hal_info "Fingerprint HAL mock: probing libfprint-supported USB sensors"

    detect_fp_devices

    if start_fprintd; then
        probe_libfprint
        hal_set_state "status" "libfprint_only"
    else
        hal_set_state "status" "mock"
    fi

    while true; do
        sleep 60
    done
}

hidl_hal_run fingerprint_native fingerprint_mock
