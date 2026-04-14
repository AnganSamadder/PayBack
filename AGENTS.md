# PAYBACK AGENT OPERATING MANUAL

**Living document:** keep this file current by converting recurring failures into durable operating rules.
Do not write incident narratives or changelog-style entries here.

**Validation stamp:** audited against this repository on 2026-02-23.

## 1) Product and Repository Overview

PayBack is an expense-sharing app with:

- Native iOS app in Swift (MVVM + Central Store)
- Convex backend in TypeScript
- Web landing page (Vite + React)

Repository structure:

```text
.
├── apps/web/          # Vite + React landing page
├── apps/backend/      # Convex backend (schema, functions, auth)
├── apps/ios/PayBack/  # Native iOS application
├── apps/android/      # Android scaffold (placeholder)
├── packages/          # Shared config packages (eslint, prettier, typescript, design-tokens)
└── scripts/           # CI/CD utilities
```

### Where to look first

| Task | Location | Notes |
| --- | --- | --- |
| iOS UI/Views | `apps/ios/PayBack/Sources/Features` | Organized by domain |
| iOS State | `apps/ios/PayBack/Sources/Services/State` | `AppStore.swift` is the God Object |
| Backend Schema | `apps/backend/convex/schema.ts` | Source of truth for data model |
| Backend Logic | `apps/backend/convex/` | Mutations, queries, actions |
| Backend Tests | `apps/backend/convex/tests/` | Integration focused |
| iOS Tests | `apps/ios/PayBack/Tests` | Unit + integration |
| Web App | `apps/web/src/` | Vite + React + TanStack Router |
| iOS Design System | `apps/ios/PayBack/Sources/DesignSystem` | Shared iOS components |

### Operational notes

- iOS architecture is Central Store-first; avoid local `@State` for shared/cross-screen data.
- `accounts` is backend user source of truth; ghost-account handling flows through `bulkImport`.
- Convex function root is `apps/backend/convex/` via root `convex.json`.
- Monorepo workspace roots are `apps/*` and `packages/*`; run workspace checks from repo root (`bun run ci`).

## 2) Commands and Quality Gates

```bash
# Monorepo Development
bun run dev            # Start web + convex backend together
bun run dev:web        # Web only (Vite)
bun run dev:backend    # Convex backend only

# Quality Checks
bun run lint           # ESLint across all workspaces
bun run lint:fix       # ESLint with --fix
bun run format         # Prettier --write
bun run format:check   # Prettier --check (CI mode)
bun run typecheck      # TypeScript check

# Testing
bun run test           # Vitest across workspaces
bun run ci             # Full local CI pipeline

# iOS (Full CI Simulation)
./scripts/test-ci-locally.sh

# iOS Build (manual)
xcodebuild -scheme PayBack -destination "platform=iOS Simulator,name=iPhone 15"
```

### Local sanitizer testing

Run sanitizers locally before pushing. CI sanitizer runs happen only on merges to `main`, so local runs are first-line defense.

```bash
# Thread Sanitizer (data races)
SANITIZER=thread ./scripts/test-ci-locally.sh

# Address Sanitizer (memory issues)
SANITIZER=address ./scripts/test-ci-locally.sh

# Standard run with coverage (PR-like)
./scripts/test-ci-locally.sh
```

Run requirements:

- Always run `SANITIZER=thread` before pushing concurrency changes (`async/await`, actors, `@State`, `@Published`).
- Always run `SANITIZER=address` before pushing data-structure or memory-sensitive changes.
- Run both sanitizers before any PR touching `AppStore`, `Services/`, or `Concurrency/`.

## 3) Core Engineering Conventions

- **Push policy:** Never run `git push` unless the user explicitly asks.
- **Commit format:** Conventional Commits (`feat:`, `fix:`), single-line message.
- **Lint policy:** zero warnings (`FAIL_ON_WARNINGS=1`).
- **Runtime/tooling:** prefer `bun` / `bunx` over `npm`.
- **Monorepo:** Turborepo for orchestration, Bun workspaces for dependencies.
- **Comments:** explain _why_ only when non-obvious; avoid restating code behavior.
- **iOS project editing:** never edit `project.pbxproj` directly.

## 4) XcodeGen is the Single Source of Truth

`project.yml` owns all Xcode project configuration. `project.pbxproj` is generated.

