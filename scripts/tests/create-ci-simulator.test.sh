#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$PROJECT_ROOT/scripts/create-ci-simulator.sh"
FAKE_XCRUN="$PROJECT_ROOT/scripts/tests/fixtures/fake-xcrun.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

GITHUB_ENV="$TEST_DIR/github-env" \
	SIMULATOR_NAME="iPhone 17 Pro Max" \
	SIMULATOR_OS="26.5" \
	PAYBACK_XCRUN="$FAKE_XCRUN" \
	FAKE_SIMULATOR_UDID="11111111-2222-3333-4444-555555555555" \
	"$SCRIPT" >"$TEST_DIR/output.txt"

grep -Fqx 'SIMULATOR_UDID=11111111-2222-3333-4444-555555555555' "$TEST_DIR/github-env"
grep -Fqx 'SIMULATOR_DESTINATION=platform=iOS Simulator,id=11111111-2222-3333-4444-555555555555' "$TEST_DIR/github-env"
grep -Fqx 'SIMULATOR_EPHEMERAL=1' "$TEST_DIR/github-env"
grep -Fq 'Created isolated simulator:' "$TEST_DIR/output.txt"

if GITHUB_ENV="$TEST_DIR/missing-runtime-env" \
	SIMULATOR_NAME="iPhone 17 Pro Max" \
	SIMULATOR_OS="27.0" \
	PAYBACK_XCRUN="$FAKE_XCRUN" \
	"$SCRIPT" >/dev/null 2>&1; then
	echo "Missing runtimes must fail simulator creation" >&2
	exit 1
fi

echo "CI simulator creation checks passed"
