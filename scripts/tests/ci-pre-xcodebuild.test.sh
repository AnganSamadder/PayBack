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
	'echo "Simulator tooling is unavailable before the Test action" >&2' \
	'exit 1' >"$TEST_BIN/xcrun"
printf '%s\n' \
	'#!/bin/sh' \
	'exit 0' >"$TEST_ROOT/ci_scripts/bin/xcodebuild"
printf '%s\n' \
	'#!/bin/sh' \
	'set -eu' \
	'printf "%s\n" "deployed" >>"$FAKE_DEPLOY_LOG"' >"$TEST_ROOT/ci_scripts/deploy_convex_backend.sh"
chmod +x \
	"$TEST_BIN/bunx" \
	"$TEST_BIN/xcrun" \
	"$TEST_ROOT/ci_scripts/bin/xcodebuild" \
	"$TEST_ROOT/ci_scripts/deploy_convex_backend.sh"

run_prebuild() {
	local tag="$1"
	local action="$2"
	local output_file="$3"
	local deploy_on_ci="${4:-}"
	local deploy_key="${5:-}"
	env -u CI_PRIMARY_REPOSITORY_PATH -u CI_BUILD_NUMBER \
		PATH="$TEST_BIN:$PATH" \
		FAKE_DEPLOY_LOG="$TEMP_DIR/deploy.log" \
		CONVEX_DEPLOY_ON_CI="$deploy_on_ci" \
		CONVEX_DEPLOY_KEY="$deploy_key" \
		CI_TAG="$tag" \
		CI_WORKFLOW="Beta Release" \
		CI_XCODE_PROJECT="PayBack.xcodeproj" \
		CI_XCODE_SCHEME="PayBack" \
		CI_XCODEBUILD_ACTION="$action" \
		CI_PRODUCT_PLATFORM="iOS" \
		sh "$TEST_ROOT/ci_scripts/ci_pre_xcodebuild.sh" >"$output_file" 2>&1
}

OUTPUT_FILE="$TEMP_DIR/output.log"
if ! run_prebuild "beta-0.1.1" "test" "$OUTPUT_FILE"; then
	sed -n '1,120p' "$OUTPUT_FILE" >&2
	exit 1
fi
grep -q 'MARKETING_VERSION: 0.1.1' "$TEST_ROOT/project.yml"
grep -q 'CURRENT_PROJECT_VERSION: 96' "$TEST_ROOT/project.yml"
grep -q '^ci_pre_xcodebuild.sh complete$' "$OUTPUT_FILE"

ARCHIVE_OUTPUT="$TEMP_DIR/archive-output.log"
if ! run_prebuild "beta-0.1.1" "archive" "$ARCHIVE_OUTPUT" "1" "prod-key"; then
	sed -n '1,120p' "$ARCHIVE_OUTPUT" >&2
	exit 1
fi
grep -q 'project.yml already contains release version 0.1.1' "$ARCHIVE_OUTPUT"
grep -q '^deployed$' "$TEMP_DIR/deploy.log"

MISSING_DEPLOY_OUTPUT="$TEMP_DIR/missing-deploy-output.log"
if run_prebuild "beta-0.1.1" "archive" "$MISSING_DEPLOY_OUTPUT"; then
	echo "Expected a beta Archive without a production backend deploy to fail" >&2
	exit 1
fi
grep -q 'requires CONVEX_DEPLOY_ON_CI=1' "$MISSING_DEPLOY_OUTPUT"

TEST_MISMATCH_OUTPUT="$TEMP_DIR/test-mismatch-output.log"
if ! run_prebuild "beta-0.1.2" "test" "$TEST_MISMATCH_OUTPUT"; then
	echo "Expected Test pre-build to skip archive-only version validation" >&2
	exit 1
fi
grep -q 'Skipping archive-only release validation' "$TEST_MISMATCH_OUTPUT"

ARCHIVE_MISMATCH_OUTPUT="$TEMP_DIR/archive-mismatch-output.log"
if run_prebuild "beta-0.1.2" "archive" "$ARCHIVE_MISMATCH_OUTPUT"; then
	echo "Expected a mismatched Archive release tag to fail" >&2
	exit 1
fi
grep -q 'does not match project.yml' "$ARCHIVE_MISMATCH_OUTPUT"

echo "Xcode Cloud pre-build checks passed"