Mandatory workflow:

1. Edit `project.yml`
2. Run `xcodegen generate` every time

```bash
xcodegen generate
```

This applies to build numbers, versions, flags, Info.plist, entitlements, schemes, SPM dependencies, targets, and configs.

### Common mapping

| Change needed | Where in `project.yml` | Example |
| --- | --- | --- |
| Build number | `settings.base.CURRENT_PROJECT_VERSION` | `95` |
| App version | `settings.base.MARKETING_VERSION` | `1.2.0` |
| Project-wide build setting | `settings.base` | `SWIFT_VERSION: "5.10"` |
| Config-specific setting | `settings.configs.Debug` | `GCC_OPTIMIZATION_LEVEL: 0` |
| Target-specific setting | `targets.PayBack.settings.base` | `PRODUCT_BUNDLE_IDENTIFIER` |
| Info.plist key | `targets.PayBack.info.properties` | `ITSAppUsesNonExemptEncryption: false` |
| Add SPM dependency | `packages` | `url: https://github.com/...` |
| New build configuration | `configs` | `Internal: release` |
| Scheme settings | `schemes.PayBack` | `archive.config: Release` |
| Entitlements | `targets.PayBack.entitlements.properties` | `com.apple.developer.associated-domains` |

## 5) CI Parity, Warnings, Simulator, Coverage

- `./scripts/test-ci-locally.sh` is the canonical local CI parity script for iOS.
- Keep it in lockstep with `.github/workflows/ci.yml` (steps, flags, simulator selection, coverage settings).
- If CI workflow changes, update the script in the same change.

Warning policy:

- Runs must be warning-free.
- Use `FAIL_ON_WARNINGS=1 ./scripts/test-ci-locally.sh` before pushing.
- If warnings are non-actionable tool output, adjust script filtering; do not normalize warnings in product code.

Simulator selection:

- CI picks newest iOS runtime with preferred iPhone models.
- Local parity should rely on `./scripts/test-ci-locally.sh` logic.
- Manual fallback: `xcrun simctl list devices iPhone available`, then pick a matching UDID.

Coverage:

- Coverage expected when `SANITIZER=none`.
- Outputs: `coverage.json`, `coverage-report.txt`.
- CI threshold: `48.0%`.

## 6) Swift Coding Rules

### Imports

- Keep imports minimal and file-scoped.
- Order: Apple frameworks, third-party, internal modules.
- Remove unused imports.

### Formatting

- Keep existing Swift formatting style (4-space indentation).
- Prefer trailing closures when readability improves.
- Align SwiftUI chained modifiers vertically.

### Naming

- Types: `UpperCamelCase`.
- Variables/functions: `lowerCamelCase`.
- Booleans should read naturally (`isValid`, `hasAccount`, `shouldSync`).

### SwiftUI architecture

- Keep views small and composable.
- Use private computed subviews for complex layouts.
- Use `@State`, `@StateObject`, and `@EnvironmentObject` consistently with existing patterns.

### Error and concurrency handling

- Prefer typed errors (`enum ...: Error`) over string errors.
- Keep user-facing errors sanitized (no PII).
- Respect actor isolation.
- Prefer `async`/`await` over new completion-callback code.

## 7) Domain Data Contracts and Identity Invariants

### 7.1 Deletion protocol

#### Hard delete (admin/backend path)

When hard deleting from Convex dashboard or via `performHardDelete`:

1. Delete the user’s `accounts` record.
2. Delete all `account_friends` rows owned by the user.
3. Cascade cleanup for other users via indexes:
   - `by_linked_account_id`
   - `by_linked_account_email`
   - `by_linked_member_id` (rule provenance: added 2026-02-07)
4. Deleted user should disappear from friend lists immediately via live sync.

#### Soft delete (user-initiated)

1. Mark account as deleted (soft delete flag).
2. User becomes a Ghost; historical data remains.
3. Friends should see user as unlinked while preserving past transactions.
4. Display fallback name should be friend nickname or original name, never `"Unknown"`.

Core tables/indexes:

- `accounts` is user source of truth.
- `account_friends` holds friend relationships and optional account links.
- Link indexes: `by_linked_account_id`, `by_linked_account_email`, `by_linked_member_id`.

### 7.2 Member-ID equivalence rules (iOS, provenance: 2026-02-07)

