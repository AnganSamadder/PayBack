#!/bin/sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$SCRIPT_DIR/.." && pwd)}"

if [ "${CONVEX_DEPLOY_ON_CI:-}" != "1" ]; then
	echo "error: Production Convex deployment is disabled." >&2
	exit 1
fi
if [ -z "${CONVEX_DEPLOY_KEY:-}" ]; then
	echo "error: CONVEX_DEPLOY_KEY is required for a production release." >&2
	exit 1
fi

"$REPOSITORY_ROOT/ci_scripts/prepare_convex_deploy.sh"

echo "Deploying the locked Convex backend before the iOS archive..."
cd "$REPOSITORY_ROOT"
"$REPOSITORY_ROOT/.convex-ci/node_modules/.bin/convex" deploy -y
echo "Convex backend deployment completed."
