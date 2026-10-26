#!/bin/bash
# =============================================================================
# scripts/build_android8_to16_hidl.sh — Android 8-16 HIDL build matrix runner
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DRY_RUN=0
ALLOW_SKIP=1
BUILD_TARGET="build-minimal"
DEVICE_PHH_REPO="${DEVICE_PHH_REPO:-https://github.com/TrebleDroid/device_phh_treble.git}"
DEVICE_PHH_DIR="${DEVICE_PHH_DIR:-$REPO_ROOT/builder/cache/device_phh_treble}"

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --strict) ALLOW_SKIP=0 ;;
        --build) BUILD_TARGET="build" ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: $0 [--dry-run] [--strict] [--build]" >&2
            exit 2
            ;;
    esac
done

declare -A PHH_VERSION_MAP=(
    [8]="v32"
    [9]="v123"
    [10]="v222"
    [11]="v313"
    [12.0]="v402"
    [12.1]="v416"
)

declare -A PHH_REPO_MAP=(
    [8]="phhusson/treble_experimentations"
    [9]="phhusson/treble_experimentations"
    [10]="phhusson/treble_experimentations"
    [11]="phhusson/treble_experimentations"
    [12.0]="phhusson/treble_experimentations"
    [12.1]="phhusson/treble_experimentations"
)

declare -A PHH_VARIANT_MAP=(
    [8]="arm64-ab-vanilla-nosu"
    [9]="arm64-ab-vanilla-nosu"
    [10]="quack-arm64-ab-vanilla"
    [11]="roar-arm64-ab-vanilla"
    [12.0]="squeak-arm64-ab-vanilla"
    [12.1]="squeak-arm64-ab-vanilla"
)

declare -A DEVICE_PHH_BRANCH_MAP=(
    [8]="android-8.1"
    [9]="android-9.0"
    [10]="android-10.0"
    [11]="android-11.0"
    [12.0]="android-12.0"
    [12.1]="android-12.1"
)

sync_device_phh_branch() {
    local branch="$1"
    local branch_ref="refs/remotes/origin/${branch}"

    if [ ! -d "$DEVICE_PHH_DIR/.git" ]; then
        echo "[HIDL matrix] Cloning device_phh_treble into $DEVICE_PHH_DIR"
        [ "$DRY_RUN" = "1" ] || git clone "$DEVICE_PHH_REPO" "$DEVICE_PHH_DIR"
    fi

    echo "[HIDL matrix] Syncing device_phh_treble branch: $branch"
    if [ "$DRY_RUN" = "1" ]; then
        return 0
    fi

    (
        cd "$DEVICE_PHH_DIR"
        git fetch origin --prune
        if git show-ref --quiet "$branch_ref"; then
            git checkout -B "$branch" "origin/$branch"
        else
            if [ "$ALLOW_SKIP" = "1" ]; then
                echo "[HIDL matrix] WARNING: missing branch origin/$branch, keeping current checkout."
            else
                echo "[HIDL matrix] ERROR: missing branch origin/$branch" >&2
                exit 1
            fi
        fi
    )
}

for version in 8 9 10 11 12.0 12.1; do
    phh_version="${PHH_VERSION_MAP[$version]}"
    phh_repo="${PHH_REPO_MAP[$version]}"
    phh_variant="${PHH_VARIANT_MAP[$version]}"
    device_phh_branch="${DEVICE_PHH_BRANCH_MAP[$version]}"

    sync_device_phh_branch "$device_phh_branch"

    # VENDOR_ANDROID_VERSION pins config.env's load_vendor_config.sh to the
    # matching vendor/*.env file so it doesn't conflict with the inline
    # PHH_GSI_* overrides below (both resolve to the same values).
    cmd="VENDOR_ANDROID_VERSION=$device_phh_branch PHH_GSI_SOURCE=release PHH_GSI_REPO=$phh_repo PHH_GSI_VERSION=$phh_version PHH_GSI_VARIANT=$phh_variant make $BUILD_TARGET"
    echo "[HIDL matrix] Android ${version} -> $cmd"
    if [ "$DRY_RUN" = "0" ]; then
        (cd "$REPO_ROOT" && eval "$cmd")
    fi
done

echo "[HIDL matrix] Done."
