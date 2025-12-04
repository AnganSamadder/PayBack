#!/bin/sh

# Xcode Cloud Post-Clone Script
# Ensures Supabase credentials are available as a local env file (gitignored).

set -euo pipefail

echo "=========================================="
echo "ci_post_clone.sh: Preparing Supabase env file"
echo "=========================================="

# Navigate to repository root (ci_scripts is inside the repo)
cd "$(dirname "$0")/.."

if [ -z "${SUPABASE_URL:-}" ] || [ -z "${SUPABASE_ANON_KEY:-}" ]; then
  echo "❌ SUPABASE_URL or SUPABASE_ANON_KEY is missing."
  echo "   Add them as encrypted environment variables in Xcode Cloud."
  exit 1
fi

cat > ".env.supabase.local" <<EOF
SUPABASE_URL=${SUPABASE_URL}
SUPABASE_ANON_KEY=${SUPABASE_ANON_KEY}
EOF

chmod 600 ".env.supabase.local" || true

echo "✅ Wrote .env.supabase.local for the build (file is gitignored)."
echo "=========================================="
