# PayBack Test Scripts

This directory contains scripts for testing and development workflow.

## Available Scripts

### `test-ci-locally.sh` ⭐ **Main Test Script**

The comprehensive test script that replicates the GitHub Actions CI environment locally.

**Usage:**
```bash
./scripts/test-ci-locally.sh
```

**Features:**
- ✅ Automatically generates Firebase config for testing (uses dummy plist + emulators)
- ✅ Selects the best available iOS simulator
- ✅ Runs complete test suite with coverage
- ✅ Separates functional code coverage from UI code coverage
- ✅ Generates detailed coverage reports
- ✅ Color-coded output showing test results
- ✅ Identifies files needing coverage improvement

**Note:** This script uses the dummy `GoogleService-Info.plist` and Firebase emulators. It does not require production Firebase credentials.

**Output:**
- `test_output.log` - Full test output
- `TestResults.xcresult` - Xcode test results bundle
- `coverage.json` - JSON coverage data
- `coverage-report.txt` - Detailed coverage breakdown by feature

**Exit Codes:**
- `0` - All tests passed
- `1` - Tests failed or coverage below target

---

### `setup-git-hooks.sh`

Installs git hooks for running tests before commits (optional).

**Usage:**
```bash
./scripts/setup-git-hooks.sh
```

---

## Quick Reference

### Run all tests with coverage
```bash
./scripts/test-ci-locally.sh
```

### Run tests with Thread Sanitizer (detect data races)
```bash
SANITIZER=thread ./scripts/test-ci-locally.sh
```

### Run tests with Address Sanitizer (detect memory issues)
```bash
SANITIZER=address ./scripts/test-ci-locally.sh
```

### View coverage details after test run
```bash
cat coverage-report.txt
```

### Open test results in Xcode
```bash
open TestResults.xcresult
```

---

## Coverage Targets

- **Functional Code** (Services, Models, Business Logic): 90%
- **UI Code** (Views, Coordinators): 40%
- **Overall Target** (Weighted): ~65%

The test script automatically categorizes code and tracks coverage separately for functional vs. UI code, since UI code is harder to unit test effectively.

---

## Troubleshooting

### Tests won't run
1. Make sure Xcode is installed and xcodebuild is available
2. Check that you have an iOS simulator available
3. Run `xcodegen` to regenerate the project if needed

### Coverage report not generated
The script requires the test results bundle. Make sure tests complete successfully first.

### Simulator not found
The script will automatically select the best available iPhone simulator. If none are available, install one through Xcode preferences.
