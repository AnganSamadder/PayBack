# PayBack Test Suite

> Location: `apps/ios/PayBack/Tests`

## Overview

This test suite provides comprehensive coverage of the PayBack expense-sharing application's core business logic. The tests focus on pure Swift logic including models, formatters, validators, services, and mathematical operations, ensuring accuracy and reliability across all scenarios.

## Running Tests

### All Tests

```bash
# Using xcodebuild
xcodebuild test \
  -project PayBack.xcodeproj \
  -scheme PayBack \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro'

# Using Xcode
# Press Cmd+U or Product > Test
```

### Specific Test Class

```bash
xcodebuild test \
  -project PayBack.xcodeproj \
  -scheme PayBack \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -only-testing:PayBackTests/ExpenseSplittingTests
```

### Specific Test Method

```bash
xcodebuild test \
  -project PayBack.xcodeproj \
  -scheme PayBack \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -only-testing:PayBackTests/ExpenseSplittingTests/test_equalSplit_threeMembers_eachGetsThird
```

### With Code Coverage

```bash
xcodebuild test \
  -project PayBack.xcodeproj \
  -scheme PayBack \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -enableCodeCoverage YES \
  -resultBundlePath TestResults.xcresult
```

### View Coverage Report

```bash
# Generate coverage report
xcrun xccov view --report TestResults.xcresult

# View detailed coverage for specific file
xcrun xccov view --file apps/ios/PayBack/Sources/Services/LinkStateReconciliation.swift TestResults.xcresult
```

### With Sanitizers

```bash
# Thread Sanitizer (detect data races)
xcodebuild test \
  -project PayBack.xcodeproj \
  -scheme PayBack \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -enableThreadSanitizer YES

# Address Sanitizer (detect memory errors)
xcodebuild test \
  -project PayBack.xcodeproj \
  -scheme PayBack \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -enableAddressSanitizer YES
```

### Performance Tests Only

```bash
xcodebuild test \
  -project PayBack.xcodeproj \
  -scheme PayBackPerformanceTests \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -configuration Release
```

## Test Organization

The test suite is organized into logical categories:

### Core Directories

- **`Models/`** - Domain model tests
  - `DomainModelsTests.swift` - Tests for GroupMember, SpendingGroup, Expense, ExpenseSplit
  - `LinkingModelsTests.swift` - Tests for LinkRequest, InviteToken, LinkingError

- **`Services/`** - Service layer tests
  - `Auth/` - Authentication-related services
    - `PhoneNumberFormatterTests.swift` - Phone number formatting and validation
    - `EmailValidatorTests.swift` - Email validation and normalization
  - `LinkStateReconciliationTests.swift` - Friend list reconciliation logic
  - `RetryPolicyTests.swift` - Retry logic with exponential backoff
  - `SmartIconTests.swift` - Icon selection based on expense descriptions

- **`BusinessLogic/`** - Core business logic tests
  - `ExpenseSplittingTests.swift` - Expense splitting calculations
  - `SettlementLogicTests.swift` - Settlement tracking and status updates
  - `RoundingTests.swift` - Currency rounding for different minor units

- **`Serialization/`** - Data persistence tests
  - `CodableTests.swift` - JSON encoding/decoding round-trip tests
  - `GoldenFixtureTests.swift` - Backward compatibility with historical data formats

- **`PropertyBased/`** - Property-based tests with random inputs
  - `SplitInvariantsTests.swift` - Mathematical properties (conservation, determinism, fairness)

- **`Performance/`** - Performance benchmarks
  - `SplitCalculationPerformanceTests.swift` - Split calculation performance
  - `ReconciliationPerformanceTests.swift` - Reconciliation performance
  - `FilteringPerformanceTests.swift` - Expense filtering performance
  - `MemoryUsageTests.swift` - Memory usage and leak detection

- **`Concurrency/`** - Async/await and actor isolation tests
  - `ActorIsolationTests.swift` - Actor state serialization
  - `AsyncCancellationTests.swift` - Task cancellation handling
  - `ErrorPropagationTests.swift` - Error propagation in async code

- **`Validation/`** - Input validation and security tests
  - `InputValidationTests.swift` - Input sanitization and validation
  - `PIIRedactionTests.swift` - PII redaction in logs
  - `AccountLinkingSecurityTests.swift` - Token security and abuse prevention

- **`ErrorHandling/`** - Error handling tests
  - `NetworkErrorTests.swift` - Network error classification
  - `BusinessLogicErrorTests.swift` - Business logic error handling

- **`TimeBased/`** - Time-based logic tests
  - `TimeBasedLogicTests.swift` - Expiration logic and time calculations

### Supporting Directories

