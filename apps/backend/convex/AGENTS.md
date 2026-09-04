# PayBack Convex backend instructions

The root `AGENTS.md` applies. This file adds rules for `apps/backend/convex`.

## Sources of truth

- `schema.ts` defines stored shapes and indexes.
- `accounts` is registered-account truth.
- `account_friends` is per-owner confirmed-relationship truth.
- `groups.members` records expense-context membership, never friendship.
- `user_expenses` and group visibility rows are derived fan-out indexes; update them through their
  reconciliation helpers.

Keep public queries/mutations short. Put reusable domain work in model/helper modules and test it
through authenticated functions.

## Authorization

- Resolve the caller with `getCurrentUserOrThrow` and derive owner account/email server-side.
- Never authorize from client-provided ownership fields, names, or group membership alone.
- Admin, migration, backfill, repair, and hard-delete entry points are internal or explicitly
  admin-gated.
- Directory/identity resolution returns only identities already visible to the caller.

## Friend, participant, and ledger boundaries

- `account_friends` proves friendship when its server-owned state is eligible.
- A group-only participant is not a friend and cannot become one through group sync/import.
- `manual` is the canonical status for a user-created unlinked friend and is eligible for direct
  expenses; pending/rejected/request states are not.
- A direct expense ledger is a `groups` row with `is_direct=true`. Its existence does not prove
  friendship.
- For a first direct expense with an explicit `context_kind="direct"` and no existing group,
  `expenses:create` validates the confirmed friend, inserts the ledger, and inserts the expense in
  the same mutation. Any thrown error rolls back both.
- First-ledger membership is the identity-equivalent union of the payer and selected participants:
  exactly the authenticated user and one confirmed friend. A payer need not take a split; preserve
  selected participant/split arrays and validate payer-only counterparties too.
- Existing legacy direct ledgers retain narrow compatibility behavior; do not extend that fallback
  to newly created ledgers.

## Identity and compatibility

- Normalize member IDs and resolve trusted canonical/alias closure before identity comparisons.
- Global aliases require server provenance; local friend merges remain owner-scoped.
- `linked_account_id` stores the account/auth ID string, not a Convex document ID.
- Treat linked metadata as server-owned and downgrade-resistant.
- Validators and Swift DTOs must evolve together; keep old document reads safe during migration.

## Transaction and scale rules

- Keep invariants that span multiple rows in one mutation when possible.
- Use indexed, bounded reads. `.filter()` does not bound a scan.
- Prefer `.take(limit + 1)` to detect overflow; paginate across resumable mutation calls, not in an
  unbounded loop inside one transaction.
- Cleanup/migration jobs persist cursors, are idempotent, and validate the complete page before
  destructive writes.
- Group/expense deletion reconciles visibility before deleting source records.
- Account deletion and orphan cleanup must be fenced against concurrent identity claims.

## Testing

Use `vitest` + `convex-test`. Every authorization or lifecycle fix needs both a success path and a
failure/rollback path, including a cross-account case when access boundaries are involved.

```bash
bun run --cwd apps/backend test --run convex/tests/<file>.test.ts
```

Run `bun run ci` from the repository root before handoff.
