#!/bin/bash
# =============================================================================
# swap_google_plist.sh
# =============================================================================
# This script is called by Xcode as a pre-build script.
# It swaps the dummy GoogleService-Info.plist with the real one from secrets/
# if it exists locally. CI environments use their own mechanisms (GSI_BASE64).
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DUMMY_PLIST="${PROJECT_ROOT}/apps/ios/PayBack/GoogleService-Info.plist"
REAL_PLIST="${PROJECT_ROOT}/secrets/GoogleService-Info.real.plist"

echo "[swap_google_plist.sh] Checking for real Firebase credentials..."

# Check if we're in a CI environment
if [ -n "$CI" ] || [ -n "$CI_XCODE_PROJECT" ] || [ -n "$GITHUB_ACTIONS" ]; then
    echo "[swap_google_plist.sh] CI environment detected, skipping swap (CI handles its own credentials)."
    exit 0
fi

# Check if the real plist exists
if [ -f "$REAL_PLIST" ]; then
    echo "[swap_google_plist.sh] Found real plist at: $REAL_PLIST"
    echo "[swap_google_plist.sh] Copying to: $DUMMY_PLIST"
    cp "$REAL_PLIST" "$DUMMY_PLIST"
    echo "[swap_google_plist.sh] ✅ Successfully swapped in real Firebase credentials!"
else
    echo "[swap_google_plist.sh] ⚠️  No real plist found at: $REAL_PLIST"
    echo "[swap_google_plist.sh] Using dummy placeholder (Firebase features may not work)."
fi

exit 0
