# Learnings: Account Linking Feature

## Schema Patterns Discovered

### Table Definition Style
- Tables use `defineTable()` with field validators from `v` module
- Indexes defined via chained `.index("name", ["field1", "field2"])` 
- Optional fields use `v.optional(v.type())`
- UUID strings stored as `v.string()` not native IDs
- Timestamps stored as `v.number()` (epoch ms)

### Existing account_friends Structure
- `member_id`: UUID linking to group members
- `has_linked_account`: boolean flag for linked status
- `linked_account_id` / `linked_account_email`: link details
- `original_name`: preserved before linking for "Originally X" display
- `nickname`: user-assigned nickname for friend

### Migration Patterns
- Migrations are exported mutations in `migrations.ts`
- Return stats object: `{ updated: number, created: number, ... }`
- Use `ctx.db.patch()` for updates, `ctx.db.insert()` for creates
- Query patterns: `.query("table").withIndex().collect()` or `.first()`

## Schema Changes Made

### New `member_aliases` Table
```typescript
member_aliases: defineTable({
  canonical_member_id: v.string(),  // The "real" member ID
  alias_member_id: v.string(),      // ID that aliases to canonical
  account_email: v.string(),        // Account that created alias
  created_at: v.number(),
})
  .index("by_alias_member_id", ["alias_member_id"])
  .index("by_canonical_member_id", ["canonical_member_id"])
```

### New Fields in `account_friends`
- `original_nickname: v.optional(v.string())` - nickname before linking
- `prefer_nickname: v.optional(v.boolean())` - toggle for display preference

## Canonical/Alias Invariant
- When receiver claims invite AND already has `linked_member_id`:
  - Receiver's existing ID = canonical
  - Sender's target_member_id = alias pointing to canonical
- Transitive: A->B and B->C means A resolves to C
- Cycle prevention required during alias creation

## Convex-Specific Notes
- No tsconfig.json in this project
- `bunx convex dev --once` handles type checking during deployment
- Must run from project root (where package.json lives), not convex/ subdirectory
- No bun tests exist for convex functions yet

## Alias Resolution Implementation (Task 2)

### Created: convex/aliases.ts
- `resolveCanonicalMemberIdInternal(db, memberId, visited?)` - Helper for transitive resolution with cycle protection
- `resolveCanonicalMemberId` - Public query wrapping internal helper
- `resolveCanonicalMemberIdInternalQuery` - Internal query for Convex function use
- `getAliasesForMember` - Reverse lookup: find all aliases pointing to canonical
- `getAllEquivalentMemberIds(db, memberId)` - Returns canonical + all aliases (for membership checks)

### Integration Pattern
Groups & Expenses use `getAllEquivalentMemberIds()` instead of direct ID comparison:
```typescript
// Before:
g.members.some(m => m.id === user.linked_member_id)

// After:
const equivalentIds = await getAllEquivalentMemberIds(ctx.db, user.linked_member_id);
g.members.some(m => equivalentIds.includes(m.id))
```

### Key Design Decisions
1. Cycle protection via `visited: Set<string>` - returns input on cycle detection
2. No-alias case returns input unchanged (identity behavior)
3. `getAllEquivalentMemberIds` includes original input ID for edge cases
4. Recursive resolution ensures A→B→C resolves A to C

### Pre-existing LSP Errors
- forEach() callback return value warnings in groups.ts/expenses.ts (lines 149-153, 250-253)
- These are linting warnings about Map.set() return values in forEach - not blocking deployment

## Merge Logic Implementation (Task 3)

### Added Mutations to convex/aliases.ts

#### `mergeMemberIds(sourceId, targetCanonicalId, accountEmail)`
- Creates alias mapping source → target (resolved to canonical)
- **Idempotency**: If alias already exists to same target, returns success without error
- **Cycle detection**: Uses `wouldCreateCycle()` helper to check if target resolves to source
- **Conflict handling**: Throws if source already aliases to a DIFFERENT target
- **Self-merge**: Treated as no-op, returns `already_existed: true`
- Returns `{ success, already_existed, message, alias }` object

