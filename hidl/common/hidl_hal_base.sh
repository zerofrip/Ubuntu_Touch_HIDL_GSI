#!/bin/bash
# =============================================================================
# hidl/common/hidl_hal_base.sh — HIDL HAL Service Base Library
# =============================================================================
# Shared functions for all HIDL HAL service wrappers. Provides hwbinder
# service registration, passthrough probing, health monitoring, mock
# fallback, and logging.
#
# Each HAL wrapper sources this file and calls:
#   hidl_hal_init  SERVICE_NAME  HIDL_INTERFACE@VERSION::IName  [CRITICAL]
#   hidl_hal_run   NATIVE_HANDLER  [MOCK_HANDLER]
#
# HIDL specifics (vs. AIDL):
#   * Uses /dev/hwbinder (HWBinder) instead of /dev/binder
#   * Service discovery via:
#       1. `lshal` (Android tool, when present)
#       2. VINTF manifest XML <hal format="hidl"> entries with <name> and <version>
#       3. Passthrough probe: /vendor/lib(64)/hw/<package>@<version>-impl.so
#   * Interface format: <package>@<major.minor>::<IName>
#       e.g. android.hardware.power@1.3::IPower
# =============================================================================

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
HIDL_LOG_DIR="/data/uhl_overlay"
HIDL_STATE_DIR="/run/ubuntu-gsi/hal"
HWBINDER_DEV="/dev/hwbinder"
VINTF_MANIFEST="/vendor/etc/vintf/manifest.xml"
VINTF_FRAGMENTS_DIRS="/vendor/etc/vintf/manifest /odm/etc/vintf/manifest /odm/etc/vintf"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_hal_log() {
    local level="$1"
    local msg="$2"
    echo "[$(date -Iseconds)] [HIDL:${HAL_SERVICE_NAME:-unknown}] [$level] $msg" >> "${HIDL_LOG_DIR}/hal.log"
}

hal_info()  { _hal_log "INFO"  "$1"; }
hal_warn()  { _hal_log "WARN"  "$1"; }
hal_error() { _hal_log "ERROR" "$1"; }

# ---------------------------------------------------------------------------
# HIDL Interface Parsing
# ---------------------------------------------------------------------------
# Splits an interface string like "android.hardware.power@1.3::IPower"
# into HAL_HIDL_PACKAGE, HAL_HIDL_VERSION, HAL_HIDL_NAME

hidl_parse_interface() {
    local iface="$1"
    HAL_HIDL_PACKAGE="${iface%@*}"
    local rest="${iface#*@}"
    HAL_HIDL_VERSION="${rest%%::*}"
    HAL_HIDL_NAME="${rest##*::}"
}

# ---------------------------------------------------------------------------
# HIDL Service Discovery
# ---------------------------------------------------------------------------

