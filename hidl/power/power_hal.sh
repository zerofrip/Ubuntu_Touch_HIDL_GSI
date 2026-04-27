#!/bin/bash
# =============================================================================
# hidl/power/power_hal.sh — Power HIDL HAL Wrapper
# =============================================================================
# Bridges Ubuntu power management (upower) to Android vendor power HAL via
# HIDL hwbinder interface android.hardware.power@1.3::IPower.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/hidl_hal_base.sh"

hidl_hal_init "power" "android.hardware.power@1.3::IPower" "critical"

# ---------------------------------------------------------------------------
# Native handler — vendor power HIDL HAL available
# ---------------------------------------------------------------------------
power_native() {
    hal_info "Mapping upower → vendor power HIDL HAL via hwbinder"

    if [ -x /usr/libexec/upowerd ]; then
        /usr/libexec/upowerd &
        hal_info "upowerd started (PID $!)"
    else
        hal_warn "upowerd not found — battery info unavailable"
    fi

    while true; do
        for bat_path in /sys/class/power_supply/battery /sys/class/power_supply/Battery; do
            if [ -d "$bat_path" ]; then
                CAPACITY=$(cat "$bat_path/capacity" 2>/dev/null || echo "?")
                STATUS=$(cat "$bat_path/status" 2>/dev/null || echo "Unknown")
                hal_info "Battery: ${CAPACITY}% ($STATUS)"
                hal_set_state "battery_capacity" "$CAPACITY"
                hal_set_state "battery_status" "$STATUS"
                break
            fi
        done
        sleep 30
    done
}

# ---------------------------------------------------------------------------
# Mock handler — no vendor power HAL
# ---------------------------------------------------------------------------
power_mock() {
    hal_info "Power HAL mock: reporting AC power, no battery"
    hal_set_state "battery_capacity" "100"
    hal_set_state "battery_status" "Full"

    if [ -x /usr/libexec/upowerd ]; then
        /usr/libexec/upowerd &
    fi

    while true; do
        sleep 60
    done
}

hidl_hal_run power_native power_mock