After CSV import, a group member `id` can differ from corresponding friend `memberId`.

Required model contract:

- `GroupMember.accountFriendMemberId: UUID?` stores original friend `memberId`.

Required lookup contract:

```swift
let lookupId = friend.accountFriendMemberId ?? friend.id
return store.friends.contains { $0.memberId == lookupId }
```

Import consistency contract (`DataImportService.swift`):

1. Check `memberIdMapping` before generating UUIDs.
2. Use `nameToExistingId` for name-based dedupe.
3. Same person must map to same UUID across friends and group members.

### 7.3 CSV import + Convex remapping contract (provenance: 2026-02-07)

Use remapped IDs end-to-end; never mix remapped local IDs with original CSV IDs across boundaries.

Failure signature:

- Local iOS stores Group `ABC` (remapped) while Convex stores Group `XYZ` (original CSV), causing sync breakage because iOS does not recognize backend IDs.

Protocol:

1. `importData` creates `memberIdMapping` and `groupIdMapping` (`Original -> New`).
2. `applyRemappings()` mutates parsed import data.
3. `performBulkImport` sends remapped UUIDs to Convex.
4. Local iOS and backend must persist identical UUIDs.

Rule: always pass `memberIdMapping` and `groupIdMapping` into `performBulkImport`.

### 7.4 Balance calculation identity contract (provenance: 2026-02-07)

Balance and split attribution must use identity equivalence, not single raw IDs.

Failure signature:

- Users can see `Settled ($0.00)` while unsettled transactions still exist.

Required checks:

1. `FriendDetailView.netBalance` checks both `friend.id` and `friend.accountFriendMemberId`.
2. `AppStore.netBalance(for:)` uses `currentUser.equivalentMemberIds`.

Rule: all balance/filter logic must include equivalence IDs (`accountFriendMemberId`, `equivalentMemberIds`).

### 7.5 Linking pipeline contract

Purpose: link local unlinked friend identities to registered accounts while preserving financial history.

Flow:

1. User A creates invite for member ID `X`.
2. User B claims invite (`inviteTokens:claim`).
3. Backend updates User B `alias_member_ids` to include `X`.
4. Backend updates User A `account_friends` row to set `linked_account_id` to User B account ID.
5. Sync result:
   - User B receives updated `UserAccount` with `alias_member_ids`.
   - User A receives updated `account_friends`.

Required identity mapping:

- `UserAccount` must map JSON `alias_member_ids` to Swift `equivalentMemberIds` via `CodingKeys`.
- `AppStore.isMe(memberId)` must check `currentUser.id`, `linkedMemberId`, and `equivalentMemberIds`.

### 7.6 Friend dedupe and identity map rules (provenance: 2026-02-07, 2026-02-10)

Backend enrichment requirement:

- `friends.ts` must include linked user `alias_member_ids` in `AccountFriend` payloads.

Failure signatures:

- Duplicate person cards appear (`linked` + `unlinked`) for the same user.
- Reappears after account switch/login if stale sync writes pre-dedupe data.

Common duplication source:

- Backend responses can include both original and linked friend rows when records coexist across `account_friends` and group-related identity surfaces.

Client rules:

1. Build `memberAliasMap` during friend updates.
2. If Friend B lists Friend A in `aliasMemberIds`, Friend B is canonical, A is alias.
3. `AppStore.processFriendsUpdate` must drop alias duplicates.
4. Keep only canonical linked friend in `store.friends`.
5. `store.areSamePerson(id1,id2)` must resolve through `memberAliasMap`.

Sync/write rules:

1. `AppStore.scheduleFriendSync` must sync deduped `self.friends` only (after `processFriendsUpdate`).
2. Convex DTO mapping must treat `linked_member_id` as alias fallback when `alias_member_ids` is sparse.
3. `friendMembers` dedupe must use `areSamePerson(...)`, never raw UUID equality.

### 7.7 Direct-expense friendship drift guard (provenance: 2026-02-11)

Failure signatures to recognize:

- `Member <name> is not a confirmed friend`
- Creator sees direct expense but counterparty does not (missing `participant_emails`)

Required backend behavior:

