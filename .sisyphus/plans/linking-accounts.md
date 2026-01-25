# Linking Accounts Feature - Complete Implementation Plan

## Context

### Original Request
Build a robust account-linking/merging feature where users can add local friends, send invite links, and when the link is claimed, accounts merge - preserving all existing expenses from both sides. Multiple unlimited merges allowed. Proper nickname preferences, deletion behaviors, and ability to merge unlinked friends.

### Interview Summary
**Key Discussions**:
- Linking model: Hybrid alias - keep old member IDs, add merged identity. Receiver's existing identity is canonical.
- Merge UX: After invite acceptance (option to merge with existing local friend), in friend profile (Add Friend or Merge), and in Settings (merge any two unlinked friends).
- Merging only for unlinked friends - linked accounts must use invite links.
- Nickname preference: Global toggle (existing) + per-friend override toggle.
- Direct groups: Persist with isDirect flag, derive display name from other member.
- Deletion behaviors defined for linked friends, unlinked friends, hard DB delete, and self-delete.
- Test strategy: TDD with XCTest.

**Research Findings**:
- Convex schema has `accounts`, `account_friends`, `groups`, `expenses` tables with `linked_member_id` and participant tracking.
- `InviteLinkClaimView` exists with "Accept & Link Account" but no merge-selection step.
- `FriendDetailView` has nickname editing and link status display.
- `AppStore.deleteFriend` removes friend from groups/expenses and deletes self-only groups.
- Extensive XCTest coverage exists for linking, invites, and reconciliation.
- `LinkStateReconciliation` uses remote friend list as source of truth.

---

## Work Objectives

### Core Objective
Implement complete account-linking/merging with alias support, nickname preferences, proper deletion behaviors, and merge flows for unlinked friends - all with comprehensive TDD coverage.

### Concrete Deliverables
- `member_aliases` table in Convex schema for alias-to-canonical mapping
- Add `prefer_nickname` and `original_nickname` fields to `account_friends` table in Convex schema
- Updated invite claim flow with optional merge-with-existing step
- Merge flows in InviteLinkClaimView, FriendDetailView, and Settings
- Per-friend `preferNickname` toggle in AccountFriend model
- Enhanced deletion logic distinguishing linked vs unlinked behaviors
- Cascade delete for hard DB deletions
- Self-delete flow that unlinks but preserves expenses
- Unified unlinked friend handling for shared friends across users
- Comprehensive XCTest coverage for all new functionality

### Definition of Done
- [ ] `bun test` in convex passes with all new backend tests
- [ ] `./scripts/test-ci-locally.sh` passes with zero warnings
- [ ] All merge scenarios work correctly (invite-merge, profile-merge, settings-merge)
- [ ] Nickname preference (global + per-friend) displays correctly throughout app
- [ ] Deletion of linked friend removes friendship only, keeps account
- [ ] Deletion of unlinked friend removes all traces
- [ ] Hard DB delete cascades correctly
- [ ] Self-delete unlinks but preserves expenses
- [ ] Multiple users sharing unlinked friend see unified record
- [ ] UI matches existing app style (clean, sleek, snappy)

### Must Have
- Alias mapping persisted and queried correctly
- Receiver's member ID is always canonical after merge
- Merge-with-existing flow after invite acceptance
- Per-friend nickname preference toggle
- Proper deletion confirmation messages with context
- Extra confirmation for active direct expenses
- All expenses preserved after linking (both sides)
- Activity dashboard shows direct expenses in groups correctly

### Must NOT Have (Guardrails)
- NO merging linked accounts via UI (only via invite links)
- NO data loss during any merge operation
- NO silent deletion of expenses without confirmation
- NO breaking existing link/invite flows
- NO changes to group membership logic beyond alias resolution
- NO new social features (blocking, privacy controls) - out of scope
- NO emoji in code or UI unless already present in codebase

---

## Verification Strategy

