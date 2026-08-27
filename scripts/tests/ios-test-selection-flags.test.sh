#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FLAGS_SCRIPT="$PROJECT_ROOT/scripts/ios-test-selection-flags.sh"
WORKFLOW="$PROJECT_ROOT/.github/workflows/ci.yml"
LOCAL_PARITY_SCRIPT="$PROJECT_ROOT/scripts/test-ci-locally.sh"

assert_equals() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	if [ "$actual" != "$expected" ]; then
		echo "$message" >&2
		echo "Expected: $expected" >&2
		echo "Actual:   $actual" >&2
		exit 1
	fi
}

assert_equals "" "$($FLAGS_SCRIPT none)" "Standard tests must keep performance coverage"
assert_equals "" "$($FLAGS_SCRIPT address)" "ASan must keep performance coverage"

THREAD_FLAGS="$($FLAGS_SCRIPT thread)"
for suite in \
	FilteringPerformanceTests \
	MemoryUsageTests \
	ReconciliationPerformanceTests \
	SplitCalculationPerformanceTests; do
	if [[ "$THREAD_FLAGS" != *"-skip-testing:PayBackTests/$suite"* ]]; then
		echo "TSan flags must skip $suite" >&2
		exit 1
	fi
done

if "$FLAGS_SCRIPT" unsupported > /dev/null 2>&1; then
	echo "Unsupported sanitizers must fail" >&2
	exit 1
fi

grep -Fq "scripts/ios-test-selection-flags.sh" "$WORKFLOW"
grep -Fq "scripts/ios-test-selection-flags.sh" "$LOCAL_PARITY_SCRIPT"
grep -Fq "bash scripts/tests/ios-test-selection-flags.test.sh" "$WORKFLOW"

grep -Fq 'parallel_flag=-parallel-testing-enabled NO' "$WORKFLOW"
if grep -Fq 'parallel_flag=-parallel-testing-enabled YES' "$WORKFLOW"; then
	echo "Hosted iOS tests must not use parallel simulator clones" >&2
	exit 1
fi

grep -Fq "PAYBACK_PARALLEL_TESTING=\"\${PAYBACK_PARALLEL_TESTING:-NO}\"" "$LOCAL_PARITY_SCRIPT"
grep -Fq 'scripts/create-ci-simulator.sh' "$WORKFLOW"
grep -Fq 'Revalidate Isolated Simulator' "$WORKFLOW"

echo "iOS test selection flag checks passed"