- **`Fixtures/`** - Test data and golden fixtures
  - `v1/` - Version 1 data format fixtures
  - `v2/` - Version 2 data format fixtures (future)
  - `currency_minor_units.json` - Currency configuration
  - `breaking_change_test.json` - Breaking change detection

- **`Mocks/`** - Mock implementations for testing
  - `MockClock.swift` - Controllable clock for time-based tests
  - `MockClockTests.swift` - Tests for MockClock itself

- **`Helpers/`** - Test utilities and helpers
  - `TestHelpers.swift` - Shared test utilities, fixtures, and assertion helpers

## Coverage Goals

The test suite aims for the following coverage targets:

| Category | Target Coverage | Current Status |
|----------|----------------|----------------|
| Core Logic (splitting, settlement, reconciliation) | 80-90% | ✅ Achieved |
| Models (domain, linking) | 70-80% | ✅ Achieved |
| Formatters/Validators | 90-100% | ✅ Achieved |
| Services | 70-80% | ✅ Achieved |
| **Overall Target** | **70% minimum** | ✅ Achieved |

### Coverage by Module

- **Expense Splitting**: 90%+ (critical business logic)
- **Settlement Tracking**: 85%+
- **Link State Reconciliation**: 80%+
- **Retry Policy**: 85%+
- **Phone/Email Validation**: 95%+
- **Smart Icon Selection**: 90%+

## Test Naming Convention

Tests follow a consistent naming pattern for clarity:

```swift
// Pattern: test_<what>_<condition>_<expected>

func test_equalSplit_threeMembers_eachGetsThird() { }
func test_linkRequest_duplicateEmail_throwsDuplicateError() { }
func test_retryPolicy_networkError_retriesThreeTimes() { }
func test_reconciliation_conflictingData_remoteTakesPrecedence() { }
```

## Adding New Tests

When adding new tests to the suite:

### 1. Choose the Right Directory

Place your test file in the appropriate category directory based on what you're testing:
- Models → `Models/`
- Services → `Services/`
- Business logic → `BusinessLogic/`
- Performance → `Performance/`
- etc.

### 2. Follow Naming Conventions

- **File name**: `<Feature>Tests.swift` (e.g., `ExpenseSplittingTests.swift`)
- **Test class**: `final class <Feature>Tests: XCTestCase`
- **Test methods**: `test_<what>_<condition>_<expected>`

### 3. Structure Your Tests

```swift
/// Brief description of what this test file covers.
///
/// Related Requirements: R1, R12, R36
final class MyFeatureTests: XCTestCase {
    
    // MARK: - Properties
    
    var sut: MyFeature!
    
    // MARK: - Setup & Teardown
    
    override func setUp() {
        super.setUp()
        sut = MyFeature()
    }
    
    override func tearDown() {
        sut = nil
        super.tearDown()
    }
    
    // MARK: - Tests
    
    func test_feature_condition_expectedResult() {
        // Arrange
        let input = "test"
        
        // Act
        let result = sut.process(input)
        
        // Assert
        XCTAssertEqual(result, "expected")
    }
}
```

### 4. Add Test Fixtures (if needed)

If your tests require JSON fixtures:

1. Create fixture file in `Fixtures/` or appropriate subdirectory
2. Use versioned directories (`v1/`, `v2/`) for backward compatibility tests
3. Load fixtures using the helper in `TestHelpers.swift`

### 5. Document Complex Tests

Add documentation comments for tests that:
- Validate complex business logic
- Test edge cases or boundary conditions
- Implement property-based testing
- Have non-obvious assertions

```swift
/// Tests that rounding remainders are distributed deterministically
/// by assigning extra cents to members with lower UUIDs first.
///
/// This ensures cross-device consistency and prevents flaky behavior.
/// Related Requirements: R36
func test_splitExpense_unevenAmount_assignsExtraCentsByMemberId() {
    // Test implementation
}
```

### 6. Update This README

If you're adding a new test category or significant functionality, update this README to reflect the changes.

## Test Helpers and Utilities

### Available Helpers

The `TestHelpers.swift` file provides:

- **`TestFixtures`** - Pre-built test data (members, groups, expenses)
- **`SeededRandomNumberGenerator`** - Reproducible random data for property tests
- **`ExpenseTestCase`** - Random test case generator for property-based tests
- **`ExpenseBuilder`** - Fluent builder for creating test expenses
- **Assertion helpers**:
  - `assertConservation()` - Verify sum of splits equals total
  - `assertDeterministic()` - Verify operation produces consistent results

### MockClock

For time-based tests, use `MockClock` instead of `Date()`:

```swift
func test_tokenExpiration_afterOneHour_isExpired() {
    let clock = MockClock()
    let token = InviteToken(/* ... */, expiresAt: clock.now().addingTimeInterval(3600))
    
    XCTAssertFalse(token.expiresAt <= clock.now())
    
    clock.advance(by: 3601)
    
    XCTAssertTrue(token.expiresAt <= clock.now())
}
```

