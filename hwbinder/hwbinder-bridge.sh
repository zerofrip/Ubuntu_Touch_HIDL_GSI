#!/bin/bash
# =============================================================================
# hwbinder/hwbinder-bridge.sh — Ubuntu ↔ Android HwBinder Bridge Daemon
# =============================================================================
# Manages the connection between Ubuntu userspace services and Android
# vendor HAL services exposed via /dev/hwbinder (HIDL).
#
# Responsibilities:
#   1. Verify hwbinder + (vnd|legacy) binder devices are present
#   2. Probe vendor manifest VINTF declarations for HIDL HALs
#   3. Start HIDL HAL wrappers from hidl/manifest.json
#   4. Monitor HAL health and restart critical ones on failure
#   5. Provide service status via state files in /run/ubuntu-gsi/hal
#
# Notes on HIDL vs. AIDL bridge:
#   * HIDL uses /dev/hwbinder (HwBinder) for vendor↔framework IPC.
#   * Service discovery is performed by `lshal -ip` and the vendor VINTF
#     fragment XML files when running. Passthrough HALs (.so impls in
#     /vendor/lib*/hw/) are also probed by individual HAL wrappers.
#   * `hwservicemanager` from /vendor must be running for binderized HIDL.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- HwBinder devices ---------------------------------------------------------
HWBINDER_DEV="/dev/hwbinder"
BINDER_DEV="/dev/binder"
VNDBINDER_DEV="/dev/vndbinder"

# --- Manifest / state ---------------------------------------------------------
MANIFEST="${HIDL_MANIFEST:-$REPO_ROOT/hidl/manifest.json}"
[ -f "$MANIFEST" ] || MANIFEST="/system/hidl/manifest.json"
LOG_FILE="/data/uhl_overlay/hwbinder-bridge.log"
STATE_DIR="/run/ubuntu-gsi/hal"
PID_DIR="/run/ubuntu-gsi/pids"

# --- VINTF locations (probed for binderized HIDL declarations) ----------------
VINTF_FRAGMENTS_DIRS="
/vendor/etc/vintf/manifest
/odm/etc/vintf/manifest
/vendor/manifest.xml.d
/odm/manifest.xml.d
"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()        { echo "[$(date -Iseconds)] [hwbinder-bridge] $1" >> "$LOG_FILE"; }
log_stdout() { echo "[hwbinder-bridge] $1"; log "$1"; }

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------
init() {
    mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR" "$PID_DIR"

    log_stdout "Starting HwBinder bridge daemon (PID $$)"

    # /dev/hwbinder is mandatory for HIDL.
    if [ ! -c "$HWBINDER_DEV" ]; then
        log_stdout "FATAL: $HWBINDER_DEV not available"
        log_stdout "  Ensure BinderFS is mounted and /dev/hwbinder symlinked"
        log_stdout "  (see builder/init/init for the symlink chain)"
        exit 1
    fi
    log_stdout "HwBinder device: $HWBINDER_DEV ✓"

    if [ -c "$BINDER_DEV" ]; then
        log_stdout "Framework binder: $BINDER_DEV ✓ (used by InputFlinger / RPC)"
    fi
    if [ -c "$VNDBINDER_DEV" ]; then
        log_stdout "Vendor binder: $VNDBINDER_DEV ✓"
    fi

    if [ ! -f "$MANIFEST" ]; then
        log_stdout "FATAL: HIDL manifest not found: $MANIFEST"
        exit 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        log_stdout "FATAL: jq not found (required to parse manifest)"
        exit 1
    fi

    probe_vintf_summary
}

