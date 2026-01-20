#!/bin/sh

# Xcode Cloud Post-Clone Script
# Installs Node.js (required for Convex CLI) and prepares build environment.

set -euo pipefail

echo "=========================================="
echo "ci_post_clone.sh: Setting up build environment"
echo "=========================================="

# Navigate to repository root (ci_scripts is inside the repo)
cd "$(dirname "$0")/.."

echo "Working directory: $(pwd)"
echo "Runner architecture: $(uname -m)"
echo "macOS version: $(sw_vers -productVersion)"
echo "Xcode path: $(xcode-select -p)"

# ----------------------------------------------------------------------------
# Xcode and SDK diagnostics
# ----------------------------------------------------------------------------
echo ""
echo "--- Xcode Environment ---"
echo "Xcode version:"
xcodebuild -version 2>/dev/null || echo "xcodebuild not available"
echo ""
echo "Available iOS SDKs:"
xcodebuild -showsdks 2>/dev/null | grep -i ios || echo "No iOS SDKs found"

# ----------------------------------------------------------------------------
# Clean up unavailable simulators (prevents stale UDID issues)
# ----------------------------------------------------------------------------
echo ""
echo "--- Cleaning Simulators ---"
xcrun simctl delete unavailable 2>/dev/null || true
echo "Cleaned unavailable simulators"

# ----------------------------------------------------------------------------
# Available simulator runtimes
# ----------------------------------------------------------------------------
echo ""
echo "--- Available iOS Runtimes ---"
xcrun simctl runtime list 2>/dev/null | grep -i ios || echo "No iOS runtimes found"

# Show available iPhone simulators with their UUIDs
echo ""
echo "--- Available iPhone Simulators (with UUIDs) ---"
xcrun simctl list devices iPhone available 2>/dev/null || echo "Could not list simulators"

# ----------------------------------------------------------------------------
# Create a fresh simulator if needed (workaround for stale UUIDs)
# ----------------------------------------------------------------------------
echo ""
echo "--- Creating Fresh Simulator ---"
# Get the latest iOS runtime
LATEST_RUNTIME=$(xcrun simctl runtime list 2>/dev/null | grep -i "iOS" | head -1 | awk '{print $1, $2}' || echo "")
echo "Latest runtime: $LATEST_RUNTIME"

# List all available device types
echo ""
echo "--- Available Device Types ---"
xcrun simctl list devicetypes 2>/dev/null | grep -i "iPhone" | head -10 || echo "Could not list device types"

# ----------------------------------------------------------------------------
# Install Node.js via Homebrew (XcodeCloud has Homebrew pre-installed)
# ----------------------------------------------------------------------------
echo ""
echo "--- Installing Node.js ---"

if command -v node >/dev/null 2>&1; then
	echo "Node.js already available: $(node --version)"
else
	echo "Installing Node.js via Homebrew..."
	if command -v brew >/dev/null 2>&1; then
		brew install node
		echo "Installed Node.js: $(node --version)"
	else
		echo "warning: Homebrew not available. Cannot install Node.js."
		echo "         Convex deploy will be skipped during build."
	fi
fi

if command -v npx >/dev/null 2>&1; then
	echo "npx available: $(npx --version)"
else
	echo "warning: npx not found after Node.js install."
fi

# ----------------------------------------------------------------------------
# Environment diagnostics
# ----------------------------------------------------------------------------
echo ""
echo "--- Environment Summary ---"
echo "Xcode version: $(xcodebuild -version | head -1)"
echo "Swift version: $(swift --version 2>&1 | head -1)"
echo "PATH: $PATH"

echo ""
echo "ci_post_clone.sh complete"
echo "=========================================="
