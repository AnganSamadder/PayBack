#!/bin/sh
# Xcode Cloud pre-build guard for Supabase env vars.
set -euo pipefail

echo "=========================================="
echo "ci_pre_xcodebuild.sh: Validating Supabase environment"
echo "=========================================="

if [ -z "${SUPABASE_URL:-}" ] || [ -z "${SUPABASE_ANON_KEY:-}" ]; then
  echo "❌ SUPABASE_URL or SUPABASE_ANON_KEY is missing."
  echo "   Set these as encrypted environment variables in Xcode Cloud."
  exit 1
fi

echo "✅ Supabase environment variables are present; build can proceed."
echo "=========================================="
