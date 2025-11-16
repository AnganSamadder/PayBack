# Test Monitoring and Metrics

This document describes the test monitoring strategy for the PayBack test suite, including metrics to track, tools to use, and how to interpret the data.

## Overview

Test monitoring helps ensure the test suite remains healthy, fast, and effective over time. We track four key categories of metrics:

1. **Test Count** - Number of tests and their distribution
2. **Execution Time** - How long tests take to run
3. **Coverage** - Percentage of code covered by tests
4. **Flakiness** - Tests that fail intermittently

## Metrics to Track

### 1. Test Count Metrics

Track the number of tests in each category to ensure balanced coverage:

| Category | Current Count | Target |
|----------|--------------|--------|
| Models | ~30 | 25-40 |
| Services | ~40 | 35-50 |
| Business Logic | ~50 | 45-60 |
| Property-Based | ~15 | 10-20 |
| Performance | ~10 | 8-15 |
| Concurrency | ~15 | 12-20 |
| Validation | ~25 | 20-30 |
| Serialization | ~20 | 15-25 |
| Error Handling | ~15 | 12-20 |
| Time-Based | ~10 | 8-15 |
| **Total** | **~230** | **200-300** |

#### How to Measure

```bash
# Count all tests
xcodebuild test -project PayBack.xcodeproj -scheme PayBack -dry-run 2>&1 | grep "Test Case" | wc -l

# Count tests by directory
find PayBackTests -name "*Tests.swift" -exec grep -c "func test_" {} + | awk '{s+=$1} END {print s}'

# Count tests per file
find PayBackTests -name "*Tests.swift" -exec sh -c 'echo "$1: $(grep -c "func test_" "$1")"' _ {} \;
```

#### Tracking Over Time

Create a simple CSV file to track test counts:

```csv
Date,Total,Models,Services,BusinessLogic,PropertyBased,Performance,Concurrency,Validation,Serialization,ErrorHandling,TimeBased
2024-01-15,230,30,40,50,15,10,15,25,20,15,10
2024-02-01,245,32,42,52,16,11,16,26,22,16,12
```

### 2. Execution Time Metrics

Track how long tests take to run to prevent slowdowns:

| Test Suite | Target Time | Warning Threshold | Critical Threshold |
|------------|-------------|-------------------|-------------------|
| Unit Tests (all) | < 10s | 15s | 20s |
| Models | < 1s | 2s | 3s |
| Services | < 2s | 3s | 5s |
| Business Logic | < 2s | 3s | 5s |
| Property-Based | < 5s | 8s | 10s |
| Performance | < 30s | 45s | 60s |
| Concurrency | < 3s | 5s | 8s |

#### How to Measure

```bash
# Run tests with timing
xcodebuild test \
  -project PayBack.xcodeproj \
  -scheme PayBack \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  2>&1 | grep "Test Suite" | grep "seconds"

# Extract timing from result bundle
xcrun xcresulttool get --path TestResults.xcresult --format json | \
  jq '.actions[].actionResult.testsRef.id._value' | \
  xargs -I {} xcrun xcresulttool get --path TestResults.xcresult --id {} --format json | \
  jq '.summaries.values[].tests[].duration'
```

#### Tracking Over Time

```csv
Date,TotalTime,ModelsTime,ServicesTime,BusinessLogicTime,PropertyBasedTime,PerformanceTime
2024-01-15,8.5,0.8,1.5,1.8,4.2,25.0
2024-02-01,9.2,0.9,1.6,2.0,4.5,26.5
```

### 3. Coverage Metrics

Track code coverage to ensure adequate testing:

| Module | Current Coverage | Target | Critical Minimum |
|--------|-----------------|--------|------------------|
| Expense Splitting | 95% | 90%+ | 85% |
| Settlement Logic | 90% | 85%+ | 80% |
| Link Reconciliation | 88% | 85%+ | 80% |
| Retry Policy | 92% | 85%+ | 80% |
| Phone/Email Validation | 98% | 95%+ | 90% |
| Smart Icon | 95% | 90%+ | 85% |
| Domain Models | 85% | 80%+ | 70% |
| Linking Models | 82% | 80%+ | 70% |
| **Overall** | **87%** | **80%+** | **70%** |

#### How to Measure

