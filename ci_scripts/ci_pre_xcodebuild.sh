#!/bin/sh
set -e

echo "=========================================="
echo "ci_pre_xcodebuild.sh: Preparing GoogleService-Info.plist"
echo "=========================================="

# Determine the repository root
# CI_WORKSPACE is set by Xcode Cloud, fallback to script's parent directory
if [ -n "$CI_WORKSPACE" ]; then
  REPO_ROOT="$CI_WORKSPACE"
else
  # Get the directory containing ci_scripts (one level up from this script)
  REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi

echo "Repository root: $REPO_ROOT"

# Debug: List directory structure to verify paths
echo "Debug: Listing apps directory..."
ls -F "$REPO_ROOT/apps/" 2>/dev/null || echo "apps directory not found"
ls -F "$REPO_ROOT/apps/ios/" 2>/dev/null || echo "apps/ios directory not found"

# Path must match where Xcode expects the file in the project
PLIST_PATH="$REPO_ROOT/apps/ios/PayBack/GoogleService-Info.plist"

if [ -z "$GSI_BASE64" ]; then
  echo "ℹ️  GSI_BASE64 environment variable is not set."
  echo "ℹ️  Using placeholder GoogleService-Info.plist (suitable for emulator testing)."
else
  echo "🔐 GSI_BASE64 is set. Decoding real GoogleService-Info.plist..."
  
  # Ensure directory exists
  mkdir -p "$(dirname "$PLIST_PATH")"
  
  echo "$GSI_BASE64" | base64 -D > "$PLIST_PATH"
  echo "✅ Successfully wrote real GoogleService-Info.plist to $PLIST_PATH"
fi

echo "=========================================="
