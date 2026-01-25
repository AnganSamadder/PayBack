<file>
00001| # Learnings: Account Linking Feature
00002| 
00003| ## Schema Patterns Discovered
00004| 
00005| ### Table Definition Style
00006| - Tables use `defineTable()` with field validators from `v` module
00007| - Indexes defined via chained `.index("name", ["field1", "field2"])` 
00008| - Optional fields use `v.optional(v.type())`
00009| - UUID strings stored as `v.string()` not native IDs
00010| - Timestamps stored as `v.number()` (epoch ms)
00011| 
00012| ### Existing account_friends Structure
00013| - `member_id`: UUID linking to group members
00014| - `has_linked_account`: boolean flag for linked status
00015| - `linked_account_id` / `linked_account_email`: link details
00016| - `original_name`: preserved before linking for "Originally X" display
00017| - `nickname`: user-assigned nickname for friend
00018| 
00019| ### Migration Patterns
00020| - Migrations are exported mutations in `migrations.ts`
00021| - Return stats object: `{ updated: number, created: number, ... }`
00022| - Use `ctx.db.patch()` for updates, `ctx.db.insert()` for creates
00023| - Query patterns: `.query("table").withIndex().collect()` or `.first()`
00024| 
00025| ## Schema Changes Made
00026| 
00027| ### New `member_aliases` Table
00028| ```typescript
00029| member_aliases: defineTable({
00030|   canonical_member_id: v.string(),  // The "real" member ID
00031|   alias_member_id: v.string(),      // ID that aliases to canonical
00032|   account_email: v.string(),        // Account that created alias
00033|   created_at: v.number(),
00034| })
00035|   .index("by_alias_member_id", ["alias_member_id"])
00036|   .index("by_canonical_member_id", ["canonical_member_id"])
00037| ```
00038| 
00039| ### New Fields in `account_friends`
00040| - `original_nickname: v.optional(v.string())` - nickname before linking
00041| - `prefer_nickname: v.optional(v.boolean())` - toggle for display preference
00042| 
00043| ## Canonical/Alias Invariant
00044| - When receiver claims invite AND already has `linked_member_id`:
00045|   - Receiver's existing ID = canonical
00046|   - Sender's target_member_id = alias pointing to canonical
00047| - Transitive: A->B and B->C means A resolves to C
00048| - Cycle prevention required during alias creation
00049| 
00050| ## Convex-Specific Notes
00051| - No tsconfig.json in this project
00052| - `bunx convex dev --once` handles type checking during deployment
00053| - Must run from project root (where package.json lives), not convex/ subdirectory
00054| - No bun tests exist for convex functions yet
00055| 
00056| ## Alias Resolution Implementation (Task 2)
00057| 
00058| ### Created: convex/aliases.ts
00059| - `resolveCanonicalMemberIdInternal(db, memberId, visited?)` - Helper for transitive resolution with cycle protection
00060| - `resolveCanonicalMemberId` - Public query wrapping internal helper
00061| - `resolveCanonicalMemberIdInternalQuery` - Internal query for Convex function use
00062| - `getAliasesForMember` - Reverse lookup: find all aliases pointing to canonical
00063| - `getAllEquivalentMemberIds(db, memberId)` - Returns canonical + all aliases (for membership checks)
00064| 
00065| ### Integration Pattern
00066| Groups & Expenses use `getAllEquivalentMemberIds()` instead of direct ID comparison:
00067| ```typescript
00068| // Before:
00069| g.members.some(m => m.id === user.linked_member_id)
00070| 
00071| // After:
00072| const equivalentIds = await getAllEquivalentMemberIds(ctx.db, user.linked_member_id);
00073| g.members.some(m => equivalentIds.includes(m.id))
00074| ```
00075| 
00076| ### Key Design Decisions
00077| 1. Cycle protection via `visited: Set<string>` - returns input on cycle detection
00078| 2. No-alias case returns input unchanged (identity behavior)
00079| 3. `getAllEquivalentMemberIds` includes original input ID for edge cases
00080| 4. Recursive resolution ensures A→B→C resolves A to C
00081| 
00082| ### Pre-existing LSP Errors
00083| - forEach() callback return value warnings in groups.ts/expenses.ts (lines 149-153, 250-253)
00084| - These are linting warnings about Map.set() return values in forEach - not blocking deployment
00085| 
00086| ## Merge Logic Implementation (Task 3)
00087| 
00088| ### Added Mutations to convex/aliases.ts
00089| 
00090| #### `mergeMemberIds(sourceId, targetCanonicalId, accountEmail)`
00091| - Creates alias mapping source → target (resolved to canonical)
00092| - **Idempotency**: If alias already exists to same target, returns success without error
00093| - **Cycle detection**: Uses `wouldCreateCycle()` helper to check if target resolves to source
00094| - **Conflict handling**: Throws if source already aliases to a DIFFERENT target
00095| - **Self-merge**: Treated as no-op, returns `already_existed: true`
00096| - Returns `{ success, already_existed, message, alias }` object
00097| 
00098| #### `mergeUnlinkedFriends(friendId1, friendId2, accountEmail)`
00099| - High-level mutation for settings UI merge flow
00100| - **Guard**: Rejects if EITHER friend has `has_linked_account = true`
00101| - Makes friendId1 the canonical, friendId2 becomes alias
00102| - Uses same idempotency and cycle detection as `mergeMemberIds`
00103| - Returns `{ success, already_merged, message, canonical_member_id, alias_member_id }`
00104| 
00105| ### Concurrency Handling
00106| - Convex mutations are transactional (ACID within single mutation)
00107| - If two concurrent merges attempt same sourceId:
00108|   - First write wins and creates alias
00109|   - Second call detects existing alias via index lookup
00110|   - Returns idempotent success if targets match, error if conflict
00111| 
00112| ### Key Pattern: Index-Based Idempotency
00113| ```typescript
00114| const existingAlias = await ctx.db
00115|   .query("member_aliases")
00116|   .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", sourceId))
00117|   .first();
00118| 
00119| if (existingAlias) {
00120|   // Check if resolves to same canonical - if so, idempotent success
00121|   const existingTarget = await resolveCanonicalMemberIdInternal(...);
00122|   const newTarget = await resolveCanonicalMemberIdInternal(...);
00123|   if (existingTarget === newTarget) return { already_existed: true, ... };
00124| }
00125| ```
00126| 
00127| ### Why No Direct Expense/Group Updates
00128| - Groups and Expenses already use `getAllEquivalentMemberIds()` for lookups (Task 2)
00129| - Creating alias automatically makes old member ID resolve correctly
00130| - No backfill needed - reads dynamically resolve aliases
00131| 
00132| ## Link-Aware Deletion Implementation (Task 5)
00133| 
00134| ### Added Mutations to convex/cleanup.ts
00135| 
00136| #### `deleteLinkedFriend(friendMemberId, accountEmail)`
00137| - Removes friend record from `account_friends` only
00138| - Does NOT delete the linked account (it exists independently)
00139| - Deletes direct group (`is_direct: true`) between the two users
00140| - Cascades to delete all expenses in that direct group
00141| - Returns `{ success, directGroupDeleted, expensesDeleted, linkedAccountPreserved }`
00142| - **Guard**: Rejects if friend is NOT linked (use deleteUnlinkedFriend instead)
00143| 
00144| #### `deleteUnlinkedFriend(friendMemberId, accountEmail)`
00145| - Full cascade removal of all traces
00146| - Removes friend from `account_friends`
00147| - Removes from all owned groups (updates members array)
00148| - Handles expense cleanup:
00149|   - If removing friend leaves ≤1 participant: delete expense
00150|   - Otherwise: remove friend from splits, participants, involved_member_ids
00151| - Deletes all member_aliases (both as canonical and as alias)
00152| - Returns `{ success, groupsModified, expensesDeleted, expensesModified, aliasesDeleted }`
00153| - **Guard**: Rejects if friend IS linked (use deleteLinkedFriend instead)
00154| 
00155| #### `hardDeleteAccount(accountId)` - internalMutation
00156| - **Not client-callable** - uses `internalMutation` for admin/DB cleanup only
00157| - Takes Convex document ID (`v.id("accounts")`) not email
00158| - Full cascade: all friends, owned groups, all group expenses, owned expenses, member_aliases
00159| - Returns stats: `{ friendsDeleted, groupsDeleted, expensesDeleted, aliasesDeleted }`
00160| 
00161| #### `selfDeleteAccount(accountEmail)`
00162| - User-initiated account deletion with debt preservation
00163| - **Unlinks** all friend records pointing to this account:
00164|   - Finds friends via `linked_account_email` or `linked_account_id`
00165|   - Sets `has_linked_account: false` and clears link fields
00166| - Does NOT delete expenses (debt must remain for other users)
00167| - Returns `{ success, friendshipsUnlinked, expensesPreserved: true }`
00168| 
00169| ### Design Decisions
00170| 
00171| 1. **Linked vs Unlinked separation** - Different cascading rules prevent data loss
00172| 2. **internalMutation for hardDeleteAccount** - Security: prevents client abuse
00173| 3. **Expense preservation on self-delete** - Other users still need debt records
00174| 4. **Alias cleanup on unlinked deletion** - Clean slate when removing "ghost" friends
00175| 5. **getAllEquivalentMemberIds integration** - Catches aliased member IDs in cleanup
00176| 
00177| ## iOS AccountFriend Model Update (Task 4)
00178| 
00179| ### New Fields Added
00180| - `originalNickname: String?` - Preserves nickname before linking (for restore on unlink)
00181| - `preferNickname: Bool` - Per-friend toggle overriding global `showRealNames` setting
00182| 
00183| ### Updated Logic: displayName(showRealNames:)
00184| Priority order:
00185| 1. If `preferNickname == true` AND nickname exists: always return nickname
00186| 2. If unlinked friend: return name
00187| 3. If linked but no nickname: return name
00188| 4. Otherwise: use global `showRealNames` preference
00189| 
00190| ### Updated Logic: secondaryDisplayName(showRealNames:)
00191| Same priority for `preferNickname`:
00192| - If `preferNickname == true` AND nickname exists: return real name as secondary
00193| - Otherwise follows existing logic for global preference
00194| 
00195| ### Codable Backward Compatibility
00196| - `preferNickname` defaults to `false` via `decodeIfPresent(...) ?? false`
00197| - `originalNickname` uses standard optional decode
00198| - Existing data without these fields decodes correctly
00199| 
00200| ### Build Notes
00201| - XcodeGen generates project from `project.yml` at repo root
00202| - Must run `xcodegen generate` before `xcodebuild` if `.xcodeproj` missing
00203| 
00204| ## Merge Flow Implementation (Task 6)
00205| - Added `mergeMemberIds` to `AccountService` protocol and implementations (`ConvexAccountService` uses `aliases:mergeMemberIds` mutation).
00206| - Added `mergeFriend` to `AppStore` to handle UI-triggered merges.
00207| - Updated `InviteLinkClaimView` to intercept the claim success and check for unlinked friends with similar names.
00208| - Implemented a "Merge Contacts?" sheet that allows the user to merge an unlinked friend into the newly linked creator friend.
00209| - If merge succeeds, the success message is updated to reflect the merge.
00210| - If merge fails or user skips, the flow completes as a normal claim.
00211| - Used `localizedCaseInsensitiveContains` for name similarity matching.
00212| - Handled edge cases where the creator friend might not be immediately found in the local store by logging and skipping the merge (safer than blocking).
00213| 
00214| ## FriendDetailView Non-Friend Actions (Task 7)
00215| - Implemented "Add Friend" and "Merge with Existing Friend" for non-friend profiles (e.g., viewed from a group).
00216| - Used `isFriend` computed property to toggle between "Invite Link" (for existing friends) and "Add/Merge" actions (for non-friends).
00217| - Leveraged `store.addImportedFriend` to convert a `GroupMember` to an `AccountFriend`.
00218| - Implemented merge flow using `store.mergeFriend(unlinkedMemberId:into:)`.
00219| - Note: Since the source member ID effectively ceases to exist after merge, we navigate back (`onBack()`) upon success to avoid showing stale data.
00220| - Reused `AccountFriend` init from `GroupMember` data.
</file>