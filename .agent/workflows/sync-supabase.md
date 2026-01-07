---
description: Sync database schema with Supabase
---

# Sync Supabase Database

Push your `schema.sql` directly to the remote Supabase database.

## Quick Sync

// turbo

1. Run the sync script:

```bash
./scripts/sync-supabase.sh
```

It will prompt for your database password.

## Preview Changes

1. Run with dry-run flag to see what would be executed:

```bash
./scripts/sync-supabase.sh --dry-run
```

## How it Works

The script executes `supabase/schema.sql` directly against the database using a robust Node.js helper. This avoids using Supabase migrations, keeping your workflow simple and clean.
