#!/bin/bash
# Simple test runner that shows all test results

set -e
cd "$(dirname "$0")/.."

echo "═══════════════════════════════════════"
echo "  Running PayBack Test Suite"
echo "═══════════════════════════════════════"
echo ""

# Clean old results
rm -rf TestResults.xcresult test_results.log

# Run tests
echo "Running tests..."
xcodebuild test \
  -project PayBack.xcodeproj \
  -scheme PayBackTests \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -enableCodeCoverage YES \
  -resultBundlePath TestResults.xcresult 2>&1 | tee test_results.log

# Extract results
echo ""
echo "═══════════════════════════════════════"
PASSED=$(grep -c "passed" test_results.log || echo "0")
FAILED=$(grep -c "Test Case.*failed" test_results.log || echo "0")

echo "✅ Tests Passed: $PASSED"
echo "❌ Tests Failed: $FAILED"
echo ""

# Show coverage
echo "📊 Coverage Report:"
xcrun xccov view --report TestResults.xcresult | grep -E "PayBack.app|PayBackTests.xctest"

# Generate full report
xcrun xccov view --report TestResults.xcresult > coverage-report.txt 2>&1

echo ""
echo "Full coverage report saved to: coverage-report.txt"
echo "═══════════════════════════════════════"
