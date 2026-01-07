#!/bin/bash
# Sync Supabase database schema
# Usage: ./scripts/sync-supabase.sh [--dry-run]
#
# Runs schema.sql directly on the remote Supabase database using a Node.js script.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Ensure Node.js and npm are installed
if ! command -v node &> /dev/null || ! command -v npm &> /dev/null; then
    echo "❌ Node.js and npm are required. Please install them."
    exit 1
fi

# Install script dependencies if needed
if [ ! -d "$SCRIPT_DIR/node_modules" ]; then
    echo "📦 Installing helper script dependencies..."
    cd "$SCRIPT_DIR"
    npm install --silent
    cd "$PROJECT_DIR"
fi

# Load ENV Variables from scripts/.env if exists
if [ -f "$SCRIPT_DIR/.env" ]; then
    # We use source to load variables, but we only export the ones we need for the node script
    set -a # automatically export all variables
    source "$SCRIPT_DIR/.env"
    set +a
fi

echo "🔄 Syncing Supabase database..."

# Check if logged in (only if we need default project ref)
if [ -z "$DB_HOST" ]; then
    if ! supabase projects list &>/dev/null; then
        echo "❌ Not logged in to Supabase. Run: supabase login"
        exit 1
    fi
fi

SCHEMA_FILE="supabase/schema.sql"

if [ ! -f "$SCHEMA_FILE" ]; then
    echo "❌ Schema file not found: $SCHEMA_FILE"
    exit 1
fi

if [ "$1" == "--dry-run" ]; then
    echo "🔍 Dry run - would execute:"
    echo "---"
    cat "$SCHEMA_FILE"
    echo "---"
    exit 0
fi

# Get password if not set
if [ -z "$DB_PASSWORD" ]; then
    echo "Enter your database password (from Supabase Dashboard > Settings > Database):"
    read -s DB_PASSWORD
    echo ""
fi

if [ -z "$DB_PASSWORD" ]; then
    echo "❌ Password cannot be empty."
    exit 1
fi

# Run the Node.js sync script
# Variables DB_HOST, DB_PORT, DB_USER, DB_PASSWORD are exported automatically if sourced, or below
export DB_PASSWORD
node scripts/sync-db.js