### Test Decision
- **Infrastructure exists**: YES (XCTest)
- **User wants tests**: YES (TDD)
- **Framework**: XCTest with existing patterns
- **QA approach**: TDD with manual verification steps

### TDD Workflow
Each TODO follows RED-GREEN-REFACTOR:
1. **RED**: Write failing test first
2. **GREEN**: Implement minimum code to pass
3. **REFACTOR**: Clean up while keeping green

---

## Task Flow

```
1 (Schema) → 2 (Backend Alias) → 3 (Backend Merge) → 4 (Backend Delete)
                                       ↓
5 (iOS Model) → 6 (Invite Claim UI) → 7 (Profile Merge UI) → 8 (Settings Merge UI)
                       ↓
              9 (Nickname Pref) → 10 (Delete UI) → 11 (Self-Delete)
                                        ↓
                              12 (Shared Unlinked) → 13 (Direct Groups) → 14 (Integration Tests)
```

## Parallelization

| Group | Tasks | Reason |
|-------|-------|--------|
| A | 5, 6, 7 | iOS UI tasks can overlap once backend is ready |
| B | 9, 10 | Nickname and delete UI are independent |

| Task | Depends On | Reason |
|------|------------|--------|
| 2 | 1 | Alias queries need schema |
| 3 | 2 | Merge logic uses alias resolution |
| 4 | 3 | Delete logic uses merge understanding |
| 5 | 1 | iOS model needs backend schema for nickname preference sync |
| 6 | 3, 5 | Invite claim merge needs backend + model |
| 14 | 1-13 | Integration tests need all features |

---

## TODOs

### Phase 1: Backend Schema & Alias Resolution

- [x] 1. Add `member_aliases` table and nickname fields to Convex schema

  **What to do**:
  - Add `member_aliases` table with fields: `canonical_member_id`, `alias_member_id`, `account_email`, `created_at`
  - Add index by `alias_member_id` for lookups
  - Add index by `canonical_member_id` for reverse lookups
  - Add `prefer_nickname: v.optional(v.boolean())` to `account_friends` table
  - Add `original_nickname: v.optional(v.string())` to `account_friends` table
  - Write migration to identify existing linked members and create initial alias records

  **Canonical/Alias Invariant** (CRITICAL):
  - When receiver claims invite: receiver's existing `linked_member_id` becomes canonical
  - Sender's `target_member_id` becomes an alias pointing to receiver's canonical ID
  - All alias lookups are transitive: if A→B and B→C, then A resolves to C
  - Cycle prevention: reject alias creation if it would create a cycle
  - Current `inviteTokens.claim` behavior changes: instead of setting `linked_member_id = target_member_id`, it creates alias from target→receiver's existing ID

  **Must NOT do**:
  - Do not modify existing `linked_member_id` semantics yet
  - Do not delete or rename existing columns

  **Parallelizable**: NO (foundation task)

  **References**:
  - `convex/schema.ts` - Add new table definition following existing patterns
  - `convex/migrations.ts` - Migration patterns for data backfill
  - `convex/inviteTokens.ts:claim` - Current linking sets `linked_member_id`

  **Acceptance Criteria**:
  - [ ] Test: `member_aliases` table creation test passes
  - [ ] Test: `account_friends` schema includes `prefer_nickname` and `original_nickname`
  - [ ] `bunx convex dev` deploys schema without errors
  - [ ] Migration creates alias records for existing linked members

  **Commit**: YES
  - Message: `feat(convex): add member_aliases table and nickname preference fields`
  - Files: `convex/schema.ts`, `convex/migrations.ts`
  - Pre-commit: `bun test`

---

