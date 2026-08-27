#!/bin/bash

set -euo pipefail

: "${SIMULATOR_NAME:?SIMULATOR_NAME must be set}"
: "${SIMULATOR_OS:?SIMULATOR_OS must be set}"
: "${GITHUB_ENV:?GITHUB_ENV must be set}"

XCRUN_BIN="${PAYBACK_XCRUN:-xcrun}"

DEVICE_TYPES_JSON="$($XCRUN_BIN simctl list devicetypes --json)"
DEVICE_TYPE_ID="$({
	printf '%s' "$DEVICE_TYPES_JSON"
} | SIMULATOR_NAME="$SIMULATOR_NAME" python3 -c '
import json
import os
import sys

data = json.load(sys.stdin)
name = os.environ["SIMULATOR_NAME"]
for device_type in data.get("devicetypes", []):
    if device_type.get("name") == name and device_type.get("identifier"):
        print(device_type["identifier"])
        break
else:
    sys.exit(1)
')"

RUNTIMES_JSON="$($XCRUN_BIN simctl list runtimes --json)"
RUNTIME_ID="$({
	printf '%s' "$RUNTIMES_JSON"
} | SIMULATOR_OS="$SIMULATOR_OS" python3 -c '
import json
import os
import sys

data = json.load(sys.stdin)
version = os.environ["SIMULATOR_OS"]
for runtime in data.get("runtimes", []):
    if (
        runtime.get("version") == version
        and runtime.get("isAvailable", True)
        and runtime.get("identifier")
    ):
        print(runtime["identifier"])
        break
else:
    sys.exit(1)
')"

RUN_LABEL="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${RANDOM}"
CI_SIMULATOR_NAME="PayBack CI ${RUN_LABEL}"
SIMULATOR_UDID="$($XCRUN_BIN simctl create "$CI_SIMULATOR_NAME" "$DEVICE_TYPE_ID" "$RUNTIME_ID")"

if [ -z "$SIMULATOR_UDID" ]; then
	echo "ERROR: simctl create returned an empty simulator UDID" >&2
	exit 1
fi

{
	echo "SIMULATOR_UDID=$SIMULATOR_UDID"
	echo "SIMULATOR_DESTINATION=platform=iOS Simulator,id=$SIMULATOR_UDID"
	echo "SIMULATOR_EPHEMERAL=1"
} >>"$GITHUB_ENV"

echo "Created isolated simulator: $CI_SIMULATOR_NAME ($SIMULATOR_UDID)"