# Check if a HIDL interface is declared in any vendor VINTF manifest.
# Accepts either a fully-qualified interface (package@ver::IName) or a package.
hidl_interface_available() {
    local interface="$1"
    local package="${interface%@*}"
    local version="${interface#*@}"
    version="${version%%::*}"
    local iname=""
    case "$interface" in
        *::*) iname="${interface##*::}" ;;
    esac

    # Walk the primary manifest plus all known fragment locations.
    local files="$VINTF_MANIFEST"
    for d in $VINTF_FRAGMENTS_DIRS; do
        [ -d "$d" ] || continue
        for f in "$d"/*.xml; do
            [ -f "$f" ] && files="$files $f"
        done
    done

    for f in $files; do
        [ -f "$f" ] || continue
        # The manifest entry must mark format="hidl" (not aidl) and contain the
        # package name. Version match is best-effort — we accept exact or any
        # version of the same major.
        if grep -q 'format="hidl"' "$f" 2>/dev/null && grep -q "$package" "$f" 2>/dev/null; then
            if [ -n "$iname" ] && ! grep -q "$iname" "$f" 2>/dev/null; then
                continue
            fi
            if [ -n "$version" ] && ! grep -q "$version" "$f" 2>/dev/null; then
                # Try just the major version
                local major="${version%%.*}"
                grep -q ">$major\." "$f" 2>/dev/null || continue
            fi
            return 0
        fi
    done
    return 1
}

# Probe for a passthrough HAL implementation (.so) — common on devices that
# never spawned a binderized server but still ship the vendor shared object.
hidl_passthrough_available() {
    local package="$1"
    local version="$2"
    # Sanitize package for the canonical filename:
    #   android.hardware.power@1.3-impl.so
    local soname="${package}@${version}-impl.so"
    for libdir in /vendor/lib64/hw /vendor/lib/hw /odm/lib64/hw /odm/lib/hw; do
        if [ -f "$libdir/$soname" ]; then
            hal_info "Passthrough impl found: $libdir/$soname"
            return 0
        fi
    done
    return 1
}

# Query lshal for a registered HIDL service (binderized or passthrough).
hwbinder_service_registered() {
    local interface="$1"
    if command -v lshal >/dev/null 2>&1; then
        # `lshal -ip` lists registered (P)assthrough/(I)nterface entries.
        lshal -ip 2>/dev/null | grep -q "$interface"
        return $?
    fi
    # Fallback to hwservicemanager debug stats.
    if [ -f "/sys/kernel/debug/binder/proc/stats" ]; then
        grep -q "$interface" /sys/kernel/debug/binder/proc/stats 2>/dev/null
        return $?
    fi
    if [ -f "/d/binder/proc/stats" ]; then
        grep -q "$interface" /d/binder/proc/stats 2>/dev/null
        return $?
    fi
    return 1
}

# Wait for a hwbinder service with retry.
wait_for_hwbinder_service() {
    local service="$1"
    local max_retries="${2:-10}"
    local delay="${3:-1}"
    local attempt=0

    while [ "$attempt" -lt "$max_retries" ]; do
        if hwbinder_service_registered "$service"; then
            hal_info "HwBinder service '$service' available (attempt $((attempt+1)))"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep "$delay"
    done

    hal_warn "HwBinder service '$service' not available after $max_retries attempts"
    return 1
}

# ---------------------------------------------------------------------------
# HAL State Management
# ---------------------------------------------------------------------------

hal_set_state() {
    local key="$1"
    local value="$2"
    mkdir -p "$HIDL_STATE_DIR"
    echo "$value" > "$HIDL_STATE_DIR/${HAL_SERVICE_NAME}.${key}"
}

hal_get_state() {
    local key="$1"
    local state_file="$HIDL_STATE_DIR/${HAL_SERVICE_NAME}.${key}"
    if [ -f "$state_file" ]; then
        cat "$state_file"
    else
        echo ""
    fi
}

# ---------------------------------------------------------------------------
# HAL Initialization
# ---------------------------------------------------------------------------

# Initialize a HIDL HAL wrapper.
# Usage: hidl_hal_init SERVICE_NAME HIDL_INTERFACE [critical|optional]
#        e.g. hidl_hal_init power "android.hardware.power@1.3::IPower" critical
hidl_hal_init() {
    HAL_SERVICE_NAME="$1"
    HAL_HIDL_INTERFACE="$2"
    HAL_CRITICALITY="${3:-optional}"

    mkdir -p "$HIDL_LOG_DIR" "$HIDL_STATE_DIR"

    hidl_parse_interface "$HAL_HIDL_INTERFACE"
    hal_info "Initializing HIDL HAL wrapper for $HAL_HIDL_INTERFACE"
    hal_info "  package=$HAL_HIDL_PACKAGE version=$HAL_HIDL_VERSION name=$HAL_HIDL_NAME"

    # Verify hwbinder device availability (HIDL specific).
    if [ ! -c "$HWBINDER_DEV" ]; then
        hal_error "$HWBINDER_DEV not available"
        if [ "$HAL_CRITICALITY" = "critical" ]; then
            exit 1
        fi
        return 1
    fi

    # 1) Prefer binderized HAL (declared in VINTF & registered with hwservicemanager).
    if hidl_interface_available "$HAL_HIDL_INTERFACE"; then
        hal_info "HIDL interface '$HAL_HIDL_INTERFACE' declared in vendor VINTF"
        hal_set_state "mode" "native"
        hal_set_state "transport" "binderized"
        HAL_MODE="native"
        return 0
    fi

    # 2) Fall back to passthrough impl (vendor .so).
    if hidl_passthrough_available "$HAL_HIDL_PACKAGE" "$HAL_HIDL_VERSION"; then
        hal_info "HIDL passthrough impl available for '$HAL_HIDL_INTERFACE'"
        hal_set_state "mode" "native"
        hal_set_state "transport" "passthrough"
        HAL_MODE="native"
        return 0
    fi

    hal_warn "HIDL interface '$HAL_HIDL_INTERFACE' NOT in VINTF and no passthrough impl"
    hal_set_state "mode" "mock"
    hal_set_state "transport" "none"
    HAL_MODE="mock"

    hal_set_state "status" "initializing"
    hal_set_state "pid" "$$"
    return 0
}

# ---------------------------------------------------------------------------
# Mock Fallback
# ---------------------------------------------------------------------------

# Run mock mode for a HAL service (provides stub responses).
hal_run_mock() {
    local mock_handler="${1:-hal_default_mock}"

    hal_info "Running in MOCK mode (vendor HIDL HAL not available)"
    hal_set_state "status" "mock"

    if type "$mock_handler" >/dev/null 2>&1; then
        "$mock_handler"
    else
        hal_info "No mock handler defined, entering idle"
        while true; do
            sleep 60
            hal_info "Mock heartbeat (PID $$)"
        done
    fi
}

# ---------------------------------------------------------------------------
# HAL Run Loop
# ---------------------------------------------------------------------------

# Main entry point — checks mode and dispatches to native or mock handler.
# Usage: hidl_hal_run NATIVE_HANDLER [MOCK_HANDLER]
hidl_hal_run() {
    local native_handler="$1"
    local mock_handler="${2:-hal_default_mock}"

    hal_set_state "status" "running"
    hal_info "HAL service started (mode=$HAL_MODE, PID=$$)"

    if [ "$HAL_MODE" = "native" ]; then
        if type "$native_handler" >/dev/null 2>&1; then
            "$native_handler"
        else
            hal_error "Native handler '$native_handler' not defined"
            exit 1
        fi
    else
        hal_run_mock "$mock_handler"
    fi
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

hal_cleanup() {
    hal_info "Shutting down (PID $$)"
    hal_set_state "status" "stopped"
}

trap hal_cleanup EXIT INT TERM