1. In `expenses.ts`, resolve participant account identity server-side (email/id/member_id).
2. Populate `participant_emails` from resolved accounts, not only client payload.
3. In direct-expense friend validation, use identity-based matching first.
4. Allow narrow legacy fallback by unique normalized friend name when IDs drift.
5. In `friends.ts` upsert, preserve existing linked metadata/status when stale payload attempts downgrade (`has_linked_account=false`).

Rule: linked friend metadata is server-owned state; client sync must not silently unlink.

### 7.8 Key identity data structures

- `UserAccount.equivalentMemberIds`: alias UUID set for same person.
- `GroupMember.accountFriendMemberId`: optional pointer to linked `AccountFriend.memberId`.
- `AccountFriend.linkedAccountId`: linked account identity (String).

### 7.9 Canonical runbook

Use `docs/linking/ACCOUNT_LINKING_PIPELINE_RUNBOOK.md` for end-to-end debugging and implementation across:

- invite claim + link request acceptance
- canonical/alias invariants
- iOS selector correctness
- bulk import identity rules
- troubleshooting commands/test gates

## 8) Non-Negotiable Security and Correctness Rules (Provenance: 2026-02-11)

### 8.1 Authorization source of truth (Convex)

Never trust client ownership identifiers (`accountEmail` etc.) for destructive/identity mutations.

Required pattern:

1. Resolve caller via auth (`getCurrentUser` / `getCurrentUserOrThrow`).
2. Derive account email/id server-side.
3. Treat client `accountEmail` as optional legacy field only; reject mismatches.

Applies to:

- `aliases:mergeMemberIds`
- `aliases:mergeUnlinkedFriends`
- `cleanup:deleteLinkedFriend`
- `cleanup:deleteUnlinkedFriend`
- `cleanup:selfDeleteAccount`

### 8.2 Admin-only mutation guard

- `admin:hardDeleteUser` must be allowlist-admin gated by auth identity.

### 8.3 Linked identity type rule

- `account_friends.linked_account_id` must store auth/account `id` string.
- Never store Convex document `_id` in this field.

### 8.4 iOS payload compatibility rule

When backend contracts change, iOS payload keys must match exactly.

Required keys:

- `aliases:mergeMemberIds`: `sourceId`, `targetCanonicalId`
- `cleanup:deleteLinkedFriend`: `friendMemberId`
- `cleanup:deleteUnlinkedFriend`: `friendMemberId`
- `aliases:mergeUnlinkedFriends`: do not send `accountEmail`

### 8.5 Realtime startup safety (iOS)

- `AppStore.subscribeToSyncManager` must ignore realtime payloads until a valid session exists.
- Prevent empty pre-auth snapshots from clobbering local state.

### 8.6 Dependencies thread-safety

- `Dependencies.reset()` must be serialized with a lock.
- This protects `DependenciesTests.testConcurrentReset_DoesNotCrash` behavior.

### 8.7 Add Expense payer identity guard

Rules for `AddExpenseView`:

1. Do not infer current user from `group.members.first`.
2. Default payer to actual current-user member (`isCurrentUser` marker first; fallback `store.isCurrentUser(...)`).
3. Render `"Me"` from resolved current-user identity, not array position.
4. Keep direct-group payer toggles using resolved identity.

Failure impact:

- Wrong `paidByMemberId` can be saved while UI still shows `"Me"`.

### 8.8 Direct expense friend validation guard (Convex)

In `expenses.create` for `group.is_direct`, friend confirmation must resolve identity over:

- `account_friends.member_id`
- `account_friends.linked_member_id`
- alias closure in `member_aliases`

Also, when friend has `linked_account_email` or `linked_account_id`, resolve linked account and include:

- linked account `member_id`
- linked account `alias_member_ids`

Failure impact:

- `member_id`-only matching causes false `not a confirmed friend` errors.
- Without linked-account alias expansion, valid direct expenses can still be rejected when group members use legacy alias IDs.

### 8.9 Group membership != friendship (iOS)

Rules:

1. `AppStore.loadRemoteData` must use server `remoteFriends` only.
2. Do not synthesize friends from group members.
3. `AppStore.scheduleFriendSync` must sync deduped `self.friends` only.
4. Never sync `derivedFriendsFromGroups()`.

Failure impact:

- Users can appear as unintended friends after shared-group updates (friend-of-friend leakage).

### 8.10 Expense participant identity metadata rule

When upserting expenses to Convex:

