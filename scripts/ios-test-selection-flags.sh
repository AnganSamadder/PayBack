#!/bin/bash

set -euo pipefail

SANITIZER="${1:?Usage: ios-test-selection-flags.sh <none|thread|address>}"

case "$SANITIZER" in
	none | address)
		;;
	thread)
		printf '%s' \
			'-skip-testing:PayBackTests/FilteringPerformanceTests ' \
			'-skip-testing:PayBackTests/MemoryUsageTests ' \
			'-skip-testing:PayBackTests/ReconciliationPerformanceTests ' \
			'-skip-testing:PayBackTests/SplitCalculationPerformanceTests'
		;;
	*)
		echo "Unsupported sanitizer: $SANITIZER" >&2
		exit 1
		;;
esac
