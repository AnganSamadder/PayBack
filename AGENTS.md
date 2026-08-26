# PayBack contributor instructions

This file contains durable repository-wide rules. Keep implementation detail close to the code in
the nested `AGENTS.md` files. Tests and generated configuration are the executable source of truth;
do not turn this file into an incident log.

## Instruction map

- `apps/backend/convex/AGENTS.md`: Convex data, authorization, identity, and transaction rules.
- `apps/ios/PayBack/Sources/AGENTS.md`: iOS state, concurrency, navigation, and UI boundaries.
- `docs/linking/ACCOUNT_LINKING_PIPELINE_RUNBOOK.md`: detailed account-linking diagnostics.

Instructions closer to a changed file take precedence. Update the closest guide only when a new
rule is durable and cannot be expressed more reliably as a test, type, validator, or CI check.

## Product and repository map

PayBack is an expense-sharing product with a SwiftUI iOS app, a Convex TypeScript backend, and a
Vite/React marketing site.

| Area                | Location                                  | Primary source of truth               |
| ------------------- | ----------------------------------------- | ------------------------------------- |
| iOS UI              | `apps/ios/PayBack/Sources/Features`       | Swift views + `AppStore`              |
| iOS shared state    | `apps/ios/PayBack/Sources/Services/State` | `AppStore.swift`                      |
| iOS tests           | `apps/ios/PayBack/Tests`                  | XCTest                                |
| Convex schema       | `apps/backend/convex/schema.ts`           | schema + validators                   |
| Convex functions    | `apps/backend/convex`                     | authenticated functions/model helpers |
| Convex tests        | `apps/backend/convex/tests`               | Vitest + `convex-test`                |
| Web                 | `apps/web`                                | Vite/React source                     |
| Xcode configuration | `project.yml`                             | XcodeGen input                        |

Run JavaScript/TypeScript workspace commands from the repository root. The Convex function root is
`apps/backend/convex` through the root `convex.json`.

## Working agreement

1. Inspect `git status`, applicable instructions, callers, persisted formats, and tests before
   editing. Preserve unrelated user changes.
2. Use an isolated worktree for risky work or when the current tree is dirty.
3. Reproduce bugs at the smallest executable seam. For a clear bug seam, add a regression test,
   confirm it fails for the expected reason, then make the smallest safe fix.
4. Trace changes through writers, readers, serializers, validators, realtime consumers, cleanup,
   and old-client behavior. Do not change a persisted or wire contract accidentally.
5. Prefer explicit domain names over short or type-based names. At a call site, the name should
   reveal whether data is confirmed, derived, transient, or persisted.
6. Do not edit `PayBack.xcodeproj/project.pbxproj`. Edit `project.yml`, then run
   `xcodegen generate`.
7. Do not mutate production data to test a change. Production inspection is read-only unless the
   user explicitly authorizes a precisely described mutation.
8. Never push or merge unless the user explicitly asks. Use single-line Conventional Commit
   messages when committing.

## Identity surface vocabulary

These are different domain sets. Never call all of them “friends.”

| Term                        | Code/data surface                                               | Meaning and allowed use                                                                                                                                                             |
| --------------------------- | --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Confirmed friend**        | iOS `friends` / `confirmedFriends`; Convex `account_friends`    | A user-approved relationship. Use for the Friends tab, any picker labeled Friends, direct-expense eligibility, deletion, linking, and friend sync.                                  |
| **Known group participant** | iOS `knownGroupParticipants`; group member rows                 | A broader identity-resolution set that can contain people seen only through groups. Use for migration, navigation fallback, dedupe, and identity repair—not as proof of friendship. |
| **Direct expense ledger**   | `SpendingGroup` / Convex `groups` with `isDirect` / `is_direct` | The private two-person container backing direct expenses. It is storage infrastructure, not a friendship record. Do not expose “direct group” as a user concept.                    |
| **Group**                   | non-direct `SpendingGroup`                                      | A named multi-person expense context. Membership does not imply friendship.                                                                                                         |

Non-negotiable lifecycle:

1. Adding a friend writes the confirmed friend remotely before showing success.
2. Adding a friend or sending a link request must not create a direct expense ledger.
3. Opening or cancelling Add Expense may create only a transient ledger draft in memory.
4. The first successful direct-expense mutation creates the direct expense ledger and expense in
   the same Convex transaction. Any failure leaves neither new record.
5. Later direct expenses reuse the existing ledger by identity equivalence.
6. Legacy empty direct ledgers may be reused for identity repair, but are not a normal product
   outcome and never prove friendship.

Any UI section labeled Friends must use `confirmedFriends`. Never sync `knownGroupParticipants` or
group-derived people into `account_friends`.

## Cross-layer correctness rules

### Authentication and authorization

- Convex derives the actor from authenticated server context. Client ownership fields are legacy
  compatibility inputs at most; reject mismatches.
- Destructive, admin, migration, and repair operations require explicit server-side authorization.
- Cross-account reads must be restricted to the caller-visible identity surface.

### Identity equivalence

- Raw member UUID equality is insufficient for linking, balances, splits, cleanup, and direct
  expenses. Use the canonical/alias helpers (`areSamePerson`, `equivalentMemberIds`,
  `accountFriendMemberId`, and backend alias resolution).
- `accounts` is registered-user truth. `account_friends` is relationship truth. Group membership is
  never relationship truth.
- Client sync cannot establish trusted linked-account or global-alias provenance.

### Persistence and cleanup

- Preserve historical financial math and participant names through unlink/soft-delete flows.
- Group deletion reconciles expense visibility before deleting expenses and the group.
- Clear-all removes owned records and detaches the caller from shared visibility.
- Long cleanup/migration work must be bounded, indexed, resumable, and safe to retry.

### Realtime and concurrency

- Account/session switches fence all async successes, failures, rollbacks, and realtime payloads.
- Realtime data must not overwrite local state before a valid session and successful channel fetch.
- Same-entity optimistic mutations need a generation/token so stale completions cannot win.
- Capture stable IDs across `await`; never carry an array index or `IndexSet` across async work.

### Compatibility

- Swift DTO keys and numeric encodings must match Convex validators exactly. Swift `Int` encodes as
  Convex Int64; send `Double` to `v.number()` fields.
- Schema changes must remain compatible with existing production documents during rollout.
- Keep legacy read compatibility only where a concrete stored-data path requires it; new writes use
  the canonical contract.

## Build and environment rules

- `project.yml` owns build settings, schemes, versions, entitlements, plist values, and packages.
- `PayBack` archives Release builds against production Convex.
- `PayBackInternal` archives Internal builds against development Convex.
- Do not hand-edit Convex URLs for a release.
- Concrete Convex types must remain guarded when `PAYBACK_CI_NO_CONVEX` is enabled.

## Verification

Choose gates proportional to the change and report exactly what ran.

```bash
# Repository checks
bun run ci

# Focused backend test
bun run --cwd apps/backend test --run convex/tests/<file>.test.ts

# Canonical iOS CI parity
./scripts/test-ci-locally.sh

# Required for AppStore, service, concurrency, or memory-sensitive changes
SANITIZER=thread ./scripts/test-ci-locally.sh
SANITIZER=address ./scripts/test-ci-locally.sh
```

Prefer one simulator and one stable DerivedData directory. Use `build-for-testing` once and
`test-without-building` for selectors when practical. Do not erase shared caches unless corruption
is proven and the exact target is safe to remove.

A change is complete only when the focused regression is green, the owning suite is green, relevant
cross-layer checks pass, the diff contains no generated/unrelated artifacts, and remaining blockers
are reported with evidence.
