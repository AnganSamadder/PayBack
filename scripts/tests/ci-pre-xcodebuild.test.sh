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
	'    MARKETING_VERSION: 0.1.0' \
	'    CURRENT_PROJECT_VERSION: 96' >"$TEST_ROOT/project.yml"

printf '%s\n' \
	'#!/bin/sh' \
	'printf "%s\n" "$*" >"$TEST_XCODEGEN_ARGS"' >"$TEST_BIN/bunx"
printf '%s\n' \
	'#!/bin/sh' \
	'exit 0' >"$TEST_BIN/xcrun"
printf '%s\n' \
	'#!/bin/sh' \
	'exit 0' >"$TEST_ROOT/ci_scripts/bin/xcodebuild"
chmod +x "$TEST_BIN/bunx" "$TEST_BIN/xcrun" "$TEST_ROOT/ci_scripts/bin/xcodebuild"

OUTPUT_FILE="$TEMP_DIR/output.log"
env -u CI_PRIMARY_REPOSITORY_PATH \
	PATH="$TEST_BIN:$PATH" \
	TEST_XCODEGEN_ARGS="$TEMP_DIR/xcodegen-args.txt" \
	CI_TAG="beta-0.1.1" \
	CI_BUILD_NUMBER="123" \
	CI_WORKFLOW="Beta Release" \
	CI_XCODE_PROJECT="PayBack.xcodeproj" \
	CI_XCODE_SCHEME="PayBack" \
	CI_XCODEBUILD_ACTION="archive" \
	CI_PRODUCT_PLATFORM="iOS" \
	bash "$TEST_ROOT/ci_scripts/ci_pre_xcodebuild.sh" >"$OUTPUT_FILE"

grep -q 'MARKETING_VERSION: 0.1.1' "$TEST_ROOT/project.yml"
grep -q 'CURRENT_PROJECT_VERSION: 123' "$TEST_ROOT/project.yml"
grep -q '^xcodegen generate --spec project.yml$' "$TEMP_DIR/xcodegen-args.txt"
grep -q '^ci_pre_xcodebuild.sh complete$' "$OUTPUT_FILE"

echo "Xcode Cloud pre-build checks passed"
