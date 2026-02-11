# PROJECT KNOWLEDGE BASE

**This is a LIVING DOCUMENT. Agents: Update this file after solving hard or recurring issues. Do not treat as a changelog.**

**Generated:** 2026-02-07 02:59:11
**Commit:** 8a34b1
**Branch:** main

## OVERVIEW
PayBack is an expense sharing app featuring a native Swift iOS client (MVVM + Central Store) and a Convex backend (TypeScript).

## STRUCTURE
```
.
├── apps/ios/PayBack/  # Native iOS application
├── convex/            # Backend (Schema, Functions, Auth)
├── packages/          # Shared packages
└── scripts/           # CI/CD utilities
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| iOS UI/Views | `apps/ios/PayBack/Sources/Features` | Organized by domain |
| iOS State | `apps/ios/PayBack/Sources/Services/State` | `AppStore.swift` is the God Object |
| Backend Schema | `convex/schema.ts` | Source of truth for data model |
| Backend Logic | `convex/` | Mutations, queries, actions |
| Tests | `apps/ios/PayBack/Tests` & `convex/tests` | Integration focused |

## COMMANDS
```bash
# Full CI Simulation (Build + Test)
./scripts/test-ci-locally.sh

# Convex Development
bunx convex dev

# iOS Build
xcodebuild -scheme PayBack -destination "platform=iOS Simulator,name=iPhone 15"
```

## CONVENTIONS
- **Commits**: Conventional Commits (`feat:`, `fix:`). Single line.
- **Linting**: Zero warnings policy (`FAIL_ON_WARNINGS=1`).
- **Runtime**: `bun` / `bunx` preferred over `npm`.

## NOTES
- **CI Parity**: `test-ci-locally.sh` mirrors GitHub Actions.
- **Architecture**: iOS uses a Central Store; avoid local `@State` for shared data.
- **Backend**: `accounts` table is the user source of truth; handle ghost data via `bulkImport`.

## DELETION PROTOCOL

### Hard Delete (Admin/Backend)
When a user is **hard deleted** from the Convex dashboard or via `performHardDelete`:
1. The user's `accounts` record is permanently deleted
2. All `account_friends` records owned by the user are deleted
3. **Cascading cleanup**: Friends of the deleted user have their links removed via:
   - `by_linked_account_id` index
   - `by_linked_account_email` index
   - `by_linked_member_id` index (added 2026-02-07)
4. The deleted user disappears from all friend lists immediately (Convex live sync)

### Soft Delete (User-Initiated)
When a user **deletes their own account**:
1. The account is marked as deleted (soft delete flag)
2. The user becomes a "Ghost" - their data remains for history purposes
3. Friends see the user as **unlinked** but can still see past transactions
4. Name displays as the friend's nickname or original name (not "Unknown")

### Key Tables
- `accounts`: User source of truth
- `account_friends`: Friend relationships with optional linking to accounts
- Indexes: `by_linked_account_id`, `by_linked_account_email`, `by_linked_member_id`

## MEMBER ID RESOLUTION (iOS)

### The Problem
After CSV import, group members may have different `id` values than their corresponding friends' `memberId`. This breaks `isFriend` checks.

### The Solution
`GroupMember` has an `accountFriendMemberId: UUID?` property that stores the original friend's `memberId`. When looking up if a group member is a friend:

```swift
// FriendDetailView.swift - isFriend computed property
let lookupId = friend.accountFriendMemberId ?? friend.id
return store.friends.contains { $0.memberId == lookupId }
```

### Import ID Consistency
`DataImportService.swift` ensures:
1. `memberIdMapping` is checked before generating new UUIDs
2. `nameToExistingId` provides name-based deduplication
3. Same person = same UUID across friends and group members

## CSV IMPORT LOGIC (iOS ↔ Convex)

### The Remapping Mismatch (Fixed 2026-02-07)
**Problem**: iOS imports generate **new local UUIDs** to avoid collisions, but `performBulkImport` originally sent the **original CSV UUIDs** to Convex.
**Result**: iOS stores Group `ABC` (remapped), Convex stores Group `XYZ` (original). Syncing breaks because iOS doesn't know `XYZ`.

### The Protocol
1. **Local Import**: `importData` generates `memberIdMapping` and `groupIdMapping` (Original → New).
2. **Transform**: `applyRemappings()` mutates the parsed data using these mappings.
3. **Bulk Import**: Sends the **remapped UUIDs** to Convex.
4. **Consistency**: Local iOS state and Convex backend now share the exact same UUIDs.

**Rule**: Always pass `memberIdMapping` and `groupIdMapping` to `performBulkImport` to ensure ID consistency.

## BALANCE CALCULATION LOGIC (iOS)

### The Zero Balance Bug (Fixed 2026-02-07)
**Problem**: Users saw "Settled ($0.00)" even with unsettled transactions because `netBalance` calculations only checked the primary `friend.id` or `currentUser.id`. Linked accounts (via invites or CSV remapping) often have different IDs in the expense splits.

### The Fix
1. **Friend Detail**: `FriendDetailView.netBalance` must check BOTH `friend.id` AND `friend.accountFriendMemberId`.
2. **Dashboard**: `AppStore.netBalance(for: Group)` must use `currentUser.equivalentMemberIds` (from `UserAccount`) to catch all splits belonging to the user, including those under remapped IDs.

**Rule**: When calculating balances or filtering expenses, ALWAYS check for ID equivalence (`accountFriendMemberId` for friends, `equivalentMemberIds` for current user).

## USER LINKING PROCESS

### Overview
Linking connects a local "Unlinked" friend (often created manually or via CSV import) to a real registered User Account. This allows two users to share the same friend/member identity in groups and expenses.

### The Flow
1.  **Invite Creation**: User A creates a link for a specific group member (e.g., "Test User" with ID `X`).
2.  **Claiming**: User B ("Test User") clicks the link.
    -   Backend (`inviteTokens:claim`) verifies the token.
    -   It updates User B's `alias_member_ids` to include `X`. This is CRITICAL for User B to see expenses assigned to `X` as their own.
    -   It updates User A's `account_friends` record for `X` to set `linked_account_id` to User B's account ID.
3.  **Syncing**:
    -   User B receives updated `UserAccount` containing `alias_member_ids`.
    -   User A receives updated `account_friends` list.

### ID Resolution Logic (The "0 Balance" Fix)
**Problem**: Before linking, User B is participating in expenses as ID `X`. After linking, User B logs in with ID `Y`.
**Solution**:
-   Backend sends `alias_member_ids` (including `X`) in the User object.
-   iOS `UserAccount` model MUST map `alias_member_ids` (JSON key) to `equivalentMemberIds` (Swift property) via `CodingKeys`.
-   `AppStore` checks `equivalentMemberIds` when calculating "My" balance. `isMe(memberId)` checks `currentUser.id` OR `linkedMemberId` OR `equivalentMemberIds`.

### Friend Identity Resolution & Deduplication (Fixed 2026-02-07)
**Symptom**: User A sees two entries for "Test User" - one unlinked (original) and one linked (new account).
**Root Cause**: When a friend link is claimed, the backend might return both the original friend record and the new linked friend record if they exist separately in `account_friends` or `groups`.

**The Solution**:
1.  **Backend Enrichment**: `convex/friends.ts` now includes `alias_member_ids` in the `AccountFriend` object (fetched from the linked user's account).
2.  **Client-Side Identity Map**:
    -   `AppStore` builds a `memberAliasMap` during friend updates.
    -   If Friend B lists Friend A's ID in its `aliasMemberIds`, Friend B is considered the "Master" and Friend A is the "Alias".
3.  **Deduplication**:
    -   `AppStore.processFriendsUpdate` filters out any friend that is found to be an alias of another present friend.
    -   Only the "Master" (linked) friend remains in the `store.friends` list.
4.  **Identity Checks**:
    -   `store.areSamePerson(id1, id2)` checks the `memberAliasMap` to resolve identity, ensuring expenses assigned to the alias ID are correctly attributed to the master friend in the UI.

### Duplicate Friend Reappearance Guard (Fixed 2026-02-10)
**Symptom**: After account switch/login, owner still sees duplicate friend cards (linked + unlinked) for the same person.

**Root Causes**:
1. `scheduleFriendSync` previously synced a **pre-dedupe** friend list back to Convex, which could reintroduce duplicate rows.
2. DTO mapping could miss identity equivalence when `alias_member_ids` was sparse in some updates.

**Required Guards**:
1. In `AppStore.scheduleFriendSync`, only sync `self.friends` **after** `processFriendsUpdate(...)` dedupe.
2. In Convex friend DTO mapping, treat `linked_member_id` as an identity alias fallback (not only `alias_member_ids`).
3. In `friendMembers`, dedupe by `areSamePerson(...)` identity equivalence, not raw UUID equality.

**Rule**: Never write pre-dedupe friend arrays to cloud. Any friend identity check in UI lists must use equivalence (`areSamePerson`), not strict UUID match.

### Key Data Structures
-   **UserAccount**: `equivalentMemberIds` stores all alias UUIDs (e.g., from invites/imports).
-   **GroupMember**: `accountFriendMemberId` stores the UUID of the linked `AccountFriend` (if any).
-   **AccountFriend**: Represents a direct friendship. Linked via `linkedAccountId` (String).

## LINKING RUNBOOK (READ FIRST)

For end-to-end linking/identity debugging and implementation rules, use:

- `docs/linking/ACCOUNT_LINKING_PIPELINE_RUNBOOK.md`

This runbook is the canonical operational guide for:
- invite claim + link-request acceptance pipeline
- canonical/alias invariants
- iOS selector correctness
- bulk import identity rules
- troubleshooting commands and test gates

## RELEASE BLOCKERS FIXED (2026-02-11)

### Convex Authorization Rule (Critical)
Never trust client-supplied `accountEmail` (or any ownership identifier) for destructive/identity mutations.

**Required pattern**:
1. Derive caller identity from auth (`getCurrentUser` / `getCurrentUserOrThrow`).
2. Resolve account email/id server-side from auth context.
3. Treat client `accountEmail` as optional legacy input at most, and reject mismatches where needed.

Applied to:
- `aliases:mergeMemberIds`
- `aliases:mergeUnlinkedFriends`
- `cleanup:deleteLinkedFriend`
- `cleanup:deleteUnlinkedFriend`
- `cleanup:selfDeleteAccount`

### Admin Mutation Guard
`admin:hardDeleteUser` must be admin-only. Use explicit admin allowlist checks from auth identity before deleting by email.

### Friend Linking Identity Type Rule
`account_friends.linked_account_id` must store auth/account `id` (string identity), not Convex document `_id`.
Using `_id` breaks comparisons/dedup paths that check against auth IDs.

### iOS Payload Compatibility Rule
When backend arg contracts change, keep iOS mutation payload keys aligned.

Current required keys:
- `aliases:mergeMemberIds`: `sourceId`, `targetCanonicalId`
- `cleanup:deleteLinkedFriend`: `friendMemberId`
- `cleanup:deleteUnlinkedFriend`: `friendMemberId`
- `aliases:mergeUnlinkedFriends`: no `accountEmail` from client

### iOS Realtime Sync Guard (Test/Startup Stability)
`AppStore.subscribeToSyncManager` must ignore realtime payloads until a session exists.
Otherwise empty remote snapshots can clobber local state before auth and break persistence expectations.

### Dependencies Thread-Safety Guard
`Dependencies.reset()` is called concurrently in tests; serialize it with a lock to avoid crashes in `DependenciesTests.testConcurrentReset_DoesNotCrash`.