# ---------------------------------------------------------------------------
# VINTF probe — informational only
# ---------------------------------------------------------------------------
probe_vintf_summary() {
    local found=0
    for d in $VINTF_FRAGMENTS_DIRS; do
        [ -d "$d" ] || continue
        for f in "$d"/*.xml; do
            [ -f "$f" ] || continue
            if grep -q 'format="hidl"' "$f" 2>/dev/null; then
                found=$((found + 1))
            fi
        done
    done

    if [ -f /vendor/etc/vintf/manifest.xml ] && \
       grep -q 'format="hidl"' /vendor/etc/vintf/manifest.xml 2>/dev/null; then
        found=$((found + 1))
    fi

    if [ "$found" -gt 0 ]; then
        log_stdout "VINTF: $found HIDL fragment(s) detected in vendor manifest"
    else
        log_stdout "VINTF: no HIDL fragments — HALs will run passthrough or mock"
    fi

    # Surface lshal output if the tool is available (Android tool, may
    # or may not be present in the rootfs).
    if command -v lshal >/dev/null 2>&1; then
        local count
        count=$(lshal -ip 2>/dev/null | wc -l)
        log_stdout "lshal: $count registered HIDL service line(s)"
    else
        log "INFO: lshal not present; relying on VINTF + passthrough only"
    fi
}

# ---------------------------------------------------------------------------
# HAL Module Management
# ---------------------------------------------------------------------------
start_hal_module() {
    local name="$1"
    local binary="$2"
    local critical="$3"
    local delay="$4"

    if [ "$delay" -gt 0 ]; then
        log "Delaying $name start by ${delay}s"
        sleep "$delay"
    fi

    if [ ! -f "$binary" ]; then
        if [ "$critical" = "true" ]; then
            log_stdout "FATAL: Critical HAL binary missing: $binary"
            return 1
        fi
        log "WARN: HAL binary missing: $binary (non-critical, skipping)"
        return 0
    fi

    chmod +x "$binary"
    bash "$binary" &
    local pid=$!
    echo "$pid" > "$PID_DIR/$name.pid"
    log_stdout "Started HIDL HAL: $name (PID $pid)"

    return 0
}

start_all_modules() {
    local module_count
    module_count=$(jq '.hal_modules | length' "$MANIFEST")

    log_stdout "Loading $module_count HIDL HAL modules"

    # Critical modules first.
    for i in $(seq 0 $((module_count - 1))); do
        local critical
        critical=$(jq -r ".hal_modules[$i].critical" "$MANIFEST")
        if [ "$critical" = "true" ]; then
            local name binary delay
            name=$(jq -r   ".hal_modules[$i].name"        "$MANIFEST")
            binary=$(jq -r ".hal_modules[$i].binary"      "$MANIFEST")
            delay=$(jq -r  ".hal_modules[$i].start_delay" "$MANIFEST")
            start_hal_module "$name" "$binary" "$critical" "$delay" || {
                log_stdout "FATAL: Critical module '$name' failed to start"
                exit 1
            }
        fi
    done

    # Optional modules.
    for i in $(seq 0 $((module_count - 1))); do
        local critical
        critical=$(jq -r ".hal_modules[$i].critical" "$MANIFEST")
        if [ "$critical" != "true" ]; then
            local name binary delay
            name=$(jq -r   ".hal_modules[$i].name"        "$MANIFEST")
            binary=$(jq -r ".hal_modules[$i].binary"      "$MANIFEST")
            delay=$(jq -r  ".hal_modules[$i].start_delay" "$MANIFEST")
            start_hal_module "$name" "$binary" "$critical" "$delay" || true
        fi
    done
}

# ---------------------------------------------------------------------------
# Health Monitor
# ---------------------------------------------------------------------------
monitor_health() {
    local check_interval=30

    while true; do
        sleep "$check_interval"

        for pidfile in "$PID_DIR"/*.pid; do
            [ -f "$pidfile" ] || continue
            local name pid
            name=$(basename "$pidfile" .pid)
            pid=$(cat "$pidfile")

            if ! kill -0 "$pid" 2>/dev/null; then
                log "WARN: HAL '$name' (PID $pid) died"

                local critical binary
                critical=$(jq -r ".hal_modules[] | select(.name==\"$name\") | .critical" "$MANIFEST")
                binary=$(jq -r   ".hal_modules[] | select(.name==\"$name\") | .binary"   "$MANIFEST")

                if [ "$critical" = "true" ]; then
                    log_stdout "Restarting critical HAL: $name"
                    start_hal_module "$name" "$binary" "true" "0"
                else
                    log "Non-critical HAL '$name' died — not restarting"
                    rm -f "$pidfile"
                fi
            fi
        done
    done
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    log_stdout "Shutting down HwBinder bridge"
    for pidfile in "$PID_DIR"/*.pid; do
        [ -f "$pidfile" ] || continue
        local pid name
        pid=$(cat "$pidfile")
        name=$(basename "$pidfile" .pid)
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            log "Stopped HAL: $name (PID $pid)"
        fi
        rm -f "$pidfile"
    done
    log_stdout "HwBinder bridge stopped"
}

trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
init
start_all_modules
log_stdout "All HIDL HAL modules started — entering health monitor"
monitor_health
