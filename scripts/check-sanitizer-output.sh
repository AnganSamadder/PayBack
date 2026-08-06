#!/bin/bash

set -euo pipefail

SANITIZER="${1:?Usage: check-sanitizer-output.sh <none|thread|address> <log-file>}"
LOG_FILE="${2:?Usage: check-sanitizer-output.sh <none|thread|address> <log-file>}"

if [ ! -f "$LOG_FILE" ]; then
	echo "Sanitizer log not found: $LOG_FILE" >&2
	exit 2
fi

case "$SANITIZER" in
none)
	exit 0
	;;
thread)
	PATTERN='WARNING: ThreadSanitizer|SUMMARY: ThreadSanitizer'
	;;
address)
	PATTERN='ERROR: AddressSanitizer|SUMMARY: AddressSanitizer'
	;;
*)
	echo "Unsupported sanitizer: $SANITIZER" >&2
	exit 2
	;;
esac

if grep -E "$PATTERN" "$LOG_FILE"; then
	echo "Sanitizer diagnostics detected in $LOG_FILE" >&2
	exit 1
fi