- [ ] 2. Implement alias resolution queries in Convex

  **What to do**:
  - Add `resolveCanonicalMemberId(aliasId)` query that looks up canonical ID from aliases
  - Add `getAliasesForMember(canonicalId)` query for reverse lookup
  - Update group member queries to resolve through aliases
  - Update expense participant queries to resolve through aliases

  **Must NOT do**:
  - Do not change mutation semantics yet
  - Do not break existing queries

  **Parallelizable**: NO (depends on 1)

  **References**:
  - `convex/schema.ts:member_aliases` - New table from task 1
  - `convex/groups.ts` - Existing group queries using `linked_member_id`
  - `convex/expenses.ts` - Existing expense queries with participant lookups
  - **Creates new file**: `convex/aliases.ts` - Alias resolution queries (does not exist yet)

  **Acceptance Criteria**:
  - [ ] Test: `resolveCanonicalMemberId` returns canonical ID for alias
  - [ ] Test: `resolveCanonicalMemberId` returns input if no alias exists
  - [ ] Test: `getAliasesForMember` returns all alias IDs
  - [ ] `bun test` passes

  **Commit**: YES
  - Message: `feat(convex): add alias resolution queries for member lookup`
  - Files: `convex/aliases.ts`, `convex/groups.ts`, `convex/expenses.ts`
  - Pre-commit: `bun test`

---

- [x] 3. Implement backend merge logic with alias creation

  **What to do**:
  - Add `mergeMemberIds(sourceId, targetCanonicalId, accountEmail)` mutation
  - Create alias record mapping source to target
  - Update all expenses where source is participant to also include canonical
  - Update all groups where source is member to recognize alias
  - Add `mergeUnlinkedFriends(friendId1, friendId2, accountEmail)` mutation for settings merge
  - Ensure merge is idempotent (running twice has no additional effect)
  - **Concurrency handling**: Use Convex transactions to ensure atomicity; if concurrent merge attempted, second call should detect existing alias and succeed idempotently

  **Must NOT do**:
  - Do not delete source member records (keep for historical reference)
  - Do not allow merging if either friend is linked (guard check)

  **Parallelizable**: NO (depends on 2)

  **References**:
  - `convex/aliases.ts` - Alias queries from task 2 (file created in task 2)
  - `convex/inviteTokens.ts:claim` - Current linking flow to extend
  - `convex/friends.ts` - Friend record updates

  **Acceptance Criteria**:
  - [ ] Test: `mergeMemberIds` creates alias record
  - [ ] Test: `mergeMemberIds` is idempotent
  - [ ] Test: Concurrent merge calls are handled safely (second call succeeds)
  - [ ] Test: `mergeUnlinkedFriends` fails if either friend is linked
  - [ ] Test: Expenses with source member resolve to canonical
  - [ ] `bun test` passes

  **Commit**: YES
  - Message: `feat(convex): implement merge logic with alias creation`
  - Files: `convex/aliases.ts`, `convex/friends.ts`
  - Pre-commit: `bun test`

---

- [x] 4. Implement backend deletion logic with link-aware behavior

  **What to do**:
  - Add `deleteLinkedFriend(friendMemberId, accountEmail)` mutation:
    - Removes friend from `account_friends` only
    - Does NOT delete the linked account
    - Deletes direct group and its expenses between the two users
    - Returns confirmation details
  - Add `deleteUnlinkedFriend(friendMemberId, accountEmail)` mutation:
    - Removes friend from `account_friends`
    - Removes friend from all groups
    - Removes friend from all expenses (or deletes expenses if only participant)
    - Deletes any aliases for this member
    - Returns deletion summary
  - Add `hardDeleteAccount(accountId)` internal mutation:
    - Cascades: delete all friends, groups, expenses, aliases
    - For use by admin/DB cleanup only
  - Add `selfDeleteAccount(accountEmail)` mutation:
    - Marks account as deleted
    - Updates all `account_friends` records pointing to this account to unlink (has_linked_account = false)
    - Preserves expenses (debt remains)

  **Must NOT do**:
  - Do not expose `hardDeleteAccount` to client
  - Do not delete expenses on self-delete

  **Parallelizable**: NO (depends on 3)

  **References**:
  - `convex/cleanup.ts:deleteAccountByEmail` - Current deletion (only deletes account row)
  - `convex/friends.ts:clearAllForUser` - Friend deletion patterns
  - `convex/groups.ts` - Group membership operations
  - `convex/expenses.ts` - Expense participant operations

  **Acceptance Criteria**:
  - [ ] Test: `deleteLinkedFriend` removes friendship but account still exists
  - [ ] Test: `deleteLinkedFriend` deletes direct group and expenses
  - [ ] Test: `deleteUnlinkedFriend` removes all traces
  - [ ] Test: `selfDeleteAccount` unlinks for others but keeps expenses
  - [ ] `bun test` passes

  **Commit**: YES
  - Message: `feat(convex): implement link-aware deletion logic`
  - Files: `convex/cleanup.ts`, `convex/friends.ts`, `convex/groups.ts`, `convex/expenses.ts`
  - Pre-commit: `bun test`