#### `mergeUnlinkedFriends(friendId1, friendId2, accountEmail)`
- High-level mutation for settings UI merge flow
- **Guard**: Rejects if EITHER friend has `has_linked_account = true`
- Makes friendId1 the canonical, friendId2 becomes alias
- Uses same idempotency and cycle detection as `mergeMemberIds`
- Returns `{ success, already_merged, message, canonical_member_id, alias_member_id }`

### Concurrency Handling
- Convex mutations are transactional (ACID within single mutation)
- If two concurrent merges attempt same sourceId:
  - First write wins and creates alias
  - Second call detects existing alias via index lookup
  - Returns idempotent success if targets match, error if conflict

### Key Pattern: Index-Based Idempotency
```typescript
const existingAlias = await ctx.db
  .query("member_aliases")
  .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", sourceId))
  .first();

if (existingAlias) {
  // Check if resolves to same canonical - if so, idempotent success
  const existingTarget = await resolveCanonicalMemberIdInternal(...);
  const newTarget = await resolveCanonicalMemberIdInternal(...);
  if (existingTarget === newTarget) return { already_existed: true, ... };
}
```

### Why No Direct Expense/Group Updates
- Groups and Expenses already use `getAllEquivalentMemberIds()` for lookups (Task 2)
- Creating alias automatically makes old member ID resolve correctly
- No backfill needed - reads dynamically resolve aliases

## Link-Aware Deletion Implementation (Task 5)

### Added Mutations to convex/cleanup.ts

#### `deleteLinkedFriend(friendMemberId, accountEmail)`
- Removes friend record from `account_friends` only
- Does NOT delete the linked account (it exists independently)
- Deletes direct group (`is_direct: true`) between the two users
- Cascades to delete all expenses in that direct group
- Returns `{ success, directGroupDeleted, expensesDeleted, linkedAccountPreserved }`
- **Guard**: Rejects if friend is NOT linked (use deleteUnlinkedFriend instead)

#### `deleteUnlinkedFriend(friendMemberId, accountEmail)`
- Full cascade removal of all traces
- Removes friend from `account_friends`
- Removes from all owned groups (updates members array)
- Handles expense cleanup:
  - If removing friend leaves ≤1 participant: delete expense
  - Otherwise: remove friend from splits, participants, involved_member_ids
- Deletes all member_aliases (both as canonical and as alias)
- Returns `{ success, groupsModified, expensesDeleted, expensesModified, aliasesDeleted }`
- **Guard**: Rejects if friend IS linked (use deleteLinkedFriend instead)

#### `hardDeleteAccount(accountId)` - internalMutation
- **Not client-callable** - uses `internalMutation` for admin/DB cleanup only
- Takes Convex document ID (`v.id("accounts")`) not email
- Full cascade: all friends, owned groups, all group expenses, owned expenses, member_aliases
- Returns stats: `{ friendsDeleted, groupsDeleted, expensesDeleted, aliasesDeleted }`

#### `selfDeleteAccount(accountEmail)`
- User-initiated account deletion with debt preservation
- **Unlinks** all friend records pointing to this account:
  - Finds friends via `linked_account_email` or `linked_account_id`
  - Sets `has_linked_account: false` and clears link fields
- Does NOT delete expenses (debt must remain for other users)
- Returns `{ success, friendshipsUnlinked, expensesPreserved: true }`

### Design Decisions

1. **Linked vs Unlinked separation** - Different cascading rules prevent data loss
2. **internalMutation for hardDeleteAccount** - Security: prevents client abuse
3. **Expense preservation on self-delete** - Other users still need debt records
4. **Alias cleanup on unlinked deletion** - Clean slate when removing "ghost" friends
5. **getAllEquivalentMemberIds integration** - Catches aliased member IDs in cleanup

## iOS AccountFriend Model Update (Task 4)

### New Fields Added
- `originalNickname: String?` - Preserves nickname before linking (for restore on unlink)
- `preferNickname: Bool` - Per-friend toggle overriding global `showRealNames` setting

