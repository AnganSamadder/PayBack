# Local CI Testing Guide

This guide shows you how to test your CI pipeline locally before pushing to GitHub.

## Quick Start

### Run all tests (default - no sanitizer):
```bash
./scripts/test-ci-locally.sh
```

### Run with Thread Sanitizer:
```bash
SANITIZER=thread ./scripts/test-ci-locally.sh
```

### Run with Address Sanitizer:
```bash
SANITIZER=address ./scripts/test-ci-locally.sh
```

### Specify iOS runtime version:
```bash
REQUIRED_IOS_RUNTIME=26.0 ./scripts/test-ci-locally.sh
```

## What the Script Does

The script replicates the exact steps from `.github/workflows/ci.yml`:

1. ✅ Creates dummy `GoogleService-Info.plist` (same as CI)
2. ✅ Shows Xcode version
3. ✅ Checks iOS runtime availability
4. ✅ Cleans unavailable simulators
5. ✅ Installs xcpretty (if needed)
6. ✅ Resolves package dependencies
7. ✅ Selects appropriate iPhone simulator (same Python logic as CI)
8. ✅ Boots the simulator
9. ✅ Runs tests with specified sanitizer
10. ✅ Generates coverage report (when SANITIZER=none)

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SANITIZER` | `none` | Sanitizer to use: `none`, `thread`, or `address` |
| `REQUIRED_IOS_RUNTIME` | `26.0` | iOS runtime version to check for |
| `PREFERRED_IOS_MAJOR` | `26` | Preferred iOS major version |

## Examples

### Test everything before pushing:
```bash
# Run standard tests
./scripts/test-ci-locally.sh

# Run thread sanitizer tests
SANITIZER=thread ./scripts/test-ci-locally.sh

# Run address sanitizer tests
SANITIZER=address ./scripts/test-ci-locally.sh
```

### Check coverage only:
```bash
./scripts/test-ci-locally.sh
# Coverage report will be in: coverage-report.txt
```

### Quick test (no sanitizers):
```bash
./scripts/test-ci-locally.sh
```

## Output Files

After running the script, you'll find:

- `TestResults.xcresult` - Full test results bundle
- `coverage.json` - Coverage data in JSON format (if SANITIZER=none)
- `coverage-report.txt` - Human-readable coverage report (if SANITIZER=none)
- `iOS/GoogleService-Info.plist` - Dummy Firebase config (auto-created)

## Comparing with GitHub Actions

The script uses the **exact same**:
- GoogleService-Info.plist content
- Simulator selection logic (Python script)
- xcodebuild commands
- Environment variables
- Coverage threshold (70%)

This means if tests pass locally, they should pass on GitHub Actions.

## Troubleshooting

### "iOS runtime not available"
Install the required runtime:
```bash
xcodebuild -downloadPlatform iOS -buildVersion 26.0
```

### "xcpretty not found"
The script will auto-install it, but you can install manually:
```bash
sudo gem install xcpretty --no-document
```

### "Simulator won't boot"
Kill all simulator processes:
```bash
killall Simulator
killall simctl
xcrun simctl shutdown all
```

Then try again.

### Tests fail locally but pass on CI (or vice versa)
Check:
1. Xcode version matches CI (see `.github/workflows/ci.yml`)
2. iOS runtime version matches
3. All dependencies are resolved
4. Simulator is fully booted

## CI Matrix Testing

To replicate the full CI matrix locally:

```bash
# Test with no sanitizer
SANITIZER=none ./scripts/test-ci-locally.sh

# Test with thread sanitizer
SANITIZER=thread ./scripts/test-ci-locally.sh

# Test with address sanitizer
SANITIZER=address ./scripts/test-ci-locally.sh
```

## Benefits

✅ **Fast iteration** - No need to push to GitHub to test CI changes  
✅ **Exact replication** - Uses same steps as GitHub Actions  
✅ **Cost savings** - Doesn't consume GitHub Actions minutes  
✅ **Debugging** - Can easily inspect local test results  
✅ **Confidence** - Know tests will pass before pushing  

## Integration with Git Workflow

Add this to your pre-push workflow:

```bash
# In .git/hooks/pre-push
#!/bin/bash
echo "Running local CI tests..."
./scripts/test-ci-locally.sh || {
    echo "❌ Tests failed. Push cancelled."
    exit 1
}
echo "✅ Tests passed. Proceeding with push."
```

Make it executable:
```bash
chmod +x .git/hooks/pre-push
```