---

### Phase 2: iOS Model Updates

- [x] 5. Update AccountFriend model with per-friend nickname preference

  **What to do**:
  - Add `preferNickname: Bool` property to `AccountFriend` struct
  - Update `displayName(showRealNames:)` to check `preferNickname` first, then global setting
  - Add `originalNickname: String?` to preserve pre-link nickname
  - Update Codable conformance for new fields
  - Add backward compatibility for existing data (default `preferNickname = false`)

  **Must NOT do**:
  - Do not break existing displayName behavior for users without preference set
  - Do not remove global `showRealNames` setting

  **Parallelizable**: YES (with 6, 7 once backend ready)

  **References**:
  - `apps/ios/PayBack/Sources/Models/UserAccount.swift:AccountFriend` - Current model with nickname, originalName
  - `apps/ios/PayBack/Sources/Features/Settings/SettingsView.swift` - Global showRealNames toggle

  **Acceptance Criteria**:
  - [ ] Test: `preferNickname=true` shows nickname regardless of global setting
  - [ ] Test: `preferNickname=false` defers to global setting
  - [ ] Test: Codable round-trips correctly with new fields
  - [ ] `./scripts/test-ci-locally.sh` passes

  **Commit**: YES
  - Message: `feat(ios): add per-friend nickname preference to AccountFriend`
  - Files: `apps/ios/PayBack/Sources/Models/UserAccount.swift`
  - Pre-commit: `./scripts/test-ci-locally.sh`

---

### Phase 3: Merge UI Flows

- [ ] 6. Add merge-with-existing flow to InviteLinkClaimView

  **What to do**:
  - After successful claim, check if user has unlinked friends with similar name
  - If potential matches exist, show "Merge with existing?" sheet:
    - List potential matches with expense counts
    - "Merge with [name]" button for each
    - "Keep separate" button to skip
  - On merge selection, call backend `mergeMemberIds`
  - Update success message to reflect merge
  - Preserve original nickname if merging

  **Must NOT do**:
  - Do not block claim completion on merge decision
  - Do not auto-merge without user confirmation
  - Do not show merge option if no similar unlinked friends exist

  **Parallelizable**: YES (with 7, once 3 and 5 complete)

  **References**:
  - `apps/ios/PayBack/Sources/Features/People/InviteLinkClaimView.swift` - Current claim UI
  - `apps/ios/PayBack/Sources/Services/State/AppStore.swift` - Friend list access
  - `apps/ios/PayBack/Sources/DesignSystem/` - UI component patterns

  **Acceptance Criteria**:
  - [ ] Test: Merge sheet appears when similar unlinked friend exists
  - [ ] Test: Merge sheet does NOT appear when no similar friends
  - [ ] Test: Selecting merge calls backend and updates local state
  - [ ] Test: "Keep separate" completes without merge
  - [ ] Manual: UI matches app style (verify with iOS Simulator screenshot)

  **Commit**: YES
  - Message: `feat(ios): add merge-with-existing flow to invite claim`
  - Files: `apps/ios/PayBack/Sources/Features/People/InviteLinkClaimView.swift`
  - Pre-commit: `./scripts/test-ci-locally.sh`

---

