# CI/CD Integration Setup

This document describes the CI/CD integration that has been configured for the PayBack unit testing suite.

## Overview

The CI/CD setup ensures that all unit tests run automatically with proper sanitizers, coverage reporting, and quality gates. This implementation satisfies Requirements R26 and R40 from the unit testing specification.

## Components

### 1. GitHub Actions Workflow

**Location:** `.github/workflows/ci.yml`

The workflow includes a dedicated `unit-tests` job that runs in a matrix configuration with three sanitizer modes:

- **none**: Standard test run with code coverage enabled
- **thread**: Thread Sanitizer enabled to detect data races
- **address**: Address Sanitizer enabled to detect memory errors

**Key Features:**
- Runs on macOS 15 with latest stable Xcode
- Uses iPhone 15 Pro simulator for consistency
- Caches Swift Package Manager dependencies
- Generates test result bundles for all runs
- Produces coverage reports for non-sanitizer runs
- Enforces 70% minimum coverage threshold
- Uploads artifacts for test results and coverage reports

**Coverage Threshold:**
The workflow will fail if code coverage falls below 70%, ensuring that the test suite maintains adequate coverage of the codebase.

### 2. Test Schemes

#### PayBackTests Scheme

**Location:** `PayBack.xcodeproj/xcshareddata/xcschemes/PayBackTests.xcscheme`

**Configuration:**
- Build configuration: Debug
- Code coverage: Enabled
- Test execution order: Random (to catch order dependencies)
- Parallelization: Enabled
- Environment variables:
  - `TESTING=1` - Indicates tests are running
  - `-TESTING` command line argument

**Purpose:** Standard unit test execution for development and CI

#### PayBackPerformanceTests Scheme

**Location:** `PayBack.xcodeproj/xcshareddata/xcschemes/PayBackPerformanceTests.xcscheme`

**Configuration:**
- Build configuration: Release (for accurate performance measurements)
- Code coverage: Disabled (to avoid overhead)
- Test execution order: Random
- Parallelization: Enabled
- Only runs performance tests (other tests are skipped)
- Environment variables:
  - `PERFORMANCE_TESTING=1` - Indicates performance testing mode
  - `-PERFORMANCE_TESTING` command line argument

**Purpose:** Performance benchmarking with optimizations enabled

**Tests Included:**
- FilteringPerformanceTests
- MemoryUsageTests
- ReconciliationPerformanceTests
- SplitCalculationPerformanceTests

### 3. Pre-Commit Hook

**Location:** `.githooks/pre-commit`

**What it does:**
- Runs unit tests before allowing a commit
- Aborts the commit if any tests fail
- Shows test results summary
- Can be bypassed with `git commit --no-verify` if needed

**Installation:**

Option 1 - Using the setup script:
```bash
./scripts/setup-git-hooks.sh
```

Option 2 - Manual configuration:
```bash
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit
```

**Benefits:**
- Catches test failures before they're committed
- Maintains code quality at the commit level
- Provides immediate feedback to developers

## Usage

### Running Tests Locally

**Standard unit tests:**
```bash
xcodebuild test \
  -project PayBack.xcodeproj \
  -scheme PayBackTests \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 15 Pro'
```

**Performance tests:**
```bash
xcodebuild test \
  -project PayBack.xcodeproj \
  -scheme PayBackPerformanceTests \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 15 Pro'
```

**With Thread Sanitizer:**
```bash
xcodebuild test \
  -project PayBack.xcodeproj \
  -scheme PayBackTests \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 15 Pro' \
  -enableThreadSanitizer YES
```

**With Address Sanitizer:**
```bash
xcodebuild test \
  -project PayBack.xcodeproj \
  -scheme PayBackTests \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 15 Pro' \
  -enableAddressSanitizer YES
```

### Viewing Coverage Reports

After running tests with coverage enabled, generate a report:

```bash
# JSON format
xcrun xccov view --report --json TestResults.xcresult > coverage.json

# Human-readable format
xcrun xccov view --report TestResults.xcresult > coverage-report.txt
```

### CI/CD Workflow

The workflow runs automatically on:
- Push to `main` branch
- Pull requests targeting `main` branch

**Matrix Jobs:**
1. **unit-tests (none)** - Standard tests with coverage
2. **unit-tests (thread)** - Thread Sanitizer enabled
3. **unit-tests (address)** - Address Sanitizer enabled

All three jobs must pass for the CI run to succeed.

## Quality Gates

### Coverage Threshold

- **Minimum:** 70%
- **Enforcement:** CI fails if coverage drops below threshold
- **Measurement:** Line coverage across all test targets

### Sanitizer Checks

- **Thread Sanitizer:** Detects data races and threading issues
- **Address Sanitizer:** Detects memory errors, buffer overflows, use-after-free
- **Enforcement:** CI fails if sanitizers detect any issues

### Test Execution

- **Random order:** Tests run in random order to catch dependencies
- **Parallelization:** Tests run in parallel for faster execution
- **Timeout:** 60-minute timeout prevents hanging tests

## Artifacts

The CI workflow uploads the following artifacts:

1. **test-results-none** - Test results without sanitizers
2. **test-results-thread** - Test results with Thread Sanitizer
3. **test-results-address** - Test results with Address Sanitizer
4. **coverage-report** - Coverage JSON and text reports

Artifacts are retained for 30 days and can be downloaded from the GitHub Actions run page.

## Troubleshooting

### Coverage Below Threshold

If coverage drops below 70%:
1. Review the coverage report to identify untested code
2. Add tests for uncovered logic
3. Focus on core business logic first
4. Consider if some code should be excluded from coverage

### Sanitizer Failures

**Thread Sanitizer:**
- Review the data race report
- Ensure proper actor isolation
- Use appropriate synchronization primitives
- Check for shared mutable state

**Address Sanitizer:**
- Review the memory error report
- Check for buffer overflows
- Verify proper memory management
- Look for use-after-free issues

### Pre-Commit Hook Issues

**Hook not running:**
```bash
git config core.hooksPath  # Should show .githooks
chmod +x .githooks/pre-commit
```

**Tests taking too long:**
- Use `git commit --no-verify` for WIP commits
- Run full tests before pushing instead
- Consider optimizing slow tests

## Requirements Satisfied

### R26 - Test Infrastructure and CI Quality Gates

✅ Fixed random seeds for reproducibility  
✅ Random test execution order  
✅ Code coverage measurement (70% minimum)  
✅ Performance budgets with XCTClockMetric  
✅ Memory budgets with XCTMemoryMetric  

### R40 - Sanitizers and Race Detection

✅ Thread Sanitizer enabled in CI  
✅ Address Sanitizer enabled in CI  
✅ Concurrent operations tested  
✅ Memory leak detection  
✅ Sanitizer failures cause build failure  

## Future Enhancements

Potential improvements for the CI/CD setup:

1. **Performance Regression Detection** - Track performance metrics over time
2. **Flaky Test Detection** - Identify and track intermittent failures
3. **Coverage Trends** - Track coverage changes over time
4. **Parallel Test Execution** - Further optimize CI runtime
5. **Custom Simulators** - Test on multiple iOS versions

## References

- [Xcode Test Plans](https://developer.apple.com/documentation/xcode/organizing-tests-to-improve-feedback)
- [Thread Sanitizer](https://developer.apple.com/documentation/xcode/diagnosing-memory-thread-and-crash-issues-early)
- [Code Coverage](https://developer.apple.com/documentation/xcode/code-coverage)
- [GitHub Actions for iOS](https://docs.github.com/en/actions/automating-builds-and-tests/building-and-testing-swift)
