#!/bin/bash

set -euo pipefail

case "$*" in
"simctl list devicetypes --json")
	printf '%s\n' '{"devicetypes":[{"name":"iPhone 17 Pro Max","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"}]}'
	;;
"simctl list runtimes --json")
	printf '%s\n' '{"runtimes":[{"version":"26.5","isAvailable":true,"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5"}]}'
	;;
simctl\ create\ *)
	printf '%s\n' "${FAKE_SIMULATOR_UDID:-00000000-0000-0000-0000-000000000001}"
	;;
*)
	echo "Unexpected fake xcrun invocation: $*" >&2
	exit 1
	;;
esac
