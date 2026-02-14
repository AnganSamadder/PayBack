#!/bin/sh
set -euo pipefail

echo "=========================================="
echo "ci_pre_xcodebuild.sh: Pre-build"
echo "=========================================="
echo "CI_TAG: ${CI_TAG:-none}"
echo "CI_BUILD_NUMBER: ${CI_BUILD_NUMBER:-none}"
echo "CI_WORKFLOW: ${CI_WORKFLOW:-none}"

cd "$(dirname "$0")/.."

# ----------------------------------------------------------------------------
# Version Extraction from Tag
# When a tag like beta-0.1.0 or release-1.0.0 is pushed, extract the version
# and update the project's marketing version.
# ----------------------------------------------------------------------------
if [[ -n "${CI_TAG:-}" ]]; then
	MARKETING_VERSION=$(echo "$CI_TAG" | sed -E 's/^(alpha|beta|release|prod)-//')
	BUILD_NUMBER="$CI_BUILD_NUMBER"

	echo "Tag detected: $CI_TAG"
	echo "Marketing Version: $MARKETING_VERSION"
	echo "Build Number: $BUILD_NUMBER"

	PROJECT_YML="$CI_PRIMARY_REPOSITORY_PATH/project.yml"

	if [[ -f "$PROJECT_YML" ]]; then
		sed -i.bak "s/MARKETING_VERSION: .*/MARKETING_VERSION: $MARKETING_VERSION/" "$PROJECT_YML"
		sed -i.bak "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: $BUILD_NUMBER/" "$PROJECT_YML"
		rm -f "${PROJECT_YML}.bak"

		echo "Updated project.yml with version $MARKETING_VERSION ($BUILD_NUMBER)"

		cd "$CI_PRIMARY_REPOSITORY_PATH"
		if command -v bunx >/dev/null 2>&1; then
			bunx xcodegen generate --spec project.yml
		elif command -v npx >/dev/null 2>&1; then
			npx xcodegen generate --spec project.yml
		fi
	fi
fi

# ----------------------------------------------------------------------------
# Ensure our helper binaries are on PATH
# ----------------------------------------------------------------------------
export PATH="$(pwd)/ci_scripts/bin:$PATH"
echo ""
echo "--- Tooling ---"
echo "which xcodebuild: $(command -v xcodebuild)"

# ----------------------------------------------------------------------------
# Critical: Architecture and SDK validation
# ----------------------------------------------------------------------------
echo ""
echo "--- Architecture Check ---"
ARCH=$(uname -m)
echo "Runner architecture: $ARCH"

if [ "$ARCH" = "x86_64" ]; then
	echo "WARNING: Running on Intel/x86_64 architecture!"
	echo "         ConvexMobile XCFramework only has arm64 simulator slices."
	echo "         Build may fail with linker errors if building for simulator."
	echo ""
	echo "         Recommended: Configure workflow to use Apple Silicon runners."
fi

# Show deployment target vs available runtimes
echo ""
echo "--- Deployment Target Check ---"
echo "Project deployment target: iOS 18.0"
echo "Available iOS runtimes:"
xcrun simctl runtime list 2>/dev/null | grep -i "iOS 18" || echo "  No iOS 18 runtimes found!"

# ----------------------------------------------------------------------------
# Simulator validation
# ----------------------------------------------------------------------------
echo ""
echo "--- Simulator Check ---"

# Get the first available iPhone simulator for iOS 18
AVAILABLE_SIM_18=$(xcrun simctl list devices available 2>/dev/null | grep -A 50 "iOS 18" | grep -E "iPhone.*\(" | head -1 || echo "")
if [ -n "$AVAILABLE_SIM_18" ]; then
	echo "iOS 18 simulator available: $AVAILABLE_SIM_18"
else
	echo "WARNING: No iOS 18 iPhone simulators found!"
	echo ""
	echo "Falling back to any available iPhone simulator:"
	AVAILABLE_SIM=$(xcrun simctl list devices iPhone available 2>/dev/null | grep -E "iPhone.*\(" | head -1 || echo "")
	if [ -n "$AVAILABLE_SIM" ]; then
		echo "  Found: $AVAILABLE_SIM"
	else
		echo "  ERROR: No iPhone simulators found at all!"
		echo ""
		echo "All available devices:"
		xcrun simctl list devices available 2>/dev/null | head -30 || true
	fi
fi

# ----------------------------------------------------------------------------
# Environment diagnostics
# ----------------------------------------------------------------------------
echo ""
echo "--- Build Environment ---"
echo "CI_XCODE_PROJECT: ${CI_XCODE_PROJECT:-unset}"
echo "CI_XCODE_SCHEME: ${CI_XCODE_SCHEME:-unset}"
echo "CI_XCODEBUILD_ACTION: ${CI_XCODEBUILD_ACTION:-unset}"
echo "CI_BUILD_NUMBER: ${CI_BUILD_NUMBER:-unset}"
echo "CI_WORKFLOW: ${CI_WORKFLOW:-unset}"
echo "CI_PRODUCT_PLATFORM: ${CI_PRODUCT_PLATFORM:-unset}"

echo ""
echo "--- Node/npx Status ---"
if command -v node >/dev/null 2>&1; then
	echo "Node: $(node --version)"
else
	echo "Node: NOT FOUND"
fi

if command -v npx >/dev/null 2>&1; then
	echo "npx: $(npx --version)"
else
	echo "npx: NOT FOUND"
fi

# ----------------------------------------------------------------------------
# Convex deploy key check (informational only)
# ----------------------------------------------------------------------------
echo ""
echo "--- Convex Configuration ---"
if [ -n "${CONVEX_DEPLOY_KEY:-}" ]; then
	echo "CONVEX_DEPLOY_KEY: set (length=${#CONVEX_DEPLOY_KEY})"
else
	echo "CONVEX_DEPLOY_KEY: NOT SET"
	echo "  Convex backend deploy will be skipped during build."
	echo "  Set CONVEX_DEPLOY_KEY in Xcode Cloud environment variables to enable."
fi

if [ "${CONVEX_DEPLOY_ON_CI:-}" = "1" ]; then
	echo "CONVEX_DEPLOY_ON_CI: enabled"
else
	echo "CONVEX_DEPLOY_ON_CI: disabled (set to '1' to enable deploy)"
fi

echo ""
echo "ci_pre_xcodebuild.sh complete"
echo "=========================================="