```bash
# Generate coverage report
xcodebuild test \
  -project PayBack.xcodeproj \
  -scheme PayBack \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -enableCodeCoverage YES \
  -resultBundlePath TestResults.xcresult

# View coverage summary
xcrun xccov view --report TestResults.xcresult

# View coverage for specific file
xcrun xccov view --file apps/ios/PayBack/Sources/Services/LinkStateReconciliation.swift TestResults.xcresult

# Export coverage as JSON
xcrun xccov view --report --json TestResults.xcresult > coverage.json
```

#### Tracking Over Time

```csv
Date,Overall,ExpenseSplitting,Settlement,LinkReconciliation,RetryPolicy,Validation,Models
2024-01-15,87,95,90,88,92,98,85
2024-02-01,88,96,91,89,93,98,86
```

#### Coverage Visualization

Use tools like:
- **Xcode Coverage Report** - Built-in coverage viewer
- **Slather** - Generate HTML coverage reports
- **Codecov** - Cloud-based coverage tracking

```bash
# Install Slather
gem install slather

# Generate HTML report
slather coverage --html --scheme PayBack PayBack.xcodeproj

# Open report
open html/index.html
```

### 4. Flakiness Metrics

Track tests that fail intermittently to maintain reliability:

| Metric | Target | Warning Threshold |
|--------|--------|-------------------|
| Flaky Test Count | 0 | 3 |
| Flakiness Rate | 0% | 1% |
| Consecutive Failures | 0 | 2 |

#### How to Measure

Run tests multiple times to detect flakiness:

```bash
# Run tests 10 times
for i in {1..10}; do
  echo "Run $i"
  xcodebuild test \
    -project PayBack.xcodeproj \
    -scheme PayBack \
    -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
    -resultBundlePath "TestResults_$i.xcresult" \
    2>&1 | tee "test_run_$i.log"
done

# Analyze results for flaky tests
grep -h "Test Case.*failed" test_run_*.log | sort | uniq -c | sort -rn
```

#### Tracking Flaky Tests

Maintain a list of known flaky tests:

```csv
TestName,FailureCount,TotalRuns,FlakinessRate,LastSeen,Status
test_async_operation,2,100,2%,2024-01-15,Fixed
test_concurrent_access,1,100,1%,2024-02-01,Monitoring
```

#### Flakiness Prevention

- ✅ Use fixed seeds for random tests
- ✅ Use MockClock for time-based tests
- ✅ Avoid real network calls
- ✅ Use deterministic test data
- ✅ Properly handle async operations
- ✅ Clean up state between tests

## Monitoring Tools

### 1. Xcode Built-in Tools

**Test Navigator**
- View all tests and their status
- Run individual tests or test classes
- See test execution time

**Coverage Report**
- View coverage by file and function
- Identify untested code paths
- Track coverage trends

**Test Report**
- View detailed test results
- See failure messages and stack traces
- Export test results

### 2. Command-Line Tools

**xcodebuild**
```bash
# Run tests with detailed output
xcodebuild test -project PayBack.xcodeproj -scheme PayBack -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

**xcresulttool**
```bash
# Extract test results
xcrun xcresulttool get --path TestResults.xcresult --format json
```

**xccov**
```bash
# View coverage report
xcrun xccov view --report TestResults.xcresult
```

### 3. CI/CD Integration

**GitHub Actions** (`.github/workflows/ci.yml`)

The CI pipeline automatically:
- Runs all tests on every push/PR
- Generates coverage reports
- Checks coverage thresholds
- Runs tests with sanitizers
- Reports failures

**Metrics Collected in CI:**
- Test pass/fail status
- Execution time
- Coverage percentage
- Sanitizer violations
- Performance regressions

### 4. Third-Party Tools

**Recommended Tools:**

1. **Codecov** - Cloud-based coverage tracking
   - Visualize coverage trends
   - Compare coverage across branches
   - Set coverage requirements for PRs

2. **Slather** - Coverage report generator
   - Generate HTML reports
   - Export to various formats
   - Integrate with CI

3. **xcpretty** - Prettier xcodebuild output
   - Colorized output
   - Progress indicators
   - JUnit XML reports

```bash
# Install xcpretty
gem install xcpretty

# Use with xcodebuild
xcodebuild test ... | xcpretty --report html
```

## Monitoring Scripts

### Daily Test Health Check

Create a script to check test health daily:

```bash
#!/bin/bash
# scripts/test-health-check.sh

