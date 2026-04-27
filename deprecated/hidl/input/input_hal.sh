#!/bin/bash
# =============================================================================
# hidl/input/input_hal.sh — Input/Touchscreen HAL Wrapper (synthetic)
# =============================================================================
# NOTE: HIDL never defined an input HAL — Android InputFlinger always relied
# on direct evdev access plus a Binder (not HwBinder) IPC for the framework.
# This wrapper therefore exposes a synthetic interface
#   ubuntu.gsi.input@1.0::IInputClassifier
# which has no vendor counterpart and always operates in "native" mode by
# preparing /dev/input devices for libinput consumption.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/hidl_hal_base.sh"

# Synthetic interface — will always fall through to "mock" because no vendor
# HIDL declaration exists. We treat the "mock" path as fully-functional.
hidl_hal_init "input" "ubuntu.gsi.input@1.0::IInputClassifier" "optional"

# Override mode: this HAL always runs the same code path regardless of
# whether vendor HIDL is present. HAL_MODE is consumed by hidl_hal_run
# in the sourced common library.
# shellcheck disable=SC2034
HAL_MODE="native"

# ---------------------------------------------------------------------------
# Input device detection
# ---------------------------------------------------------------------------

detect_touchscreen_devices() {
    local ts_count=0

    for event_dev in /dev/input/event*; do
        [ -c "$event_dev" ] || continue

        local dev_name=""
        local sysfs_path
        sysfs_path="/sys/class/input/$(basename "$event_dev")/device/name"
        if [ -f "$sysfs_path" ]; then
            dev_name=$(cat "$sysfs_path" 2>/dev/null)
        fi

        local abs_path
        abs_path="/sys/class/input/$(basename "$event_dev")/device/capabilities/abs"
        if [ -f "$abs_path" ]; then
            local abs_caps
            abs_caps=$(cat "$abs_path" 2>/dev/null)
            if [ -n "$abs_caps" ] && [ "$abs_caps" != "0" ]; then
                case "$dev_name" in
                    *[Tt]ouch*|*goodix*|*Goodix*|*GDIX*|*focaltech*|*fts_ts*|\
                    *NVT*|*nvt*|*himax*|*synaptics*|*Synaptics*|*atmel*|*Atmel*|\
                    *chipone*|*ilitek*|*ILITEK*|*sec_touchscreen*|*elan*|*raydium*|\
                    *mtk-tpd*|*mtk_tpd*)
                        hal_info "Touchscreen: $event_dev ($dev_name)"
                        ts_count=$((ts_count + 1))
                        ;;
                    *)
                        hal_info "Input device with abs: $event_dev ($dev_name)"
                        ts_count=$((ts_count + 1))
                        ;;
                esac
            fi
        fi
    done

    hal_set_state "touchscreen_count" "$ts_count"
    echo "$ts_count"
}

detect_all_input_devices() {
    local input_count=0

    for event_dev in /dev/input/event*; do
        [ -c "$event_dev" ] || continue
        input_count=$((input_count + 1))

        local dev_name=""
        local sysfs_path
        sysfs_path="/sys/class/input/$(basename "$event_dev")/device/name"
        if [ -f "$sysfs_path" ]; then
            dev_name=$(cat "$sysfs_path" 2>/dev/null)
        fi
        hal_info "Input device: $event_dev ($dev_name)"
    done

    hal_set_state "input_device_count" "$input_count"
    echo "$input_count"
}

set_input_permissions() {
    for event_dev in /dev/input/event*; do
        [ -c "$event_dev" ] || continue
        chmod 0660 "$event_dev" 2>/dev/null || true
        chgrp input "$event_dev" 2>/dev/null || true
    done

    chmod 0755 /dev/input 2>/dev/null || true

    hal_info "Input device permissions configured"
}

configure_libinput() {
    local quirks_dir="/etc/libinput"
    mkdir -p "$quirks_dir"

    cat > "$quirks_dir/90-ubuntu-gsi-touch.quirks" << 'QUIRKSEOF'
# Ubuntu HIDL GSI — Android vendor touchscreen quirks
# Applied to all detected touchscreen devices

[Ubuntu HIDL GSI Touchscreen Defaults]
MatchUdevType=touchscreen
AttrPalmSizeThreshold=0
AttrPalmPressureThreshold=0
AttrThumbPressureThreshold=0
QUIRKSEOF

    hal_info "libinput quirks configured"
}

setup_udev_trigger() {
    if command -v udevadm >/dev/null 2>&1; then
        udevadm trigger --subsystem-match=input --action=change 2>/dev/null || true
        udevadm settle --timeout=5 2>/dev/null || true
        hal_info "udev input rules triggered"
    fi
}

# ---------------------------------------------------------------------------
# Main handler — always runs; HIDL has no native input HAL.
# ---------------------------------------------------------------------------
input_native() {
    hal_info "Initializing input/touchscreen subsystem (no HIDL vendor counterpart)"

    set_input_permissions
    configure_libinput
    setup_udev_trigger

    local ts_count=0
    local retries=0
    local max_retries=15

    while [ $retries -lt $max_retries ]; do
        ts_count=$(detect_touchscreen_devices)
        if [ "$ts_count" -gt 0 ]; then
            break
        fi
        retries=$((retries + 1))
        hal_info "Waiting for touchscreen device... (attempt $retries/$max_retries)"
        sleep 2
    done

    local input_count
    input_count=$(detect_all_input_devices)

    if [ "$ts_count" -eq 0 ]; then
        hal_warn "No touchscreen detected after $max_retries attempts"
        hal_warn "Total input devices: $input_count"
        hal_set_state "status" "no_touchscreen"
    else
        hal_info "Touchscreen ready: $ts_count touchscreen(s), $input_count total input devices"
        hal_set_state "status" "active"
    fi

    while true; do
        local current_count=0
        for event_dev in /dev/input/event*; do
            [ -c "$event_dev" ] || continue
            current_count=$((current_count + 1))
        done

        if [ "$current_count" -ne "$input_count" ]; then
            hal_info "Input device change detected: $input_count → $current_count"
            set_input_permissions
            input_count=$current_count
            hal_set_state "input_device_count" "$input_count"
        fi

        sleep 30
    done
}

input_mock() {
    input_native
}

hidl_hal_run input_native input_mock
