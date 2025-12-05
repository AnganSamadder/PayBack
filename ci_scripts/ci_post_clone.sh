#!/bin/sh

# Xcode Cloud Post-Clone Script
# Ensures Supabase credentials are available as a local env file (gitignored).

set -euo pipefail

echo "=========================================="
echo "ci_post_clone.sh: Preparing Supabase env file"
echo "=========================================="

# Navigate to repository root (ci_scripts is inside the repo)
cd "$(dirname "$0")/.."

# Use placeholder values if secrets are not set (allows builds to succeed)
SUPABASE_URL="${SUPABASE_URL:-https://placeholder.supabase.co}"
SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-placeholder-anon-key}"

if [ "$SUPABASE_URL" = "https://placeholder.supabase.co" ] || [ "$SUPABASE_ANON_KEY" = "placeholder-anon-key" ]; then
  echo "⚠️  Using placeholder Supabase credentials (secrets not configured)."
  echo "   Add SUPABASE_URL and SUPABASE_ANON_KEY in Xcode Cloud for full functionality."
else
  echo "✅ Using Supabase credentials from environment."
fi

cat > ".env.supabase.local" <<EOF
SUPABASE_URL=${SUPABASE_URL}
SUPABASE_ANON_KEY=${SUPABASE_ANON_KEY}
EOF

chmod 600 ".env.supabase.local" || true

echo "✅ Wrote .env.supabase.local for the build (file is gitignored)."
echo "=========================================="
