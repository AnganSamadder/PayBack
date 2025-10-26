# Testing Guide for PayBack

This guide provides quick reference for running tests and understanding the testing infrastructure.

## Quick Start

### Running All Tests

```bash
# Standard unit tests
xcodebuild test -project PayBack.xcodeproj -scheme PayBackTests \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 15 Pro'

# Performance tests (Release mode)
xcodebuild test -project PayBack.xcodeproj -scheme PayBackPerformanceTests \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 15 Pro'
```

### Running Tests with Sanitizers

```bash
# Thread Sanitizer (detect data races)
xcodebuild test -project PayBack.xcodeproj -scheme PayBackTests \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 15 Pro' \
  -enableThreadSanitizer YES

# Address Sanitizer (detect memory errors)
xcodebuild test -project PayBack.xcodeproj -scheme PayBackTests \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 15 Pro' \
  -enableAddressSanitizer YES
```

### Generating Coverage Reports

```bash
# Run tests with coverage
xcodebuild test -project PayBack.xcodeproj -scheme PayBackTests \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 15 Pro' \
  -enableCodeCoverage YES \
  -resultBundlePath TestResults.xcresult

# View coverage report
xcrun xccov view --report TestResults.xcresult
```

## Test Organization

```
PayBackTests/
├── Models/              # Domain and linking model tests
├── Services/            # Service layer tests
│   └── Auth/           # Authentication service tests
├── BusinessLogic/       # Core business logic tests
├── Serialization/       # JSON encoding/decoding tests
├── PropertyBased/       # Property-based tests with random inputs
├── Performance/         # Performance benchmark tests
├── Concurrency/         # Actor isolation and async tests
├── Validation/          # Input validation and security tests
├── ErrorHandling/       # Error handling tests
├── TimeBased/          # Time-based logic tests
├── Fixtures/           # Test data fixtures
│   ├── v1/            # Version 1 format fixtures
│   └── v2/            # Version 2 format fixtures
├── Mocks/              # Mock implementations
└── Helpers/            # Test utilities and helpers
```

## Test Schemes

### PayBackTests (Debug)
- All unit tests
- Code coverage enabled
- Random execution order
- Parallelization enabled
- Environment: `TESTING=1`

### PayBackPerformanceTests (Release)
- Performance tests only
- Optimizations enabled
- No code coverage (to avoid overhead)
- Environment: `PERFORMANCE_TESTING=1`

## CI/CD Integration

### GitHub Actions

The CI workflow runs automatically on:
- Push to `main` branch
- Pull requests to `main`

**Test Matrix:**
- Standard tests with coverage
- Tests with Thread Sanitizer
- Tests with Address Sanitizer

**Quality Gates:**
- ✅ All tests must pass
- ✅ Code coverage ≥ 70%
- ✅ No data races detected
- ✅ No memory errors detected

### Pre-Commit Hook

Install the pre-commit hook to run tests before each commit:

```bash
./scripts/setup-git-hooks.sh
```

To bypass (not recommended):
```bash
git commit --no-verify
```

## Coverage Requirements

**Minimum Coverage:** 70%

**Focus Areas:**
- Core business logic (expense splitting, settlement)
- Data models and serialization
- Formatters and validators
- Service layer logic

**Excluded from Coverage:**
- UI code (SwiftUI views)
- Firebase integration code
- Generated code

## Writing Tests

### Test Structure

```swift
import XCTest
@testable import PayBack

final class MyFeatureTests: XCTestCase {
    
    // MARK: - Setup
    
    override func setUp() {
        super.setUp()
        // Test setup
    }
    
    override func tearDown() {
        // Test cleanup
        super.tearDown()
    }
    
    // MARK: - Tests
    
    func testFeatureBehavior() {
        // Given
        let input = createTestInput()
        
        // When
        let result = performOperation(input)
        
        // Then
        XCTAssertEqual(result, expectedValue)
    }
}
```