- [ ] 7. Add merge/add-friend options to FriendDetailView for non-friends

  **What to do**:
  - When viewing a profile of someone who is NOT in friends list (e.g., from group):
    - Show "Add Friend" button
    - Show "Merge with existing friend" button if user has unlinked friends
  - "Add Friend" creates new friend record (existing flow)
  - "Merge with existing" shows picker of unlinked friends, then calls merge
  - After merge, navigate to merged friend's profile

  **Must NOT do**:
  - Do not show merge option for linked friends
  - Do not show these buttons if already friends

  **Parallelizable**: YES (with 6, once 3 and 5 complete)

  **References**:
  - `apps/ios/PayBack/Sources/Features/People/FriendDetailView.swift` - Friend profile UI
  - `apps/ios/PayBack/Sources/Services/State/AppStore.swift:addFriend` - Friend addition

  **Acceptance Criteria**:
  - [ ] Test: Non-friend profile shows Add Friend button
  - [ ] Test: Non-friend profile shows Merge option when unlinked friends exist
  - [ ] Test: Merge navigates to merged friend profile
  - [ ] Manual: UI matches app style

  **Commit**: YES
  - Message: `feat(ios): add merge/add-friend options for non-friend profiles`
  - Files: `apps/ios/PayBack/Sources/Features/People/FriendDetailView.swift`
  - Pre-commit: `./scripts/test-ci-locally.sh`

---

- [ ] 8. Add merge screen to Settings for merging any two unlinked friends

  **What to do**:
  - Add "Merge Friends" row in Settings under a "Friends" or "Data" section
  - Merge screen shows two pickers: "Friend A" and "Friend B" (only unlinked friends)
  - Preview section shows:
    - Combined expense count
    - Groups affected
    - Warning about irreversibility
  - "Merge" button with confirmation dialog
  - On confirm, call backend `mergeUnlinkedFriends`
  - Navigate back with success toast

  **Must NOT do**:
  - Do not show linked friends in pickers
  - Do not allow merging same friend with itself

  **Parallelizable**: YES (with 9, 10)

  **References**:
  - `apps/ios/PayBack/Sources/Features/Settings/SettingsView.swift` - Settings structure
  - `apps/ios/PayBack/Sources/DesignSystem/` - UI patterns

  **Acceptance Criteria**:
  - [ ] Test: Pickers only show unlinked friends
  - [ ] Test: Merge fails if either friend is linked
  - [ ] Test: Success updates friend list correctly
  - [ ] Manual: UI matches app style

  **Commit**: YES
  - Message: `feat(ios): add merge friends screen to Settings`
  - Files: `apps/ios/PayBack/Sources/Features/Settings/SettingsView.swift`, `apps/ios/PayBack/Sources/Features/Settings/MergeFriendsView.swift`
  - Pre-commit: `./scripts/test-ci-locally.sh`

---

### Phase 4: Nickname & Profile UI

- [ ] 9. Implement per-friend nickname preference toggle in FriendDetailView

  **What to do**:
  - Add "Prefer Nickname" toggle in friend profile below nickname field
  - Toggle updates `AccountFriend.preferNickname`
  - When toggled ON and no nickname set, auto-fill with `originalNickname` if available
  - When editing nickname, autofill text field with current or original nickname
  - Show "Original name: [originalName]" below linked friend's display name
  - Show "Previously known as: [originalNickname]" if nickname changed after linking

  **Must NOT do**:
  - Do not remove global showRealNames toggle
  - Do not auto-save on every keystroke (save on dismiss or explicit save)

  **Parallelizable**: YES (with 8, 10)

  **References**:
  - `apps/ios/PayBack/Sources/Features/People/FriendDetailView.swift` - Nickname editing sheet exists
  - `apps/ios/PayBack/Sources/Models/UserAccount.swift:AccountFriend` - Model from task 5

  **Acceptance Criteria**:
  - [ ] Test: Toggle updates preferNickname and persists
  - [ ] Test: Toggle ON with no nickname autofills originalNickname
  - [ ] Test: Edit nickname autofills current value
  - [ ] Test: Secondary display shows original name for linked friends
  - [ ] Manual: UI is clean and matches app style

  **Commit**: YES
  - Message: `feat(ios): add per-friend nickname preference toggle`
  - Files: `apps/ios/PayBack/Sources/Features/People/FriendDetailView.swift`
  - Pre-commit: `./scripts/test-ci-locally.sh`