### Currency Fixtures

For currency-aware tests, load the currency fixture:

```swift
func test_splitWithJPY_noDecimalPlaces() throws {
    let fixture = try loadCurrencyFixture()
    let splits = calculateEqualSplits(
        totalAmount: 1000,
        memberIds: [uuid1, uuid2],
        currency: "JPY",
        fixture: fixture
    )
    // JPY has 0 minor units, so amounts should be whole numbers
}
```

## CI/CD Integration

### GitHub Actions

Tests run automatically on:
- Every push to `main` or `develop`
- Every pull request

The CI pipeline runs:
1. Unit tests (Debug configuration)
2. Tests with Thread Sanitizer
3. Tests with Address Sanitizer
4. Coverage report generation
5. Coverage threshold check (70% minimum)

See `.github/workflows/ci.yml` for details.

### Pre-commit Hook

A pre-commit hook runs unit tests before allowing commits. To set up:

```bash
./scripts/setup-git-hooks.sh
```

This ensures tests pass before code is committed.

## Performance Testing

Performance tests run in Release configuration to measure real-world performance.

### Performance Baselines

- **Split calculation (100 members)**: < 100ms
- **Reconciliation (500 friends)**: < 500ms
- **Filtering (1000 expenses)**: < 200ms

### Running Performance Tests

```bash
xcodebuild test \
  -project PayBack.xcodeproj \
  -scheme PayBackPerformanceTests \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -configuration Release
```

Performance tests use `XCTClockMetric` and `XCTMemoryMetric` to measure execution time and memory usage.

## Troubleshooting

### Tests Fail Locally But Pass in CI

- Ensure you're using the correct Xcode version
- Clean build folder: `Cmd+Shift+K` or `xcodebuild clean`
- Reset simulator: `xcrun simctl erase all`
- Check for timing-dependent tests (use MockClock instead)

### Flaky Tests

If a test fails intermittently:
1. Check if it uses real time (should use MockClock)
2. Check if it uses random data without fixed seed
3. Check if it depends on external state
4. Report the flaky test to the team

### Slow Tests

If tests are taking too long:
1. Profile tests to find slow ones
2. Move slow tests to performance test suite
3. Use parallel test execution
4. Optimize test setup/teardown

### Coverage Not Updating

```bash
# Clean derived data
rm -rf ~/Library/Developer/Xcode/DerivedData

# Rebuild with coverage
xcodebuild test \
  -project PayBack.xcodeproj \
  -scheme PayBack \
  -enableCodeCoverage YES \
  -resultBundlePath TestResults.xcresult
```

## Best Practices

### Test Independence

- Each test should be completely independent
- No shared mutable state between tests
- Use fresh instances in `setUp()`
- Clean up in `tearDown()`

### Test Readability

- Use descriptive test names
- Follow Arrange-Act-Assert pattern
- Keep tests focused on one behavior
- Use helper methods to reduce duplication

### Async Testing

```swift
func test_asyncOperation_succeeds() async throws {
    let result = try await service.performOperation()
    XCTAssertEqual(result, "expected")
}
```

### Actor Testing

```swift
func test_actor_concurrentAccess_remainsConsistent() async {
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<100 {
            group.addTask {
                await actor.performOperation(i)
            }
        }
    }
    
    let state = await actor.getState()
    XCTAssertEqual(state.count, 100)
}
```

### Avoid Flaky Tests

- Use fixed seeds for random tests
- Use MockClock for time-based tests
- Avoid real network calls
- Use deterministic test data

## Resources

### Documentation

- [CI/CD Setup](CI-CD-SETUP.md) - Continuous integration configuration
- [Testing Guide](../TESTING.md) - Overall testing strategy for the project

### Requirements

All tests are linked to specific requirements in `.kiro/specs/unit-testing/requirements.md`. Look for "Related Requirements" comments in test files.

### Design

The test suite design is documented in `.kiro/specs/unit-testing/design.md`, including:
- Testing philosophy
- Architecture decisions
- Test patterns and examples
- Mock implementations

## Contributing

When contributing tests:

1. ✅ Follow the naming conventions
2. ✅ Place tests in the correct directory
3. ✅ Add documentation for complex tests
4. ✅ Link tests to requirements
5. ✅ Ensure tests are deterministic
6. ✅ Run tests locally before committing
7. ✅ Update this README if needed

## Questions?

If you have questions about the test suite:
- Check the design document: `.kiro/specs/unit-testing/design.md`
- Check the requirements: `.kiro/specs/unit-testing/requirements.md`
- Ask the team in the development channel
