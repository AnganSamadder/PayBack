#!/bin/sh

# Xcode Cloud Pre-Build Script
# Validates environment and provides diagnostics before xcodebuild runs.

set -euo pipefail

echo "=========================================="
echo "ci_pre_xcodebuild.sh: Pre-build validation"
echo "=========================================="

# Navigate to repository root
cd "$(dirname "$0")/.."

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