---

### Phase 5: Deletion UI

- [ ] 10. Implement link-aware deletion UI with proper confirmations

  **What to do**:
  - Update delete confirmation in FriendsTabView:
    - For linked friend: "Remove [name] as a friend? Their account will remain, but your 1:1 expenses will be deleted."
    - For unlinked friend: "Delete [name]? This will remove them from all your groups and expenses."
  - Add extra confirmation if active (unsettled) direct expenses exist:
    - "You have [N] unsettled expenses with [name] totaling [amount]. Deleting will remove these. Continue?"
  - After deletion, show toast with summary
  - Ensure FriendDetailView delete button uses same logic

  **Must NOT do**:
  - Do not delete without at least one confirmation
  - Do not silently delete unsettled expenses

  **Parallelizable**: YES (with 8, 9)

  **References**:
  - `apps/ios/PayBack/Sources/Features/People/FriendsTabView.swift` - Current delete confirmation
  - `apps/ios/PayBack/Sources/Features/People/FriendDetailView.swift` - Delete button exists
  - `apps/ios/PayBack/Sources/Services/State/AppStore.swift:deleteFriend` - Current deletion logic

  **Acceptance Criteria**:
  - [ ] Test: Linked friend deletion shows correct message
  - [ ] Test: Unlinked friend deletion shows correct message
  - [ ] Test: Active expenses trigger extra confirmation
  - [ ] Test: Deletion calls correct backend mutation based on link status
  - [ ] Manual: Confirmation dialogs are clear and informative

  **Commit**: YES
  - Message: `feat(ios): implement link-aware deletion with proper confirmations`
  - Files: `apps/ios/PayBack/Sources/Features/People/FriendsTabView.swift`, `apps/ios/PayBack/Sources/Features/People/FriendDetailView.swift`, `apps/ios/PayBack/Sources/Services/State/AppStore.swift`
  - Pre-commit: `./scripts/test-ci-locally.sh`

---

- [ ] 11. Implement self-delete account flow

  **What to do**:
  - Add "Delete Account" option in Settings (under Account section, with red text)
  - Confirmation flow:
    - First: "Are you sure? This cannot be undone."
    - Second: "Your friends will still see expenses with you, but you'll be unlinked. Type DELETE to confirm."
  - On confirm, call backend `selfDeleteAccount`
  - Sign out and show "Account deleted" screen

  **Must NOT do**:
  - Do not delete without double confirmation
  - Do not delete expenses (they must persist)

  **Parallelizable**: NO (depends on 4)

  **References**:
  - `apps/ios/PayBack/Sources/Features/Settings/SettingsView.swift` - Settings structure
  - `convex/cleanup.ts:selfDeleteAccount` - Backend from task 4

  **Acceptance Criteria**:
  - [ ] Test: Delete requires typing "DELETE"
  - [ ] Test: Backend is called and user is signed out
  - [ ] Test: Friends of deleted user see them as unlinked
  - [ ] Manual: Flow is clear and not easily triggered accidentally

  **Commit**: YES
  - Message: `feat(ios): implement self-delete account flow`
  - Files: `apps/ios/PayBack/Sources/Features/Settings/SettingsView.swift`, `apps/ios/PayBack/Sources/Features/Settings/DeleteAccountView.swift`
  - Pre-commit: `./scripts/test-ci-locally.sh`

---

### Phase 6: Shared Unlinked Friends & Edge Cases

