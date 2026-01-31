# Convex Schema Migration Guide: String IDs to v.id References

This guide describes the transition from using client-generated UUID strings to native Convex `v.id` references for relationships in the backend.

## Overview

We are moving away from string-based IDs for internal relationships to improve type safety, query performance, and database integrity.

### Key Changes

1.  **Accounts**: Added `v.id("accounts")` as the primary way to reference users.
2.  **Groups**: Added `v.id("groups")` for referencing groups.
3.  **Expenses**: Added `owner_id` (account reference) and `group_ref` (group reference).

## Deprecated Fields

The following fields are now deprecated and should be replaced in new code:

### Groups Table
| Deprecated Field | New Field | Description |
| :--- | :--- | :--- |
| `owner_account_id` (string) | `owner_id` (v.id) | Reference to the owner's account. |

### Expenses Table
| Deprecated Field | New Field | Description |
| :--- | :--- | :--- |
| `owner_account_id` (string) | `owner_id` (v.id) | Reference to the owner's account. |
| `group_id` (string) | `group_ref` (v.id) | Reference to the group this expense belongs to. |

## Query Updates

Existing queries have been updated to *prefer* the new `v.id` fields and their corresponding indexes.

### Example: Listing Groups
**Old Way:**
```typescript
const groups = await ctx.db
  .query("groups")
  .withIndex("by_owner_account_id", (q) => q.eq("owner_account_id", user.id))
  .collect();
```

**New Way:**
```typescript
const groups = await ctx.db
  .query("groups")
  .withIndex("by_owner_id", (q) => q.eq("owner_id", user._id))
  .collect();
```

## Data Migration

A background migration script should be run to populate the new `v.id` fields for existing records by looking up the corresponding `_id` from the existing string IDs.

1.  For each group, look up `accounts` where `id == owner_account_id` and set `owner_id`.
2.  For each expense, look up `accounts` where `id == owner_account_id` and set `owner_id`.
3.  For each expense, look up `groups` where `id == group_id` and set `group_ref`.

## Backward Compatibility

Deprecated fields will remain in the schema for several releases to ensure that existing client versions continue to function. However, they should not be used in new features.