### Best Practices

1. **Use descriptive test names** - `testExpenseSplitConservesTotal()`
2. **Follow Given-When-Then** - Arrange, Act, Assert
3. **Test one thing per test** - Keep tests focused
4. **Use test fixtures** - Reuse common test data
5. **Test edge cases** - Zero, negative, very large values
6. **Make tests deterministic** - Use fixed seeds for random tests
7. **Keep tests fast** - Mock external dependencies
8. **Test error cases** - Verify error handling

### Property-Based Testing

For mathematical properties, use property-based tests:

```swift
func testConservationProperty() {
    let seed: UInt64 = 12345
    var rng = SeededRandomNumberGenerator(seed: seed)
    
    for _ in 0..<100 {
        let testCase = ExpenseTestCase.random(using: &rng)
        let splits = calculateEqualSplits(
            totalAmount: testCase.totalAmount,
            memberIds: testCase.memberIds
        )
        
        let sum = splits.reduce(0.0) { $0 + $1.amount }
        XCTAssertEqual(sum, testCase.totalAmount, accuracy: 0.01)
    }
}
```

### Performance Testing

Use `measure` for performance tests:

```swift
func testSplitCalculationPerformance() {
    let memberIds = (0..<100).map { _ in UUID() }
    
    measure(metrics: [XCTClockMetric()]) {
        _ = calculateEqualSplits(totalAmount: 1000.0, memberIds: memberIds)
    }
}
```

## Troubleshooting

### Tests Failing Locally

1. Clean build folder: `⌘ + Shift + K` in Xcode
2. Reset simulator: `xcrun simctl erase all`
3. Clear derived data: `rm -rf ~/Library/Developer/Xcode/DerivedData`
4. Resolve packages: `xcodebuild -resolvePackageDependencies`

### Sanitizer Issues

**Thread Sanitizer:**
- Check for shared mutable state
- Ensure proper actor isolation
- Use appropriate synchronization

**Address Sanitizer:**
- Check for buffer overflows
- Verify memory management
- Look for use-after-free

### Coverage Not Updating

1. Delete result bundle: `rm -rf TestResults.xcresult`
2. Clean and rebuild
3. Run tests with coverage explicitly enabled

## Resources

### Documentation
- [Test Suite README](PayBackTests/README.md) - Comprehensive test suite documentation
- [Test Requirements Mapping](PayBackTests/TEST_REQUIREMENTS_MAPPING.md) - Maps tests to requirements
- [Test Monitoring Guide](PayBackTests/TEST_MONITORING.md) - Metrics and monitoring strategy
- [CI/CD Setup](PayBackTests/CI-CD-SETUP.md) - Continuous integration configuration
- [Git Hooks](.githooks/README.md) - Pre-commit hook setup

### External Resources
- [XCTest Documentation](https://developer.apple.com/documentation/xctest)
- [Code Coverage Guide](https://developer.apple.com/documentation/xcode/code-coverage)

## Test Metrics and Monitoring

Track these metrics over time to ensure test suite health:

### Key Metrics
- **Test Count** - Number of tests by category
- **Code Coverage** - Percentage of code covered (target: 70%+)
- **Execution Time** - How long tests take to run (target: <15s)
- **Flakiness Rate** - Tests that fail intermittently (target: 0%)
- **Performance Benchmarks** - Baseline performance measurements

### Monitoring Scripts

```bash
# Daily health check
./scripts/test-health-check.sh

# Weekly metrics report (includes flakiness detection)
./scripts/weekly-metrics.sh

# Export metrics to CSV
./scripts/export-metrics.sh
```

See [Test Monitoring Guide](PayBackTests/TEST_MONITORING.md) for detailed monitoring strategy.

## Getting Help

If you encounter issues:
1. Check this guide
2. Review test documentation
3. Check CI logs for details
4. Ask the team in #engineering