echo "=== PayBack Test Health Check ==="
echo "Date: $(date)"
echo ""

# Run tests
echo "Running tests..."
xcodebuild test \
  -project PayBack.xcodeproj \
  -scheme PayBack \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -enableCodeCoverage YES \
  -resultBundlePath TestResults.xcresult \
  > test_output.log 2>&1

# Check if tests passed
if [ $? -eq 0 ]; then
  echo "✅ All tests passed"
else
  echo "❌ Some tests failed"
  grep "Test Case.*failed" test_output.log
fi

# Count tests
TEST_COUNT=$(grep -c "Test Case.*passed" test_output.log)
echo ""
echo "Test Count: $TEST_COUNT"

# Check execution time
TOTAL_TIME=$(grep "Test Suite.*seconds" test_output.log | tail -1 | awk '{print $(NF-1)}')
echo "Total Time: ${TOTAL_TIME}s"

# Check coverage
COVERAGE=$(xcrun xccov view --report TestResults.xcresult | grep "PayBack.app" | awk '{print $NF}')
echo "Coverage: $COVERAGE"

# Check thresholds
COVERAGE_NUM=$(echo $COVERAGE | sed 's/%//')
if (( $(echo "$COVERAGE_NUM < 70" | bc -l) )); then
  echo "⚠️  Coverage below 70% threshold"
fi

if (( $(echo "$TOTAL_TIME > 15" | bc -l) )); then
  echo "⚠️  Execution time above 15s threshold"
fi

echo ""
echo "=== End Health Check ==="
```

### Weekly Metrics Report

Create a script to generate weekly metrics:

```bash
#!/bin/bash
# scripts/weekly-metrics.sh

echo "=== Weekly Test Metrics Report ==="
echo "Week of: $(date)"
echo ""

# Run tests multiple times to check for flakiness
echo "Running flakiness check (5 runs)..."
FLAKY_TESTS=""
for i in {1..5}; do
  xcodebuild test \
    -project PayBack.xcodeproj \
    -scheme PayBack \
    -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
    > "test_run_$i.log" 2>&1
done

# Analyze flakiness
FLAKY_TESTS=$(grep -h "Test Case.*failed" test_run_*.log | sort | uniq -c | awk '$1 < 5 {print $0}')

if [ -z "$FLAKY_TESTS" ]; then
  echo "✅ No flaky tests detected"
else
  echo "⚠️  Flaky tests detected:"
  echo "$FLAKY_TESTS"
fi

# Generate coverage report
xcodebuild test \
  -project PayBack.xcodeproj \
  -scheme PayBack \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -enableCodeCoverage YES \
  -resultBundlePath TestResults.xcresult \
  > /dev/null 2>&1

# Export metrics
echo ""
echo "=== Metrics ==="
echo "Test Count: $(grep -c "Test Case.*passed" test_run_1.log)"
echo "Coverage: $(xcrun xccov view --report TestResults.xcresult | grep "PayBack.app" | awk '{print $NF}')"
echo "Execution Time: $(grep "Test Suite.*seconds" test_run_1.log | tail -1 | awk '{print $(NF-1)}')s"

# Cleanup
rm test_run_*.log

echo ""
echo "=== End Weekly Report ==="
```

## Dashboard and Reporting

### Metrics Dashboard

Create a simple dashboard to visualize metrics over time:

**Recommended Approach:**
1. Export metrics to CSV files
2. Use a spreadsheet tool (Excel, Google Sheets) to create charts
3. Track trends over time

**Key Charts:**
- Test count over time (line chart)
- Execution time over time (line chart)
- Coverage by module (bar chart)
- Coverage trend (line chart)
- Flaky test count (bar chart)

### CI/CD Reporting

**GitHub Actions Integration:**

The CI workflow already reports:
- ✅ Test pass/fail status
- ✅ Coverage percentage
- ✅ Sanitizer violations

**Additional Reporting:**

Add to `.github/workflows/ci.yml`:

```yaml
- name: Generate Test Report
  if: always()
  run: |
    # Generate JUnit XML report
    xcodebuild test ... | xcpretty --report junit
    
- name: Upload Test Results
  if: always()
  uses: actions/upload-artifact@v3
  with:
    name: test-results
    path: build/reports/junit.xml
    
- name: Publish Test Report
  if: always()
  uses: dorny/test-reporter@v1
  with:
    name: Test Results
    path: build/reports/junit.xml
    reporter: java-junit
