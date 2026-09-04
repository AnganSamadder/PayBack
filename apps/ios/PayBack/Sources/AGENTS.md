# PayBack iOS source instructions

The root `AGENTS.md` applies. This file adds rules for `apps/ios/PayBack/Sources`.

## Architecture

- `AppStore` is the account-scoped source of truth for shared UI state.
- Views render store state and keep only short-lived presentation/input state locally.
- Inject services through `AppStore`/`Dependencies` protocols so behavior is executable in tests.
- Realtime sync is authoritative only after authentication and a successful channel fetch.

## Names that encode the data boundary

- `friends: [AccountFriend]`: persisted confirmed relationship records.
- `confirmedFriends: [GroupMember]`: display/selection projection of confirmed friends. Use for the
  Friends tab, all UI labeled Friends, and direct-expense targets.
- `knownGroupParticipants: [GroupMember]`: confirmed friends plus group-derived identities. Use only
  for identity resolution, migration recovery, dedupe, and navigation fallback.
- `directExpenseTarget(for:)`: returns an existing direct expense ledger or a transient draft. It
  must not persist, sync, or alter friendship state.
- `existingDirectExpenseLedger(with:)`: lookup only.

Never reintroduce a generic `friendMembers` API. It obscures whether group-only people are included.
Never infer or sync friendship from group membership.

## Friend and direct-expense lifecycle

1. `addUnlinkedFriend` awaits `AccountService.syncFriends` before updating local confirmed state.
2. Friend addition and link-request success do not create a direct expense ledger.
3. Direct-expense UI works with a transient target until save.
4. `addExpenseAndSync(_:directExpenseLedger:)` commits the local ledger only after the Convex
   expense mutation succeeds. On failure it rolls back the optimistic expense and leaves no ledger.
5. Existing/legacy ledgers are reused through identity-equivalent member IDs.

## Expense participation

- Expense visibility includes `paidByMemberId`, `involvedMemberIds`, and split member IDs. Use
  `Expense.involvesMember(where:)` with the store's identity matching for read-side filters.
- A payer can have no split. Preserve selected split participants and amounts when fixing display
  logic; existing records must count without a data rewrite.
- Friend balances, Individual/Groups lists, and row summaries must resolve the same canonical,
  linked, alias, and imported `accountFriendMemberId` identities.

## Async state safety

- `AppStore` UI mutations are main-actor isolated.
- Capture account ID/data epoch before async work and reject stale completions after account switch.
- Cancellation is not success and must not surface an obsolete error.
- Roll back only the entity/version changed by the failed operation.
- Use per-entity generation tokens for overlapping optimistic writes.
- Carry UUIDs, not array positions, across `await`.

## Navigation and presentation

- Push detail pages through typed `NavigationStack` routes.
- Keep task flows (create, add, import, auth, camera) modal.
- Preserve independent per-tab paths in `TabNavigationState`.
- Resolve route IDs through `AppStore` identity-aware navigation helpers.

## Build and tests

- Do not edit `project.pbxproj`; edit `project.yml` and run `xcodegen generate`.
- Add focused XCTest regression coverage for state transitions and failure rollback.
- Any `AppStore`, service, or concurrency change requires standard iOS CI plus TSan; add ASan for
  data-structure or memory-sensitive changes.
- Keep user-facing errors actionable and free of raw backend details or PII.
