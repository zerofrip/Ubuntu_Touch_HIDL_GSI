#!/bin/bash
# =============================================================================
# hidl/face/face_hal.sh — Face Authentication HIDL HAL Wrapper
# =============================================================================
# Bridges Howdy / IR-camera authentication to Android vendor Face HAL via
# HIDL (android.hardware.biometrics.face@1.0::IBiometricsFace).
#
# Detection flow:
#   1. Probe for IR / depth cameras via V4L2 (Linux YU12 IR sensors)
#   2. Probe for ToF / structured-light sensors
#   3. Configure Howdy (PAM-based face auth) if available
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/hidl_hal_base.sh"

hidl_hal_init "face" "android.hardware.biometrics.face@1.0::IBiometricsFace" "optional"

IR_CAMS=""
IR_COUNT=0
DEPTH_DEVS=""
DEPTH_COUNT=0

# ---------------------------------------------------------------------------
# IR / depth sensor discovery
# ---------------------------------------------------------------------------
detect_ir_cameras() {
    IR_CAMS=""
    IR_COUNT=0

    for vdev in /dev/video*; do
        [ -c "$vdev" ] || continue

        local vname=""
        local sysfs_dir
        sysfs_dir="/sys/class/video4linux/$(basename "$vdev")"
        if [ -f "$sysfs_dir/name" ]; then
            vname=$(cat "$sysfs_dir/name" 2>/dev/null)
        fi

        case "$vname" in
            *[Ii][Rr]*|*[Ii]nfrared*|*[Dd]epth*|*[Tt]o[Ff]*|*Realsense*|*RealSense*)
                IR_CAMS="${IR_CAMS} ${vdev}"
                IR_COUNT=$((IR_COUNT + 1))
                hal_info "IR/depth camera: $vdev ($vname)"
                ;;
        esac

        if [ -z "$vname" ] && command -v v4l2-ctl >/dev/null 2>&1; then
            if v4l2-ctl --device="$vdev" --list-formats 2>/dev/null | grep -qi "Y8\b\|GREY\b\|Y16\b"; then
                IR_CAMS="${IR_CAMS} ${vdev}"
                IR_COUNT=$((IR_COUNT + 1))
                hal_info "Probable IR camera (Y8/GREY): $vdev"
            fi
        fi
    done

    hal_set_state "ir_count" "$IR_COUNT"
}

detect_depth_sensors() {
    DEPTH_DEVS=""
    DEPTH_COUNT=0

    for dev in /dev/intel-realsense /dev/iep_iep /dev/sec_face; do
        if [ -e "$dev" ]; then
            DEPTH_DEVS="${DEPTH_DEVS} ${dev}"
            DEPTH_COUNT=$((DEPTH_COUNT + 1))
            hal_info "Depth sensor: $dev"
        fi
    done

    hal_set_state "depth_count" "$DEPTH_COUNT"
}

set_face_permissions() {
    for dev in $IR_CAMS $DEPTH_DEVS; do
        chmod 0660 "$dev" 2>/dev/null || true
        chgrp video "$dev" 2>/dev/null || true
    done
}

configure_howdy() {
    if ! command -v howdy >/dev/null 2>&1; then
        hal_info "Howdy not installed — face auth limited to vendor HAL"
        return 1
    fi

    local first_ir
    first_ir=$(echo "$IR_CAMS" | awk '{print $1}')
    if [ -n "$first_ir" ]; then
        if [ -f /etc/howdy/config.ini ]; then
            sed -i "s|^device_path *=.*|device_path = $first_ir|" /etc/howdy/config.ini 2>/dev/null || true
        fi
        hal_info "Howdy configured to use $first_ir"
    fi

    if [ -f /etc/pam.d/common-auth ] && ! grep -q "pam_howdy" /etc/pam.d/common-auth; then
        sed -i '1i auth sufficient pam_howdy.so' /etc/pam.d/common-auth 2>/dev/null || true
        hal_info "Howdy PAM module enabled"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Native handler — vendor face HIDL HAL available
# ---------------------------------------------------------------------------
face_native() {
    hal_info "Face HIDL HAL detected — initializing biometrics bridge"

    detect_ir_cameras
    detect_depth_sensors

    if [ "$IR_COUNT" -eq 0 ] && [ "$DEPTH_COUNT" -eq 0 ]; then
        hal_warn "No IR/depth sensors found — face HAL will rely on vendor RGB"
        hal_set_state "status" "vendor_only"
    else
        set_face_permissions
        configure_howdy
        hal_set_state "status" "active"
    fi

    while true; do
        sleep 60
    done
}

# ---------------------------------------------------------------------------
# Mock handler — no vendor HAL; try Howdy on RGB or IR
# ---------------------------------------------------------------------------
face_mock() {
    hal_info "Face HAL mock: probing for IR/depth/RGB cameras"

    detect_ir_cameras
    detect_depth_sensors

    if [ "$IR_COUNT" -gt 0 ] || [ "$DEPTH_COUNT" -gt 0 ]; then
        set_face_permissions
        configure_howdy
        hal_set_state "status" "howdy_only"
    else
        hal_info "No suitable cameras for face authentication"
        hal_set_state "status" "mock"
    fi

    while true; do
        sleep 60
    done
}

hidl_hal_run face_native face_mock
