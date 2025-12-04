#!/bin/bash
# =============================================================================
# swap_google_plist.sh
# =============================================================================
# This script is called by Xcode as a pre-build script.
# It swaps the dummy GoogleService-Info.plist with the real one from secrets/
# if it exists locally. CI environments use their own mechanisms (GSI_BASE64).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DUMMY_PLIST="${PROJECT_ROOT}/apps/ios/PayBack/GoogleService-Info.plist"
REAL_PLIST="${PROJECT_ROOT}/secrets/GoogleService-Info.real.plist"
DERIVED_PLIST_DIR="${DERIVED_FILE_DIR:-${PROJECT_ROOT}/DerivedData}"
DERIVED_PLIST="${DERIVED_PLIST_DIR}/GoogleService-Info.plist"

echo "[swap_google_plist.sh] Checking for real Firebase credentials..."

# Check if we're in a CI environment
if [ -n "$CI" ] || [ -n "$CI_XCODE_PROJECT" ] || [ -n "$GITHUB_ACTIONS" ]; then
    echo "[swap_google_plist.sh] CI environment detected, skipping swap (CI handles its own credentials)."
    exit 0
fi

# Ensure derived directory exists so we never touch tracked files
mkdir -p "$DERIVED_PLIST_DIR"

# Check if the real plist exists
if [ -f "$REAL_PLIST" ]; then
    echo "[swap_google_plist.sh] Found real plist at: $REAL_PLIST"
    echo "[swap_google_plist.sh] Copying to derived data: $DERIVED_PLIST"
    cp "$REAL_PLIST" "$DERIVED_PLIST"
    echo "[swap_google_plist.sh] ✅ Prepared real Firebase credentials in derived data"
else
    echo "[swap_google_plist.sh] ⚠️  No real plist found at: $REAL_PLIST"
    echo "[swap_google_plist.sh] Using dummy placeholder (Firebase features may not work)."
    cp "$DUMMY_PLIST" "$DERIVED_PLIST"
fi

# If build outputs are available, overlay into the app bundle without touching source control
if [ -n "${BUILT_PRODUCTS_DIR:-}" ] && [ -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
    BUNDLE_PLIST="${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/GoogleService-Info.plist"
    mkdir -p "$(dirname "$BUNDLE_PLIST")"
    cp "$DERIVED_PLIST" "$BUNDLE_PLIST"
    echo "[swap_google_plist.sh] 📦 Copied GoogleService-Info.plist into bundle: $BUNDLE_PLIST"
else
    echo "[swap_google_plist.sh] ℹ️  Build products not available yet; plist prepared at $DERIVED_PLIST"
fi

exit 0
