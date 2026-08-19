#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

TEST_ROOT="$TEMP_DIR/repository"
TEST_BIN="$TEMP_DIR/bin"
mkdir -p "$TEST_ROOT/apps/backend/convex" "$TEST_ROOT/ci_scripts" "$TEST_BIN"
cp "$PROJECT_ROOT/ci_scripts/prepare_convex_deploy.sh" "$TEST_ROOT/ci_scripts/"

printf '%s\n' \
	'{' \
	'  "packages": {' \
	'    "convex": ["convex@1.31.7", "", {}]' \
	'  }' \
	'}' >"$TEST_ROOT/bun.lock"

printf '%s\n' \
	'#!/bin/sh' \
	'set -eu' \
	'prefix=""' \
	'arguments="$*"' \
	'while [ "$#" -gt 0 ]; do' \
	'  if [ "$1" = "--prefix" ]; then' \
	'    prefix="$2"' \
	'    shift 2' \
	'  else' \
	'    shift' \
	'  fi' \
	'done' \
	'printf "%s\n" "$arguments" >"$FAKE_NPM_ARGUMENTS"' \
	'mkdir -p "$prefix/node_modules/convex/dist/cjs/server" "$prefix/node_modules/.bin"' \
	'printf "%s\n" '\''{"exports":{"./server":"./dist/cjs/server/index.js"}}'\'' >"$prefix/node_modules/convex/package.json"' \
	': >"$prefix/node_modules/convex/dist/cjs/server/index.js"' \
	': >"$prefix/node_modules/.bin/convex"' >"$TEST_BIN/npm"
chmod +x "$TEST_BIN/npm"

OUTPUT_FILE="$TEMP_DIR/output.log"
FAKE_NPM_ARGUMENTS="$TEMP_DIR/npm-arguments.log" \
	CI_PRIMARY_REPOSITORY_PATH="$TEST_ROOT" \
	PATH="$TEST_BIN:$PATH" \
	sh "$TEST_ROOT/ci_scripts/prepare_convex_deploy.sh" >"$OUTPUT_FILE" 2>&1

grep -q 'convex@1.31.7' "$TEMP_DIR/npm-arguments.log"
grep -q '^Convex deployment dependencies are ready\.$' "$OUTPUT_FILE"
test -L "$TEST_ROOT/node_modules/convex"
node -e 'require.resolve("convex/server", { paths: [process.argv[1]] })' "$TEST_ROOT/apps/backend/convex"

echo "Convex deployment preparation checks passed"