1. Resolve participant `linkedAccountId` and `linkedAccountEmail` for both current-user aliases and linked friends (`areSamePerson(...)`).
2. Normalize empty values to `nil` and lowercase emails before send.

Failure impact:

- Cross-account fan-out can break and expenses may appear missing after account switch.

### 8.11 Clear-all semantics (`iOS <-> Convex`)

`clearAllUserData` must remove owned data and detach shared visibility.

Required backend behavior:

1. `groups:clearAllForUser`:
   - delete owned groups
   - remove current user canonical/alias member IDs from shared groups
2. `expenses:clearAllForUser`:
   - reconcile + delete owned expenses (`reconcileUserExpenses(..., [])` before delete)
   - delete current user `user_expenses` rows

Failure impact:

- Users can clear data but still see leftover shared groups/people or stale expense visibility.

### 8.12 Friend UI boundary

- Friends tab shows confirmed `AccountFriend` entries only.
- Group-derived identities (`friendMembers`) are for identity resolution/group workflows, not canonical friends list UI.

Failure impact:

- Friend-of-friend participants (for example, Bob in a shared group) can appear as unintended direct friends.

## 9) Security Hardening Set (Provenance: 2026-02-20)

### 9.1 Group upsert authorization

- `groups:create` can accept client `id` for idempotent upsert.
- If `id` already exists, verify ownership before patching.
- Existing-group updates by client ID are owner-only.

### 9.2 Group delete cascade

All group deletions (`deleteGroup`, `deleteGroups`, clear/leave flows removing whole group) must:

1. Reconcile each expense via `reconcileUserExpenses(..., [])`.
2. Delete those expenses.
3. Delete the group.

### 9.3 Member ID reassignment

- `accounts.member_id` is canonical identity; do not reassign for existing accounts.
- `users:updateLinkedMemberId` may only bootstrap legacy accounts missing `member_id`, and only with unused IDs.

### 9.4 Linked account resolution privacy

- `users:resolveLinkedAccountsForMemberIds` must not be a global directory lookup.
- Return metadata only for caller-visible identity surface:
  - self aliases
  - owned/shared groups
  - direct friends
  - linked friend identities

### 9.5 Operational endpoint exposure

- Backfills/repairs are privileged.
- Migration/repair endpoints must be `internalMutation` or explicit admin-gated.
- Never expose one-off repair operations as normal authenticated mutations.

### 9.6 Authenticated name fallback

- In authenticated sessions, self-friend detection must be ID/link based only.
- Name-equality fallback is allowed only for no-session/local contexts.

## 10) Convex Environment Routing (iOS Build Pipeline)

Goal: route iOS builds automatically:

- Local dev/internal testing -> development Convex DB
- External TestFlight/App Store -> production Convex DB

Required config contract:

1. `project.yml` has `Debug`, `Internal`, `Release` configs.
2. PayBack target sets:
   - `PAYBACK_CONVEX_ENV=development` for `Debug` and `Internal`
   - `PAYBACK_CONVEX_ENV=production` for `Release`
3. `Info.plist` contains `PAYBACK_CONVEX_ENV=$(PAYBACK_CONVEX_ENV)`.
4. Runtime (`AppConfig.environment`) reads bundle `PAYBACK_CONVEX_ENV`; falls back to debug/release only if missing/invalid.

Scheme contract:

- `PayBackInternal` archives with `Internal` config (development DB)
- `PayBack` archives with `Release` config (production DB)

Xcode Cloud workflow split:

1. Internal testing workflow -> `PayBackInternal`
2. External TestFlight/App Store workflow -> `PayBack`

Rule: never flip Convex URLs manually for release cycles.

### CI compile guard for Convex types

`PAYBACK_CI_NO_CONVEX` can compile out concrete Convex services (e.g. `ConvexAccountService`).

Required behavior:

1. `AppStore` and core services should code against `AccountService` protocol.
2. Any concrete Convex type usage must be guarded by `#if !PAYBACK_CI_NO_CONVEX`.

Failure signature:

- Xcode Cloud compile error: `Cannot find type 'ConvexAccountService' in scope`.

## 11) Auth UX Continuity (iOS)

### 11.1 Auth draft persistence

Treat login/signup/verification as one flow with shared draft state.

Required behavior:

