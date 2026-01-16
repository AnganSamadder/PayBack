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
