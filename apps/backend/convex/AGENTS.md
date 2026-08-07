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

| Field                  | Purpose                              | Index                     |
| ---------------------- | ------------------------------------ | ------------------------- |
| `linked_account_id`    | Auth ID (Clerk subject)              | `by_linked_account_id`    |
| `linked_account_email` | Email address                        | `by_linked_account_email` |
| `linked_member_id`     | Canonical member ID (legacy imports) | `by_linked_member_id`     |
| `link_state`           | Server provenance marker             | —                         |

**IMPORTANT**: `linked_member_id` is mainly used for backwards compatibility with imports. Primary linking uses `linked_account_email` and `linked_account_id`.
Successful invite/link-request claims must write `link_state: "linked"` on both users' friend rows.
Client sync and bulk import cannot create this marker. During migration of older rows, preserve an
unmarked link only when indexed claim/request or account-alias provenance proves the owner-account-
member relationship, then rewrite the complete tuple from the live account.

Global member aliases are trusted only when `materialization_source` is `account_alias` and
`source_account_id` identifies the canonical account. Legacy unmarked rows stay quarantined until
the identity migration corroborates them against that account's `alias_member_ids`; unproven rows
must block readiness. Local friend merges belong in `account_friends.local_alias_member_ids`.

Invite creation must bind `invite_tokens.target_friend_id` to the exact creator-owned unlinked
friend row. Claim and link-request acceptance must revalidate that binding and the active creator,
reject legacy unbound tokens, and rewrite only bounded creator-owned references.

Current identity readiness is `member_identity_v3`; older markers never open mutation gates. During
v3 rollout, unmarked aliases stay quarantined and compatibility may scan at most 512 accounts. Each
migration page must preflight every conflict, duplicate, provenance tag, delete, and patch before any
domain mutation; on failure only migration `last_error` may change.

Public invite validation uses an allowlisted token DTO and creator-owned expenses through
`expenses.by_owner_id`, with a hard preview cap and verified creator-owned `group_ref`. Do not expose
raw invite-token documents or scan global expenses. Use the shared ghost predicate for both
normalized `status` and `link_state`, and keep name-based identity repair endpoints disabled.

### Cleanup Functions

| Function                   | Location           | When Called             | Behavior                                                  |
| -------------------------- | ------------------ | ----------------------- | --------------------------------------------------------- |
| `beginHardDeleteAccount`   | `cleanup.ts`       | API deletion endpoints  | Starts bounded, resumable hard deletion                   |
| `processOrphanCleanupStep` | `orphanCleanup.ts` | Re-creation and janitor | Processes one bounded orphan-cleanup step                 |
| `advanceOrphanCleanupJob`  | `users.ts`         | Scheduled worker        | Reschedules the persisted orphan job until complete       |
| `friends.list`             | `friends.ts`       | Every friend list query | Validates links exist, returns unlinked state if orphaned |

Cleanup email identity is case-insensitive. `cleanupEmailMaterialization.ts` owns the versioned,
bounded canonicalization pass for legacy email-bearing rows. New writes must store normalized
lowercase identity emails. Account creation and email-selected admin deletion must wait for the
`cleanup_email_canonicalization_v1` readiness stamp; never treat missing optional
`accounts.normalized_email` as proof that no matching account exists.

Orphan and hard-delete workers must remain resumable: persist scan/member cursors and perform
bounded work per mutation. Before destructive orphan cleanup, install
`orphan_cleanup_member_fences` for every discovered member ID. Runtime account/alias claim paths
must call `assertMemberIdentityNotCleanupFenced`; late identity discovery pauses cleanup until the
new IDs are fenced. Release fences in bounded batches on completion or terminal failure. Continue
to re-check auth ID, document ID, normalized email, and target-local ownership in every destructive
transaction.

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

1. Resolve linked rows through server provenance, then enrich them with canonical identity aliases
   (`alias_member_ids`) and `linked_member_id` from the live account.
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
