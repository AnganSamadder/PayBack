#!/bin/bash
# Test Health Check Script
# Runs tests and checks key health metrics

set -e

echo "=== PayBack Test Health Check ==="
echo "Date: $(date)"
echo ""

# Configuration
SIMULATOR="platform=iOS Simulator,name=iPhone 15 Pro"
COVERAGE_THRESHOLD=70
TIME_THRESHOLD=15

# Run tests
echo "Running tests..."
xcodebuild test \
  -project PayBack.xcodeproj \
  -scheme PayBack \
  -destination "$SIMULATOR" \
  -enableCodeCoverage YES \
  -resultBundlePath TestResults.xcresult \
  > test_output.log 2>&1

TEST_EXIT_CODE=$?

# Check if tests passed
echo ""
if [ $TEST_EXIT_CODE -eq 0 ]; then
  echo "✅ All tests passed"
else
  echo "❌ Some tests failed"
  echo ""
  echo "Failed tests:"
  grep "Test Case.*failed" test_output.log || echo "  (Could not parse failures)"
fi

# Count tests
TEST_COUNT=$(grep -c "Test Case.*passed" test_output.log || echo "0")
echo ""
echo "📊 Metrics:"
echo "  Test Count: $TEST_COUNT"

# Check execution time
TOTAL_TIME=$(grep "Test Suite.*seconds" test_output.log | tail -1 | awk '{print $(NF-1)}' || echo "0")
echo "  Total Time: ${TOTAL_TIME}s"

# Check coverage
if [ -d "TestResults.xcresult" ]; then
  COVERAGE=$(xcrun xccov view --report TestResults.xcresult 2>/dev/null | grep "PayBack.app" | awk '{print $NF}' || echo "N/A")
  echo "  Coverage: $COVERAGE"
  
  # Check coverage threshold
  if [ "$COVERAGE" != "N/A" ]; then
    COVERAGE_NUM=$(echo $COVERAGE | sed 's/%//')
    if (( $(echo "$COVERAGE_NUM < $COVERAGE_THRESHOLD" | bc -l 2>/dev/null || echo "0") )); then
      echo ""
      echo "⚠️  Coverage ($COVERAGE) is below ${COVERAGE_THRESHOLD}% threshold"
    fi
  fi
else
  echo "  Coverage: N/A (result bundle not found)"
fi

# Check execution time threshold
if (( $(echo "$TOTAL_TIME > $TIME_THRESHOLD" | bc -l 2>/dev/null || echo "0") )); then
  echo ""
  echo "⚠️  Execution time (${TOTAL_TIME}s) exceeds ${TIME_THRESHOLD}s threshold"
fi

echo ""
echo "=== End Health Check ==="

# Exit with test result code
exit $TEST_EXIT_CODE
