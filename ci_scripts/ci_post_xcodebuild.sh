#!/bin/sh
# ============================================================================
# Xcode Cloud Post-Build Script
# Runs after xcodebuild completes (success or failure)
# ============================================================================

set -e

echo "=== CI Post-Build Script ==="
echo "CI_XCODEBUILD_EXIT_CODE: ${CI_XCODEBUILD_EXIT_CODE:-unknown}"
echo "CI_TAG: ${CI_TAG:-none}"
echo "CI_BUILD_NUMBER: ${CI_BUILD_NUMBER:-none}"

# ----------------------------------------------------------------------------
# Exit early if build failed
# ----------------------------------------------------------------------------
if [[ "$CI_XCODEBUILD_EXIT_CODE" != "0" ]]; then
	echo "Build failed with exit code $CI_XCODEBUILD_EXIT_CODE"
	exit $CI_XCODEBUILD_EXIT_CODE
fi

# ----------------------------------------------------------------------------
# TestFlight Notes Generation
# When a signed app is produced (archive success), generate TestFlight notes
# from git commit history.
# ----------------------------------------------------------------------------

if [[ -n "$CI_APP_STORE_SIGNED_APP_PATH" ]]; then
	echo "Signed app created at: $CI_APP_STORE_SIGNED_APP_PATH"

	# Create TestFlight directory for release notes
	TESTFLIGHT_DIR="$CI_PRIMARY_REPOSITORY_PATH/TestFlight"
	mkdir -p "$TESTFLIGHT_DIR"

	# Extract version info
	if [[ -n "$CI_TAG" ]]; then
		VERSION=$(echo "$CI_TAG" | sed -E 's/^(alpha|beta|release|prod)-//')
		TAG_TYPE=$(echo "$CI_TAG" | sed -E 's/-.*$//')
	else
		VERSION="${CI_BUILD_NUMBER:-unknown}"
		TAG_TYPE="main"
	fi

	# Generate release notes from recent commits
	{
		echo "Build $VERSION ($CI_BUILD_NUMBER)"
		echo ""
		echo "Type: $TAG_TYPE"
		echo ""
		echo "Recent changes:"
		echo "────────────────"

		# Get commits since last tag (or last 10 if no previous tag)
		if [[ -n "$CI_TAG" ]]; then
			PREVIOUS_TAG=$(git tag --sort=-creatordate 2>/dev/null | grep -v "^$CI_TAG$" | head -n1)
			if [[ -n "$PREVIOUS_TAG" ]]; then
				echo "Changes since $PREVIOUS_TAG:"
				git log --oneline --no-merges "$PREVIOUS_TAG..$CI_TAG" 2>/dev/null || git log --oneline --no-merges -10
			else
				echo "Initial release"
				git log --oneline --no-merges -10
			fi
		else
			git log --oneline --no-merges -10
		fi
	} >"$TESTFLIGHT_DIR/WhatToTest.en-US.txt"

	echo "Generated TestFlight notes:"
	cat "$TESTFLIGHT_DIR/WhatToTest.en-US.txt"

	# Copy for other locales if you support them
	# cp "$TESTFLIGHT_DIR/WhatToTest.en-US.txt" "$TESTFLIGHT_DIR/WhatToTest.es-ES.txt"
fi

# ----------------------------------------------------------------------------
# Deployment Summary
# ----------------------------------------------------------------------------
if [[ -n "$CI_TAG" ]]; then
	echo ""
	echo "========================================="
	echo "RELEASE SUMMARY"
	echo "========================================="
	echo "Tag: $CI_TAG"
	echo "Build Number: $CI_BUILD_NUMBER"
	echo "Workflow: $CI_WORKFLOW"
	echo "Scheme: ${CI_XCODE_SCHEME:-unknown}"

	if [[ "$CI_TAG" == alpha-* ]]; then
		echo "Deployment: TestFlight Internal Testing"
		echo "Convex DB: Development"
	elif [[ "$CI_TAG" == beta-* ]]; then
		echo "Deployment: TestFlight External Testing"
		echo "Convex DB: Production"
	elif [[ "$CI_TAG" == release-* ]] || [[ "$CI_TAG" == prod-* ]]; then
		echo "Deployment: App Store"
		echo "Convex DB: Production"
	fi
	echo "========================================="
fi

echo "=== Post-Build Script Complete ==="