```

## Alerting and Notifications

### When to Alert

Set up alerts for:

1. **Test Failures** - Any test failure in main branch
2. **Coverage Drop** - Coverage drops below 70%
3. **Slow Tests** - Execution time exceeds 20s
4. **Flaky Tests** - Same test fails intermittently
5. **Sanitizer Violations** - Thread or address sanitizer detects issues

### How to Alert

**GitHub Actions:**
- Use GitHub Actions notifications
- Post to Slack/Discord via webhooks
- Send email notifications

**Example Slack Notification:**

```yaml
- name: Notify Slack on Failure
  if: failure()
  uses: slackapi/slack-github-action@v1
  with:
    payload: |
      {
        "text": "❌ Tests failed in PayBack",
        "blocks": [
          {
            "type": "section",
            "text": {
              "type": "mrkdwn",
              "text": "*Tests Failed*\nBranch: ${{ github.ref }}\nCommit: ${{ github.sha }}"
            }
          }
        ]
      }
  env:
    SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
```

## Best Practices

### 1. Regular Monitoring

- ✅ Check test health daily
- ✅ Review metrics weekly
- ✅ Analyze trends monthly
- ✅ Update baselines quarterly

### 2. Proactive Maintenance

- ✅ Fix flaky tests immediately
- ✅ Optimize slow tests regularly
- ✅ Add tests for new features
- ✅ Remove obsolete tests

### 3. Team Communication

- ✅ Share metrics with team
- ✅ Discuss trends in retrospectives
- ✅ Celebrate improvements
- ✅ Address concerns promptly

### 4. Continuous Improvement

- ✅ Set goals for metrics
- ✅ Track progress toward goals
- ✅ Experiment with new approaches
- ✅ Learn from failures

## Troubleshooting

### High Execution Time

**Symptoms:** Tests take longer than expected

**Diagnosis:**
```bash
# Profile tests to find slow ones
xcodebuild test ... -enableCodeCoverage YES -resultBundlePath TestResults.xcresult
xcrun xcresulttool get --path TestResults.xcresult --format json | \
  jq '.actions[].actionResult.testsRef.id._value' | \
  xargs -I {} xcrun xcresulttool get --path TestResults.xcresult --id {} --format json | \
  jq '.summaries.values[].tests[] | {name: .name, duration: .duration}' | \
  jq -s 'sort_by(.duration) | reverse | .[0:10]'
```

**Solutions:**
- Move slow tests to performance suite
- Optimize test setup/teardown
- Use parallel test execution
- Mock expensive operations

### Low Coverage

**Symptoms:** Coverage below target

**Diagnosis:**
```bash
# Find files with low coverage
xcrun xccov view --report TestResults.xcresult | grep -E "^\s+[0-9]" | awk '$NF < 70 {print $0}'
```

**Solutions:**
- Add tests for uncovered code
- Remove dead code
- Focus on critical paths first

### Flaky Tests

**Symptoms:** Tests fail intermittently

**Diagnosis:**
```bash
# Run tests multiple times
for i in {1..20}; do xcodebuild test ... > "run_$i.log" 2>&1; done
grep -h "Test Case.*failed" run_*.log | sort | uniq -c
```

**Solutions:**
- Use fixed seeds for random tests
- Use MockClock for time-based tests
- Add proper async/await handling
- Increase timeouts if needed
- Quarantine flaky tests until fixed

## Resources

### Documentation
- [Xcode Testing Documentation](https://developer.apple.com/documentation/xctest)
- [Code Coverage in Xcode](https://developer.apple.com/documentation/xcode/code-coverage)
- [CI/CD Setup](CI-CD-SETUP.md)

### Tools
- [xcpretty](https://github.com/xcpretty/xcpretty)
- [Slather](https://github.com/SlatherOrg/slather)
- [Codecov](https://codecov.io)

### Internal Documentation
- [Test Suite README](README.md)
- [Test Requirements Mapping](TEST_REQUIREMENTS_MAPPING.md)

## Conclusion

Effective test monitoring ensures the test suite remains healthy, fast, and reliable. By tracking key metrics and responding to trends proactively, we can maintain high confidence in our test coverage and catch issues before they reach production.

Remember: **Metrics are tools, not goals.** Focus on meaningful improvements that enhance code quality and developer productivity.
