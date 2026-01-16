# PayBack Scripts

Helper scripts for local development and CI.

## Scripts

- `setup-git-hooks.sh`: Installs git hooks for local workflows (optional).
- `test-ci-locally.sh`: Runs tests with CI parity. Supports multiple modes:
  - Default: GitHub Actions-style test run
  - `CI_FLAVOR=xcodecloud`: XcodeCloud parity mode with build-for-testing flow
- `test-with-coverage.sh`: Runs tests with code coverage and writes `coverage.json` + `coverage-report.txt`.

## Running Tests Locally

```bash
# Generate/regenerate Xcode project
xcodegen generate

# Run tests (simple)
xcodebuild -scheme PayBack -destination "platform=iOS Simulator,name=iPhone 16" test

# Run tests with CI parity
./scripts/test-ci-locally.sh

# Run with XcodeCloud parity mode
CI_FLAVOR=xcodecloud ./scripts/test-ci-locally.sh
```

## Convex Backend

The app uses Convex as its backend. Backend functions are in the `convex/` directory.

To deploy backend changes locally:
```bash
npx convex deploy
```

For CI/XcodeCloud deployment, set these environment variables:
- `CONVEX_DEPLOY_KEY`: Convex deploy key (secret)
- `CONVEX_DEPLOY_ON_CI=1`: Safety switch to enable deploy from CI