### Updated Logic: displayName(showRealNames:)
Priority order:
1. If `preferNickname == true` AND nickname exists: always return nickname
2. If unlinked friend: return name
3. If linked but no nickname: return name
4. Otherwise: use global `showRealNames` preference

### Updated Logic: secondaryDisplayName(showRealNames:)
Same priority for `preferNickname`:
- If `preferNickname == true` AND nickname exists: return real name as secondary
- Otherwise follows existing logic for global preference

### Codable Backward Compatibility
- `preferNickname` defaults to `false` via `decodeIfPresent(...) ?? false`
- `originalNickname` uses standard optional decode
- Existing data without these fields decodes correctly

### Build Notes
- XcodeGen generates project from `project.yml` at repo root
- Must run `xcodegen generate` before `xcodebuild` if `.xcodeproj` missing

## Merge Flow Implementation (Task 6)
- Added `mergeMemberIds` to `AccountService` protocol and implementations (`ConvexAccountService` uses `aliases:mergeMemberIds` mutation).
- Added `mergeFriend` to `AppStore` to handle UI-triggered merges.
- Updated `InviteLinkClaimView` to intercept the claim success and check for unlinked friends with similar names.
- Implemented a "Merge Contacts?" sheet that allows the user to merge an unlinked friend into the newly linked creator friend.
- If merge succeeds, the success message is updated to reflect the merge.
- If merge fails or user skips, the flow completes as a normal claim.
- Used `localizedCaseInsensitiveContains` for name similarity matching.
- Handled edge cases where the creator friend might not be immediately found in the local store by logging and skipping the merge (safer than blocking).

## FriendDetailView Non-Friend Actions (Task 7)
- Implemented "Add Friend" and "Merge with Existing Friend" for non-friend profiles (e.g., viewed from a group).
- Used `isFriend` computed property to toggle between "Invite Link" (for existing friends) and "Add/Merge" actions (for non-friends).
- Leveraged `store.addImportedFriend` to convert a `GroupMember` to an `AccountFriend`.
- Implemented merge flow using `store.mergeFriend(unlinkedMemberId:into:)`.
- Note: Since the source member ID effectively ceases to exist after merge, we navigate back (`onBack()`) upon success to avoid showing stale data.
- Reused `AccountFriend` init from `GroupMember` data.

## Merge Friends Implementation (Settings)
- Added `MergeFriendsView` to merge unlinked friends.
- Used `store.friends.filter { !$0.hasLinkedAccount }` to filter candidates.
- `AppStore.mergeFriend` uses `AccountService.mergeMemberIds`, which required updating mocks in `AuthCoordinatorTests` and `MockAccountService`.
- Added "Data Management" section to `SettingsView` for this feature.
- **Critical**: When adding new service methods, ensure ALL mocks (Test doubles and Preview mocks) are updated, otherwise tests will fail to compile.

## Per-Friend Nickname Preference (Task 8)

### Implementation
- Added `preferNickname` (Bool) to `AccountFriend` model (updates `UserAccount.swift`).
- Added `updateFriendPreferNickname` to `AppStore` to persist preference.
- Updated `FriendDetailView`:
  - Added toggle for "Prefer Nickname" in nickname edit sheet.
  - Implemented auto-fill logic: toggling ON with empty nickname fills `originalNickname`.
  - Updated `heroBalanceCard` display logic to respect `preferNickname` override.
  - Shows "Original name: X" and "Previously known as: Y" for linked friends with history.

### Display Logic Hierarchy
1. If linked + has nickname + `preferNickname=true`: Primary = Nickname, Secondary = Real Name.
2. If linked + has nickname + `preferNickname=false`: Primary = Real Name, Secondary = "aka [Nickname]".
3. If linked + no nickname: Primary = Real Name.
4. If unlinked: Primary = Name (which is the local nickname).

### UX Considerations
- Toggle state initializes from friend data when sheet opens.
- Changes to toggle don't save until "Save" button is pressed (atomic update with nickname).
- "Original name" only shows if it differs from current display names to avoid redundancy.
