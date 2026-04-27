#!/bin/bash
# =============================================================================
# hidl/bluetooth/bluetooth_hal.sh — Bluetooth HIDL HAL Wrapper
# =============================================================================
# Bridges BlueZ to Android vendor Bluetooth HAL via
# HIDL hwbinder interface android.hardware.bluetooth@1.1::IBluetoothHci.
#
# Detection:
#   1. Identify Bluetooth controller (HCI) via /sys/class/bluetooth/
#   2. Load vendor firmware patches if needed
#   3. Bring up HCI interface (hciconfig hciX up)
#   4. Start bluetoothd (BlueZ daemon)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/hidl_hal_base.sh"

hidl_hal_init "bluetooth" "android.hardware.bluetooth@1.1::IBluetoothHci" "optional"

# ---------------------------------------------------------------------------
# HCI device detection
# ---------------------------------------------------------------------------
detect_hci_devices() {
    HCI_COUNT=0
    HCI_DEVICES=""

    if [ -d /sys/class/bluetooth ]; then
        for hci_dir in /sys/class/bluetooth/hci*; do
            [ -d "$hci_dir" ] || continue
            local hci_name
            hci_name=$(basename "$hci_dir")
            HCI_DEVICES="${HCI_DEVICES} ${hci_name}"
            HCI_COUNT=$((HCI_COUNT + 1))
            hal_info "HCI device: $hci_name"
        done
    fi

    hal_set_state "hci_count" "$HCI_COUNT"
}

detect_bt_chipset() {
    BT_CHIPSET="unknown"

    if [ -d /sys/class/bluetooth/hci0/device ]; then
        local modalias_path="/sys/class/bluetooth/hci0/device/modalias"
        if [ -f "$modalias_path" ]; then
            local modalias
            modalias=$(cat "$modalias_path" 2>/dev/null)
            case "$modalias" in
                *broadcom*|*BCM*) BT_CHIPSET="broadcom" ;;
                *qcom*|*qca*)     BT_CHIPSET="qualcomm" ;;
                *intel*)          BT_CHIPSET="intel" ;;
                *realtek*|*rtl*)  BT_CHIPSET="realtek" ;;
                *mediatek*|*mtk*) BT_CHIPSET="mediatek" ;;
            esac
        fi
    fi

    if [ "$BT_CHIPSET" = "unknown" ] && [ -d /vendor/firmware ]; then
        if ls /vendor/firmware/BCM*.hcd >/dev/null 2>&1; then
            BT_CHIPSET="broadcom"
        elif ls /vendor/firmware/crnv*.bin >/dev/null 2>&1 || \
             ls /vendor/firmware/crbtfw*.tlv >/dev/null 2>&1; then
            BT_CHIPSET="qualcomm"
        elif ls /vendor/firmware/rtl_bt/* >/dev/null 2>&1; then
            BT_CHIPSET="realtek"
        elif ls /vendor/firmware/mt*.bin >/dev/null 2>&1; then
            BT_CHIPSET="mediatek"
        fi
    fi

    hal_info "Bluetooth chipset: $BT_CHIPSET"
    hal_set_state "chipset" "$BT_CHIPSET"
}

load_vendor_firmware() {
    local fw_paths="/vendor/firmware /vendor/etc/firmware /lib/firmware"
    for fw_dir in $fw_paths; do
        [ -d "$fw_dir" ] || continue

        if [ -d "$fw_dir/brcm" ] || ls "$fw_dir"/BCM*.hcd >/dev/null 2>&1; then
            ln -sf "$fw_dir" /lib/firmware/brcm 2>/dev/null || true
            hal_info "Symlinked Broadcom BT firmware"
        fi
        if [ -d "$fw_dir/qca" ]; then
            ln -sf "$fw_dir/qca" /lib/firmware/qca 2>/dev/null || true
            hal_info "Symlinked Qualcomm BT firmware"
        fi
        if [ -d "$fw_dir/rtl_bt" ]; then
            ln -sf "$fw_dir/rtl_bt" /lib/firmware/rtl_bt 2>/dev/null || true
            hal_info "Symlinked Realtek BT firmware"
        fi
    done
}

bring_up_hci() {
    local hci_up=0
    for hci in $HCI_DEVICES; do
        if command -v hciconfig >/dev/null 2>&1; then
            hciconfig "$hci" up 2>/dev/null && hci_up=$((hci_up + 1))
        elif command -v btmgmt >/dev/null 2>&1; then
            btmgmt --index "${hci#hci}" power on 2>/dev/null && hci_up=$((hci_up + 1))
        fi
    done
    hal_set_state "hci_up_count" "$hci_up"
    hal_info "Brought up $hci_up HCI interface(s)"
}

start_bluez() {
    if ! command -v bluetoothd >/dev/null 2>&1; then
        hal_warn "bluetoothd not installed"
        return 1
    fi

    if systemctl list-unit-files bluetooth.service >/dev/null 2>&1; then
        systemctl enable bluetooth.service 2>/dev/null || true
        systemctl start bluetooth.service 2>/dev/null || true
        hal_info "BlueZ bluetooth.service started"
    else
        bluetoothd --experimental 2>/dev/null &
        hal_info "bluetoothd started directly (PID $!)"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Native handler — vendor BT HIDL HAL available
# ---------------------------------------------------------------------------
bluetooth_native() {
    hal_info "Bluetooth HIDL HAL detected — initializing BlueZ stack"

    detect_bt_chipset
    load_vendor_firmware

    local retries=0
    local max_retries=10
    detect_hci_devices

    while [ "$HCI_COUNT" -eq 0 ] && [ "$retries" -lt "$max_retries" ]; do
        retries=$((retries + 1))
        hal_info "Waiting for HCI device (attempt $retries/$max_retries)"
        sleep 2
        detect_hci_devices
    done

    if [ "$HCI_COUNT" -eq 0 ]; then
        hal_warn "No HCI device became available — entering passive monitor"
        hal_set_state "status" "no_hci"
    else
        bring_up_hci
        start_bluez
        hal_set_state "status" "active"
    fi

    while true; do
        sleep 60
    done
}

# ---------------------------------------------------------------------------
# Mock handler — no vendor BT HAL but USB BT might exist
# ---------------------------------------------------------------------------
bluetooth_mock() {
    hal_info "Bluetooth HAL mock: probing for any HCI device"
    detect_hci_devices

    if [ "$HCI_COUNT" -gt 0 ]; then
        bring_up_hci
        start_bluez
        hal_set_state "status" "standalone"
    else
        hal_info "No Bluetooth controllers — operating in mock mode"
        hal_set_state "status" "mock"
    fi

    while true; do
        sleep 60
    done
}

hidl_hal_run bluetooth_native bluetooth_mock
