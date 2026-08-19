#!/bin/sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$SCRIPT_DIR/.." && pwd)}"
LOCK_FILE="$REPOSITORY_ROOT/bun.lock"
CONVEX_CLI_DIR="$REPOSITORY_ROOT/.convex-ci"

if [ ! -f "$LOCK_FILE" ]; then
	echo "error: bun.lock not found at $LOCK_FILE" >&2
	exit 1
fi

CONVEX_VERSION=$(sed -n 's/^    "convex": \["convex@\([^"]*\)".*/\1/p' "$LOCK_FILE")
if [ -z "$CONVEX_VERSION" ]; then
	echo "error: Could not determine the locked Convex version from $LOCK_FILE" >&2
	exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
	echo "error: npm is required to prepare the Convex CLI on Xcode Cloud" >&2
	exit 1
fi

echo "Installing Convex $CONVEX_VERSION for the production deployment..."
npm install \
	--prefix "$CONVEX_CLI_DIR" \
	--no-save \
	--ignore-scripts \
	"convex@$CONVEX_VERSION"

mkdir -p "$REPOSITORY_ROOT/node_modules"
ln -sfn "$CONVEX_CLI_DIR/node_modules/convex" "$REPOSITORY_ROOT/node_modules/convex"

node -e 'require.resolve("convex/server", { paths: [process.argv[1]] })' "$REPOSITORY_ROOT/apps/backend/convex"
echo "Convex deployment dependencies are ready."
