#!/bin/sh
# =========================================================================
# IMPORTANT: ENABLE_USER_SCRIPT_SANDBOXING must be set to NO in the Xcode
# project settings (Build Settings > User Script Sandboxing) for BOTH Debug
# and Release configurations. Otherwise, this script will fail with:
#   "Command PhaseScriptExecution failed with a nonzero exit code"
# because the sandbox blocks reading .env.supabase.local and writing to
# BUILT_PRODUCTS_DIR.
# =========================================================================
# 
# Generates SupabaseConfig.plist at build time from environment variables.
# Secrets never touch source control; provide SUPABASE_URL and SUPABASE_ANON_KEY in the build environment.

set -euo pipefail

REPO_ROOT="${SRCROOT:-$(pwd)}"

# Optionally source a local env file (gitignored) to make local dev easy.
ENV_FILE=""
if [ -f "${REPO_ROOT}/.env.supabase.local" ]; then
  ENV_FILE="${REPO_ROOT}/.env.supabase.local"
elif [ -f "${REPO_ROOT}/.env.local" ]; then
  ENV_FILE="${REPO_ROOT}/.env.local"
fi

if [ -n "${ENV_FILE}" ]; then
  # shellcheck disable=SC1090
  set -a
  . "${ENV_FILE}"
  set +a
fi

DEST_DIR="${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
DEST_FILE="${DEST_DIR}/SupabaseConfig.plist"

SUPABASE_URL_VALUE="${SUPABASE_URL:-}"
SUPABASE_ANON_KEY_VALUE="${SUPABASE_ANON_KEY:-}"

if [ -z "${SUPABASE_URL_VALUE}" ] || [ -z "${SUPABASE_ANON_KEY_VALUE}" ]; then
  echo "[Supabase] Missing SUPABASE_URL or SUPABASE_ANON_KEY environment variables."
  echo "[Supabase] Set them in your scheme (Run/Test), Xcode Cloud environment secrets, or .env.supabase.local (gitignored)."
  exit 1
fi

mkdir -p "${DEST_DIR}"
cat > "${DEST_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>SUPABASE_URL</key>
  <string>${SUPABASE_URL_VALUE}</string>
  <key>SUPABASE_ANON_KEY</key>
  <string>${SUPABASE_ANON_KEY_VALUE}</string>
</dict>
</plist>
EOF

echo "[Supabase] Wrote SupabaseConfig.plist to bundle resources."