- [ ] 12. Handle shared unlinked friends across multiple users

  **What to do**:
  - **Global identity strategy**: Unlinked friends are identified by `member_id` (UUID generated on first creation). When user A adds "Bob" and user B adds the same person to a shared group, they get the SAME `member_id` by:
    - If adding via group: reuse existing member_id from group
    - If adding fresh: generate new UUID, but on merge later, alias maps them together
  - When user adds someone to a group who is another user's unlinked friend:
    - Create or reference the same underlying member record
    - Both users see same unlinked friend identity
  - If that unlinked friend later claims via invite link:
    - All users who have them as friend get updated simultaneously via `account_friends.linked_account_id`
    - Each user's nickname preferences preserved (stored per-user in `account_friends`)
  - In group member list, if viewing an unlinked friend who isn't your friend:
    - Show "Add to Friends" and "Merge with existing" options (from task 7)
  - **Dedupe on add**: Before creating new friend record, check if member_id already exists in any shared group

  **Must NOT do**:
  - Do not create duplicate member records for same person
  - Do not auto-merge without user consent

  **Parallelizable**: NO (depends on 3, 7)

  **References**:
  - `convex/groups.ts` - Group member handling
  - `apps/ios/PayBack/Sources/Features/Groups/` - Group member views
  - `apps/ios/PayBack/Sources/Services/State/AppStore.swift` - Friend sync

  **Acceptance Criteria**:
  - [ ] Test: Two users adding same unlinked person share member record
  - [ ] Test: Link claim updates all users' friend records
  - [ ] Test: Nickname preferences remain per-user after shared link
  - [ ] Manual: Group member profile shows correct options

  **Commit**: YES
  - Message: `feat: handle shared unlinked friends across users`
  - Files: `convex/groups.ts`, `convex/friends.ts`, `apps/ios/PayBack/Sources/Features/Groups/GroupDetailView.swift`
  - Pre-commit: `./scripts/test-ci-locally.sh`

---

- [ ] 13. Ensure direct groups display correctly in Activity

  **What to do**:
  - Verify direct groups (isDirect=true, 2 members, no name) show correctly in Activity
  - Direct group name should derive from other member's displayName (respecting nickname preference)
  - Ensure direct expenses appear in Activity feed alongside group expenses
  - If direct group's other member is deleted, handle gracefully (show "[Deleted]" or hide)

  **Must NOT do**:
  - Do not show direct groups in Groups tab (existing behavior, verify)
  - Do not break existing direct expense creation flow

  **Parallelizable**: YES (with 12)

  **References**:
  - `apps/ios/PayBack/Sources/Services/State/AppStore.swift:groupDisplayName` - Name derivation
  - `apps/ios/PayBack/Sources/Services/State/AppStore.swift:isDirectGroup` - Direct detection
  - `apps/ios/PayBack/Sources/Features/Activity/ActivityView.swift` - Activity view (NOT Dashboard)

  **Acceptance Criteria**:
  - [ ] Test: Direct group uses friend's display name (with nickname if preferred)
  - [ ] Test: Activity shows direct expenses correctly
  - [ ] Test: Deleted member shows gracefully
  - [ ] Manual: Activity dashboard looks correct with mixed group/direct expenses

  **Commit**: YES
  - Message: `fix(ios): ensure direct groups display correctly in Activity`
  - Files: `apps/ios/PayBack/Sources/Services/State/AppStore.swift`, `apps/ios/PayBack/Sources/Features/Activity/ActivityView.swift`
  - Pre-commit: `./scripts/test-ci-locally.sh`

---

### Phase 7: Integration Testing