1. Keep auth inputs in `AuthCoordinator` (`@Published`), not per-view local `@State`.
2. Login -> Signup pre-fills signup email from login draft.
3. Signup -> Login carries edited signup email back.
4. Verification -> back returns to Signup with intact draft.

### 11.2 Native text input metadata

Required fields:

1. Login email: `.textContentType(.username)` + no autocapitalization/correction.
2. Login password: `.textContentType(.password)`.
3. Signup password: `.textContentType(.newPassword)`.
4. Signup confirm password: `.textContentType(.password)` and submit label `.join`.
5. Verification code: `.textContentType(.oneTimeCode)` with keyboard-dismiss affordance.

## 12) Add Expense UX Continuity (iOS, provenance: 2026-02-20)

### 12.1 Save validation parity

- Save/check availability and `save()` guard must use one shared validation path.
- Validation must require: non-empty description, positive amount, at least one participant, non-empty computed splits.
- Never allow silent no-op save taps from guard mismatch.

### 12.2 Save validation feedback

- `saveValidationMessage` must explicitly list missing fields.
- If multiple fields are missing, message should include all relevant misses.
- Blocked-save path should not trigger warning/success-like haptics; show alert copy only.

### 12.3 Split summary label

- One selected participant: `Only me` or `Only <name>`.
- Multi-participant: mode labels (`Split equally`, `Split by percent`, etc.).
- Subset of group: append context like `(<n> people)`.

### 12.4 Split sheet exit affordance

- Provide explicit top-bar confirm control (checkmark) for split sheet dismissal.
- Swipe-to-dismiss cannot be the only close affordance.

### 12.5 Swipe gesture determinism

Rules for Add Expense gestures:

1. Do not persist/animate panel offset during drag.
2. Detect swipe-up from end translation only.
3. Disable swipe-down interactive dismissal for split/add-expense sheets.
4. Setting `confirmPromptOnSwipeUpAddExpense` (default ON):
   - ON: confirm prompt before swipe-up save
   - OFF: direct save on swipe-up
5. When swipe-confirm overlay is visible, second upward swipe over threshold must execute the same path as tapping `Save`, then fully reset offset/gesture state.

### 12.6 Convex acknowledgement on save

Expense creation must not look successful locally if cloud upsert fails in the same flow.

Required behavior:

1. Save path must use Convex-backed `addExpenseAndSync`.
2. On Convex upsert failure during create, rollback optimistic local insert.
3. Keep user on creation screen with actionable error.
4. Save-confirm and duplicate-warning prompts must share one alert state machine.
5. Avoid multiple `.alert` modifiers on same root view.

## 13) Do / Don’t Reference for High-Risk Changes

### Identity equivalence

- **Do:** use `areSamePerson(...)`, `equivalentMemberIds`, and `accountFriendMemberId` for matching.
- **Don’t:** compare raw UUIDs only in friend/balance/direct-expense logic.

### Friend sync writes

- **Do:** sync deduped `self.friends` after `processFriendsUpdate(...)`.
- **Don’t:** write pre-dedupe arrays or `derivedFriendsFromGroups()` to Convex.

### Convex auth and ownership

- **Do:** derive actor identity on server (`getCurrentUser*`) and resolve ownership server-side.
- **Don’t:** trust client `accountEmail` or client ownership claims for destructive ops.

### Linked account metadata

- **Do:** treat linked friend metadata as server-owned and downgrade-resistant.
- **Don’t:** let stale payloads clear linked fields/status.

### Clear-all behavior

- **Do:** remove owned records and shared visibility (`user_expenses`, shared membership).
- **Don’t:** leave user attached to shared groups/visibility after clear-all.

### Add Expense behavior

- **Do:** run one validation pipeline for button state + save guard + alerts.
- **Don’t:** allow save affordance that later no-ops silently.

### Build environment routing

- **Do:** choose correct scheme/workflow (`PayBackInternal` vs `PayBack`).
- **Don’t:** hand-edit Convex URLs for release/internal toggles.

## 14) Maintenance Protocol for Agents

When adding new rules:

1. Convert issue learnings into stable instruction language.
2. Keep function/table/field names explicit.
3. Add do/don’t guidance for failure-prone behaviors.
4. Preserve existing constraints unless intentionally superseded.
5. If replacing a rule, state the new invariant and migration implications.

This file is the operational contract for contributors and agents; prefer precision over brevity.
