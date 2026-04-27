#!/bin/bash
# =============================================================================
# hidl/vibrator/vibrator_hal.sh — Vibrator HIDL HAL Wrapper
# =============================================================================
# Bridges sysfs vibrator interfaces (timed_output / LED-style / FF-input) to
# Android vendor Vibrator HAL via HIDL hwbinder
# (android.hardware.vibrator@1.3::IVibrator).
#
# Sysfs candidates probed (in priority order):
#   /sys/class/timed_output/vibrator/enable      (legacy timed_output)
#   /sys/class/leds/vibrator/duration            (LED-style)
#   /sys/class/leds/vibrator/activate            (LED-style modern)
#   /dev/input/event* with FF capability         (force-feedback)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/hidl_hal_base.sh"

hidl_hal_init "vibrator" "android.hardware.vibrator@1.3::IVibrator" "optional"

VIBRATOR_TYPE="none"
VIBRATOR_PATH=""

# ---------------------------------------------------------------------------
# Vibrator backend detection
# ---------------------------------------------------------------------------
detect_vibrator_backend() {
    if [ -f /sys/class/timed_output/vibrator/enable ]; then
        VIBRATOR_TYPE="timed_output"
        VIBRATOR_PATH="/sys/class/timed_output/vibrator"
        hal_info "Vibrator backend: timed_output (legacy)"
        return 0
    fi

    if [ -f /sys/class/leds/vibrator/duration ] && \
       [ -f /sys/class/leds/vibrator/activate ]; then
        VIBRATOR_TYPE="led_modern"
        VIBRATOR_PATH="/sys/class/leds/vibrator"
        hal_info "Vibrator backend: led_modern"
        return 0
    fi

    if [ -d /sys/class/leds/vibrator ]; then
        VIBRATOR_TYPE="led_legacy"
        VIBRATOR_PATH="/sys/class/leds/vibrator"
        hal_info "Vibrator backend: led_legacy"
        return 0
    fi

    for event_dev in /dev/input/event*; do
        [ -c "$event_dev" ] || continue
        local cap_path
        cap_path="/sys/class/input/$(basename "$event_dev")/device/capabilities/ff"
        if [ -f "$cap_path" ]; then
            local ff_caps
            ff_caps=$(cat "$cap_path" 2>/dev/null)
            if [ -n "$ff_caps" ] && [ "$ff_caps" != "0" ]; then
                VIBRATOR_TYPE="ff_input"
                VIBRATOR_PATH="$event_dev"
                hal_info "Vibrator backend: ff_input ($event_dev)"
                return 0
            fi
        fi
    done

    VIBRATOR_TYPE="none"
    hal_warn "No vibrator backend found"
    return 1
}

set_vibrator_permissions() {
    case "$VIBRATOR_TYPE" in
        timed_output)
            chmod 0664 "$VIBRATOR_PATH/enable" 2>/dev/null || true
            chgrp input "$VIBRATOR_PATH/enable" 2>/dev/null || true
            ;;
        led_modern)
            chmod 0664 "$VIBRATOR_PATH/duration" 2>/dev/null || true
            chmod 0664 "$VIBRATOR_PATH/activate" 2>/dev/null || true
            chgrp input "$VIBRATOR_PATH/duration" 2>/dev/null || true
            chgrp input "$VIBRATOR_PATH/activate" 2>/dev/null || true
            ;;
        led_legacy)
            for f in "$VIBRATOR_PATH"/*; do
                [ -f "$f" ] && chmod 0664 "$f" 2>/dev/null || true
                [ -f "$f" ] && chgrp input "$f" 2>/dev/null || true
            done
            ;;
        ff_input)
            chmod 0660 "$VIBRATOR_PATH" 2>/dev/null || true
            chgrp input "$VIBRATOR_PATH" 2>/dev/null || true
            ;;
    esac
}

create_userspace_helpers() {
    mkdir -p /run/ubuntu-gsi
    cat > /run/ubuntu-gsi/vibrator.conf << CONFEOF
type=$VIBRATOR_TYPE
path=$VIBRATOR_PATH
CONFEOF

    cat > /usr/local/bin/gsi-vibrate << 'SCRIPTEOF'
#!/bin/bash
# Helper to trigger vibrator using the configured backend
DURATION="${1:-100}"
[ -f /run/ubuntu-gsi/vibrator.conf ] || exit 1
. /run/ubuntu-gsi/vibrator.conf

case "$type" in
    timed_output)
        echo "$DURATION" > "$path/enable" ;;
    led_modern)
        echo "$DURATION" > "$path/duration"
        echo 1 > "$path/activate" ;;
    led_legacy)
        echo 255 > "$path/brightness"
        sleep "$(awk -v d="$DURATION" 'BEGIN{print d/1000}')"
        echo 0 > "$path/brightness" ;;
    *) exit 1 ;;
esac
SCRIPTEOF
    chmod 0755 /usr/local/bin/gsi-vibrate

    hal_info "Userspace vibrator helper installed"
}

# ---------------------------------------------------------------------------
# Native handler — vendor vibrator HIDL HAL available
# ---------------------------------------------------------------------------
vibrator_native() {
    hal_info "Vibrator HIDL HAL detected"

    if detect_vibrator_backend; then
        set_vibrator_permissions
        create_userspace_helpers
        hal_set_state "type" "$VIBRATOR_TYPE"
        hal_set_state "path" "$VIBRATOR_PATH"
        hal_set_state "status" "active"
    else
        hal_set_state "status" "no_backend"
    fi

    while true; do
        sleep 60
    done
}

vibrator_mock() {
    hal_info "Vibrator HAL mock: scanning local backends"

    if detect_vibrator_backend; then
        set_vibrator_permissions
        create_userspace_helpers
        hal_set_state "type" "$VIBRATOR_TYPE"
        hal_set_state "path" "$VIBRATOR_PATH"
        hal_set_state "status" "standalone"
    else
        hal_set_state "type" "none"
        hal_set_state "status" "mock"
    fi

    while true; do
        sleep 60
    done
}

hidl_hal_run vibrator_native vibrator_mock
