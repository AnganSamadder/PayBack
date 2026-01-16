#!/bin/sh
# Runs tests and emits coverage report (coverage.json + coverage-report.txt).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DEST="platform=iOS Simulator,name=iPhone 16"
DERIVED_DATA="$REPO_ROOT/build/CoverageDerived"

echo "Running tests with coverage..."
xcodebuild -scheme PayBack -destination "$DEST" -derivedDataPath "$DERIVED_DATA" -enableCodeCoverage YES test

XCRESULT=$(find "$DERIVED_DATA/Logs/Test" -name "*.xcresult" | sort | tail -n 1)
if [ -z "$XCRESULT" ]; then
	echo "xcresult not found; cannot compute coverage."
	exit 1
fi

echo "Generating coverage reports..."
xcrun xccov view --report --json "$XCRESULT" >coverage.json
xcrun xccov view --report "$XCRESULT" >coverage-report.txt
echo "Coverage reports written to coverage.json and coverage-report.txt"