- [ ] 14. Comprehensive integration tests for all linking scenarios

  **What to do**:
  - Add integration test suite covering:
    - perA adds local perB, sends invite, perB accepts and merges with existing local perA
    - perB already has expenses, gains perA's expenses after link
    - perC sees perB through shared group, adds as friend, perB links, perC updated
    - Delete linked friend removes friendship only
    - Delete unlinked friend removes all traces
    - Self-delete unlinks but preserves expenses
    - Nickname preference respected across all views
    - Hard DB delete cascades correctly
  - Test edge cases:
    - Link then unlink then re-link
    - Merge then delete merged friend
    - Multiple users merging same unlinked friend

  **Must NOT do**:
  - Do not skip any deletion scenario
  - Do not assume happy path only

  **Parallelizable**: NO (final integration)

  **References**:
  - `apps/ios/PayBack/Tests/Services/AppStoreLinkingTests.swift` - Existing link tests
  - `apps/ios/PayBack/Tests/Services/LinkStateReconciliationTests.swift` - Reconciliation tests
  - `apps/ios/PayBack/Tests/Validation/AccountLinkingSecurityTests.swift` - Security tests
  - **Creates new file**: `apps/ios/PayBack/Tests/Integration/AccountLinkingIntegrationTests.swift`

  **Acceptance Criteria**:
  - [ ] Test: All scenarios pass in XCTest
  - [ ] Test: No regressions in existing link tests
  - [ ] `./scripts/test-ci-locally.sh` passes with zero warnings
  - [ ] Manual: Full user journey walkthrough successful

  **Commit**: YES
  - Message: `test: comprehensive integration tests for account linking`
  - Files: `apps/ios/PayBack/Tests/Integration/AccountLinkingIntegrationTests.swift`
  - Pre-commit: `./scripts/test-ci-locally.sh`

---

## Commit Strategy

| After Task | Message | Files | Verification |
|------------|---------|-------|--------------|
| 1 | `feat(convex): add member_aliases table` | convex/schema.ts, convex/migrations.ts | bun test |
| 2 | `feat(convex): add alias resolution queries` | convex/aliases.ts, convex/groups.ts, convex/expenses.ts | bun test |
| 3 | `feat(convex): implement merge logic` | convex/aliases.ts, convex/friends.ts | bun test |
| 4 | `feat(convex): implement link-aware deletion` | convex/cleanup.ts, convex/friends.ts, convex/groups.ts, convex/expenses.ts | bun test |
| 5 | `feat(ios): add per-friend nickname preference` | UserAccount.swift | ./scripts/test-ci-locally.sh |
| 6 | `feat(ios): merge-with-existing in invite claim` | InviteLinkClaimView.swift | ./scripts/test-ci-locally.sh |
| 7 | `feat(ios): merge/add options for non-friends` | FriendDetailView.swift | ./scripts/test-ci-locally.sh |
| 8 | `feat(ios): merge friends screen in Settings` | SettingsView.swift, MergeFriendsView.swift | ./scripts/test-ci-locally.sh |
| 9 | `feat(ios): per-friend nickname toggle` | FriendDetailView.swift | ./scripts/test-ci-locally.sh |
| 10 | `feat(ios): link-aware deletion UI` | FriendsTabView.swift, FriendDetailView.swift, AppStore.swift | ./scripts/test-ci-locally.sh |
| 11 | `feat(ios): self-delete account flow` | SettingsView.swift, DeleteAccountView.swift | ./scripts/test-ci-locally.sh |
| 12 | `feat: shared unlinked friends` | convex/groups.ts, convex/friends.ts, GroupDetailView.swift | ./scripts/test-ci-locally.sh |
| 13 | `fix(ios): direct groups in Activity` | AppStore.swift, ActivityView.swift | ./scripts/test-ci-locally.sh |
| 14 | `test: account linking integration tests` | AccountLinkingIntegrationTests.swift | ./scripts/test-ci-locally.sh |

---

## Success Criteria

### Verification Commands
```bash
# Backend tests
cd convex && bun test  # Expected: All tests pass

# iOS tests
./scripts/test-ci-locally.sh  # Expected: 0 warnings, all tests pass
```

### Final Checklist
- [ ] All "Must Have" features implemented and tested
- [ ] All "Must NOT Have" guardrails respected
- [ ] All 14 tasks completed with passing tests
- [ ] No regressions in existing functionality
- [ ] UI matches existing app style throughout
