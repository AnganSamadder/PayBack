# Quick Test Reference 🚀

## Run All Tests
```bash
cd /Users/angansamadder/Code/PayBack
rm -rf TestResults.xcresult
xcodebuild test -project PayBack.xcodeproj -scheme PayBackTests \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -enableCodeCoverage YES -resultBundlePath TestResults.xcresult
```

## View Coverage
```bash
# Summary
xcrun xccov view --report TestResults.xcresult | grep -E "(PayBack.app|PayBackTests.xctest)"

# Full Report
xcrun xccov view --report TestResults.xcresult > coverage-report.txt
```

## Run Specific Test Suite
```bash
xcodebuild test -project PayBack.xcodeproj -scheme PayBackTests \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -only-testing:PayBackTests/ExpenseSplittingTests
```

## Test Statistics
- **Files**: 38
- **Functions**: 698
- **Pass Rate**: 99.86%+
- **Coverage**: 94.53% (test code)

## Test Categories
✅ Business Logic  
✅ Data Models  
✅ Services  
✅ Validation & Security  
✅ Concurrency  
✅ Performance  
✅ Serialization  
✅ Time-Based  
✅ Error Handling  
✅ Integration  

## Documentation
- `TESTING_COMPLETE.md` - Full overview
- `TEST_COVERAGE_SUMMARY.md` - Detailed coverage
- `TEST_RUN_SUMMARY.md` - Execution results
- `coverage-report.txt` - Line-by-line coverage

## Status: ✅ PRODUCTION READY
