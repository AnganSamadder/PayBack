#!/bin/bash
set -e

cd "$(dirname "$0")/.."

echo "🧪 Running PayBack Tests..."
echo ""

# Clean old results
rm -rf TestResults.xcresult

# Run tests showing each result
xcodebuild test \
  -project PayBack.xcodeproj \
  -scheme PayBackTests \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -enableCodeCoverage YES \
  -resultBundlePath TestResults.xcresult 2>&1 | \
  tee test_output.log | \
  grep -E "Test Case|Test Suite 'All tests'" | \
  sed 's/Test Case/  /' | \
  sed "s/passed.*/$(printf '\033[32mpassed ✓\033[0m')/" | \
  sed "s/failed.*/$(printf '\033[31mfailed ✗\033[0m')/"

echo ""
echo "📊 Coverage Report:"
xcrun xccov view --report TestResults.xcresult | grep -E "PayBack.app|PayBackTests.xctest"

echo ""
echo "✅ Done! Full report: coverage-report.txt"
xcrun xccov view --report TestResults.xcresult > coverage-report.txt 2>&1
