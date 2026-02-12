# CONVEX BACKEND KNOWLEDGE BASE

**Path:** `convex/`

**MAINTENANCE PROTOCOL**
- **Update this file** when you change schema patterns, auth flows, or discover migration quirks.
- **Example**: If you add a new fan-out pattern, document the denormalization logic here.
- **Goal**: Ensure future agents understand the "why" behind complex backend logic.

## OVERVIEW
Serverless backend handling Authentication, Data Persistence, and Real-time Sync. Built with Convex & TypeScript.

## STRUCTURE
```
convex/
├── _generated/    # Convex generated code
├── migrations/    # Data migration scripts
├── tests/         # Integration tests (`convex-test`)
├── auth.config.ts # Clerk configuration
├── schema.ts      # Database schema definition
└── *.ts           # Query and Mutation files
```

## DATA PATTERNS
- **Group Visibility**: `groups:list` includes groups found via `user_expenses` to ensure consistency. If a user sees an expense, they MUST see the group, even if membership links are broken.

- **Fan-out**: `user_expenses` table denormalizes data for fast queries (`reconcileUserExpenses`).
- **Ghost Data**: Soft deletes preserve history. `bulkImport` handles ID remapping.
- **IDs**: Client-generated UUIDs used for expenses to support offline creation.
- **User Truth**: `accounts` table is the definitive source for user data.

## AUTHENTICATION
- **Provider**: Clerk.
- **Flow**: Client gets Clerk token -> Convex validates -> Creates/Updates `accounts` record.
- **Checks**: Strict auth checks in all mutations/queries.

## TESTING
- **Framework**: `vitest` + `convex-test`.
- **Focus**: Integration testing of mutations and queries.
- **Environment**: Tests run against a local Convex instance or mocked environment.

## ACCOUNT DELETION & ORPHAN CLEANUP

### Hard Delete vs Soft Delete
- **Hard Delete**: DELETE friend records entirely from other users' lists. No ghost placeholders.
- **Soft Delete**: UNLINK only (set `has_linked_account=false`). Preserves friend name/history.

### Manual Dashboard Deletion (CRITICAL)
When an account is manually deleted from the Convex Dashboard:
1. **No triggers fire** - Convex has no database triggers.
2. **Janitor cron** (`cleanupOrphans`) runs every 5 minutes to catch orphans.
3. **For INSTANT updates**: The `friends.list` query validates linked accounts exist in real-time. Convex reactivity auto-updates iOS when the linked account disappears.

### Friend Linking Fields (`account_friends` table)
| Field | Purpose | Index |
|-------|---------|-------|
| `linked_account_id` | Auth ID (Clerk subject) | `by_linked_account_id` |
| `linked_account_email` | Email address | `by_linked_account_email` |
| `linked_member_id` | Canonical member ID (legacy imports) | `by_linked_member_id` |

**IMPORTANT**: `linked_member_id` is mainly used for backwards compatibility with imports. Primary linking uses `linked_account_email` and `linked_account_id`.

### Cleanup Functions
| Function | Location | When Called | Behavior |
|----------|----------|-------------|----------|
| `performHardDelete` | `cleanup.ts` | API deletion endpoints | DELETEs friend records pointing to deleted account |
| `hardCleanupOrphanedAccount` | `users.ts` | Janitor cron | DELETEs orphaned data for a given email |
| `cleanupOrphanedDataForEmail` | `users.ts` | Account re-creation | UNLINKS (soft) for account re-registration |
| `friends.list` | `friends.ts` | Every friend list query | Validates links exist, returns unlinked state if orphaned |

### Janitor Cron (`janitor.ts`)
- Runs every 5 minutes via `crons.ts`.
- Scans `account_friends.linked_account_email` for emails not in `accounts` table.
- DELETEs orphaned friend records (hard delete behavior).
- Processes max 5 orphans per run to avoid timeouts.

### Bug Prevention Checklist
When modifying cleanup logic, ensure:
1. All three link fields are cleared/checked: `linked_account_id`, `linked_account_email`, `linked_member_id`
2. Use indexed queries, not full table scans
3. Hard delete = DELETE records. Soft delete = PATCH to unlink.
4. Query-time validation in `friends.list` provides instant UI updates

## LINKING PIPELINE RUNBOOK

Primary reference for account-linking identity logic:
- `docs/linking/ACCOUNT_LINKING_PIPELINE_RUNBOOK.md`

When changing any of the following, update tests and the runbook:
- `inviteTokens:claim` / `linkRequests:accept`
- alias resolution (`member_aliases`, `accounts.alias_member_ids`)
- friend dedupe/enrichment payload contracts
- member ID normalization behavior

## FRIEND LIST DEDUPE CONTRACT (CRITICAL)

`friends:list` must return one logical row per person identity for each owner, even if `account_friends` contains legacy/stale duplicates.

### Required behavior
1. Enrich linked rows with canonical identity aliases (`alias_member_ids`) and `linked_member_id`.
2. Build identity keys using linked account identifiers (`linked_account_email`, `linked_account_id`, `linked_member_id`) and alias membership.
3. Deduplicate response rows by identity key with deterministic precedence:
   - linked row over unlinked
   - richer alias set over sparse alias set
   - newer `updated_at` over older
4. Preserve merged alias visibility in the winning row so clients can resolve `areSamePerson(...)`.

### Why this exists
During invite-link transitions, owners can temporarily have both:
- stale linked row (`member_id = old/manual id`)
- unlinked canonical row (`member_id = canonical id`)

Without response-level dedupe, iOS/Android clients can show duplicate friend cards if alias metadata is delayed/sparse in a sync cycle.
