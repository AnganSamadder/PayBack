#!/bin/bash

# Setup script for PayBack Git hooks
# This script configures Git to use the custom hooks in .githooks/

set -e

echo "🔧 Setting up Git hooks for PayBack..."
echo ""

# Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "❌ Error: Not in a Git repository"
    exit 1
fi

# Configure Git to use .githooks directory
git config core.hooksPath .githooks

# Make hooks executable
chmod +x .githooks/pre-commit

echo "✅ Git hooks configured successfully!"
echo ""
echo "The following hooks are now active:"
echo "  - pre-commit: Runs unit tests before each commit"
echo ""
echo "To bypass hooks when needed, use: git commit --no-verify"
echo ""
