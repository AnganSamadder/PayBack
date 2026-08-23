#!/bin/sh
set -eu

echo "=========================================="
echo "ci_pre_xcodebuild.sh: Pre-build"
echo "=========================================="
echo "CI_TAG: ${CI_TAG:-none}"
echo "CI_BUILD_NUMBER: ${CI_BUILD_NUMBER:-none}"
echo "CI_WORKFLOW: ${CI_WORKFLOW:-none}"

if [ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]; then
	echo "Skipping archive-only release validation for ${CI_XCODEBUILD_ACTION:-unknown} action"
	echo "ci_pre_xcodebuild.sh complete"
	echo "=========================================="
	exit 0
fi

cd "$(dirname "$0")/.."
REPOSITORY_ROOT=$(pwd)

# ----------------------------------------------------------------------------
# Release version validation
# Release tags must match the version committed through project.yml/XcodeGen.
# ----------------------------------------------------------------------------
if [ -n "${CI_TAG:-}" ]; then
	MARKETING_VERSION=$(echo "$CI_TAG" | sed -E 's/^(alpha|beta|release|prod)-//')

	echo "Tag detected: $CI_TAG"
	echo "Marketing Version: $MARKETING_VERSION"
	echo "Xcode Cloud Build Number: ${CI_BUILD_NUMBER:-unset}"

	PROJECT_YML="$REPOSITORY_ROOT/project.yml"
	if [ ! -f "$PROJECT_YML" ]; then
		echo "ERROR: project.yml not found at $PROJECT_YML" >&2
		exit 1
	fi

	CONFIGURED_VERSION=$(awk '$1 == "MARKETING_VERSION:" { print $2; exit }' "$PROJECT_YML" | tr -d '"')
	if [ "$CONFIGURED_VERSION" != "$MARKETING_VERSION" ]; then
		echo "ERROR: Tag version $MARKETING_VERSION does not match project.yml version $CONFIGURED_VERSION" >&2
		exit 1
	fi

	echo "project.yml already contains release version $MARKETING_VERSION"
fi

# ----------------------------------------------------------------------------
# Environment diagnostics
# ----------------------------------------------------------------------------
echo ""
echo "--- Build Environment ---"
echo "CI_XCODE_PROJECT: ${CI_XCODE_PROJECT:-unset}"
echo "CI_XCODE_SCHEME: ${CI_XCODE_SCHEME:-unset}"
echo "CI_XCODEBUILD_ACTION: ${CI_XCODEBUILD_ACTION:-unset}"
echo "CI_BUILD_NUMBER: ${CI_BUILD_NUMBER:-unset}"
echo "CI_WORKFLOW: ${CI_WORKFLOW:-unset}"
echo "CI_PRODUCT_PLATFORM: ${CI_PRODUCT_PLATFORM:-unset}"

# ----------------------------------------------------------------------------
# Convex deployment configuration
# ----------------------------------------------------------------------------
echo ""
echo "--- Convex Configuration ---"
if [ -n "${CONVEX_DEPLOY_KEY:-}" ]; then
	echo "CONVEX_DEPLOY_KEY: set (length=${#CONVEX_DEPLOY_KEY})"
else
	echo "CONVEX_DEPLOY_KEY: NOT SET"
	echo "  Tagged production archives require this Xcode Cloud environment variable."
fi

if [ "${CONVEX_DEPLOY_ON_CI:-}" = "1" ]; then
	echo "CONVEX_DEPLOY_ON_CI: enabled"
else
	echo "CONVEX_DEPLOY_ON_CI: disabled (set to '1' to enable deploy)"
fi

case "${CI_TAG:-}" in
beta-* | release-* | prod-*)
	if [ "${CONVEX_DEPLOY_ON_CI:-}" != "1" ]; then
		echo "ERROR: Production release $CI_TAG requires CONVEX_DEPLOY_ON_CI=1." >&2
		exit 1
	fi
	if [ -z "${CONVEX_DEPLOY_KEY:-}" ]; then
		echo "ERROR: Production release $CI_TAG requires CONVEX_DEPLOY_KEY." >&2
		exit 1
	fi
	"$REPOSITORY_ROOT/ci_scripts/deploy_convex_backend.sh"
	;;
esac

echo ""
echo "ci_pre_xcodebuild.sh complete"
echo "=========================================="
