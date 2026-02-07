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
