#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="$PROJECT_ROOT/scripts/check-sanitizer-output.sh"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

expect_success() {
	local sanitizer="$1"
	local contents="$2"
	local log_file="$TEMP_DIR/${sanitizer}-clean.log"
	printf '%s\n' "$contents" >"$log_file"
	"$CHECKER" "$sanitizer" "$log_file"
}

expect_failure() {
	local sanitizer="$1"
	local contents="$2"
	local log_file="$TEMP_DIR/${sanitizer}-failure.log"
	printf '%s\n' "$contents" >"$log_file"
	if "$CHECKER" "$sanitizer" "$log_file" >"$TEMP_DIR/checker-output.log" 2>&1; then
		echo "Expected $sanitizer diagnostics to fail" >&2
		exit 1
	fi
}

expect_success none "Test Suite 'PayBackTests' passed"
expect_success thread "Test Suite 'PayBackCITests' passed"
expect_success address "Test Suite 'PayBackTests' passed"
expect_failure thread "WARNING: ThreadSanitizer: thread leak"
expect_failure thread "SUMMARY: ThreadSanitizer: data race"
expect_failure address "ERROR: AddressSanitizer: heap-use-after-free"
expect_failure address "SUMMARY: AddressSanitizer: heap-use-after-free"
if "$CHECKER" none "$TEMP_DIR/missing.log" >"$TEMP_DIR/checker-output.log" 2>&1; then
	echo "Expected a missing sanitizer log to fail" >&2
	exit 1
fi

echo "Sanitizer output checks passed"
