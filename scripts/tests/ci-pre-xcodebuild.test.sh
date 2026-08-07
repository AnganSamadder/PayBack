#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

TEST_ROOT="$TEMP_DIR/repository"
TEST_BIN="$TEMP_DIR/bin"
mkdir -p "$TEST_ROOT/ci_scripts/bin" "$TEST_BIN"
cp "$PROJECT_ROOT/ci_scripts/ci_pre_xcodebuild.sh" "$TEST_ROOT/ci_scripts/"

printf '%s\n' \
	'settings:' \
	'  base:' \
	'    MARKETING_VERSION: 0.1.1' \
	'    CURRENT_PROJECT_VERSION: 96' >"$TEST_ROOT/project.yml"

printf '%s\n' \
	'#!/bin/sh' \
	'echo "XcodeGen must not run during Xcode Cloud builds" >&2' \
	'exit 1' >"$TEST_BIN/bunx"
printf '%s\n' \
	'#!/bin/sh' \
	'exit 0' >"$TEST_BIN/xcrun"
printf '%s\n' \
	'#!/bin/sh' \
	'exit 0' >"$TEST_ROOT/ci_scripts/bin/xcodebuild"
chmod +x "$TEST_BIN/bunx" "$TEST_BIN/xcrun" "$TEST_ROOT/ci_scripts/bin/xcodebuild"

run_prebuild() {
	local tag="$1"
	local output_file="$2"
	env -u CI_PRIMARY_REPOSITORY_PATH \
		PATH="$TEST_BIN:$PATH" \
		CI_TAG="$tag" \
		CI_BUILD_NUMBER="123" \
		CI_WORKFLOW="Beta Release" \
		CI_XCODE_PROJECT="PayBack.xcodeproj" \
		CI_XCODE_SCHEME="PayBack" \
		CI_XCODEBUILD_ACTION="archive" \
		CI_PRODUCT_PLATFORM="iOS" \
		bash "$TEST_ROOT/ci_scripts/ci_pre_xcodebuild.sh" >"$output_file" 2>&1
}

OUTPUT_FILE="$TEMP_DIR/output.log"
if ! run_prebuild "beta-0.1.1" "$OUTPUT_FILE"; then
	sed -n '1,120p' "$OUTPUT_FILE" >&2
	exit 1
fi
grep -q 'MARKETING_VERSION: 0.1.1' "$TEST_ROOT/project.yml"
grep -q 'CURRENT_PROJECT_VERSION: 96' "$TEST_ROOT/project.yml"
grep -q '^ci_pre_xcodebuild.sh complete$' "$OUTPUT_FILE"

MISMATCH_OUTPUT="$TEMP_DIR/mismatch-output.log"
if run_prebuild "beta-0.1.2" "$MISMATCH_OUTPUT"; then
	echo "Expected a mismatched release tag to fail" >&2
	exit 1
fi
grep -q 'does not match project.yml' "$MISMATCH_OUTPUT"

echo "Xcode Cloud pre-build checks passed"
