# Plan: CSV Import/Export Backward Compatibility

This plan is intentionally written as a durable handoff artifact. Update it as changes land (and keep `docs/import-export/WORKLOG.md` current).

## Goals (what “works” means)

1) **Backwards compatible CSV import** across all historical export variants we’ve observed.

2) **All people in an imported export become “my friends”** even if none of them have linked accounts yet.
   - Linked accounts are an enhancement (visibility/claiming), not a prerequisite for importing expenses.

3) **Direct expenses must import and show up** for the importer.
   - In Convex, `expenses:create` currently requires that every non-current-user involved member in a direct group has an `account_friends` row with `status == "friend"`.
   - Therefore: the importer must ensure those rows will exist (and be “friend”) before attempting expense upserts.

4) **Format changes must be guarded by mocks + tests**, so compatibility is preserved long-term.

## Non-goals / Clarifications

- Import does **not** guarantee that unlinked friends can see the expense on their device until they create/link an account (because `participant_emails` fanout is email-driven).
- Import is not a migration framework; it is a best-effort reconstruction of local state plus cloud sync.

## Current root cause (confirmed)

### iOS ordering + status mismatch

- `AppStore.addExpense` immediately schedules a cloud upsert (`expenseCloudService.upsertExpense`) and swallows errors.
- `DataImportService.importData` currently:
  1. Adds friends from `[FRIENDS]` (defaults `status` to `"friend"` if missing).
  2. Imports groups.
  3. Imports expenses.
  4. Only after expenses, it ensures group members are added as friends — but with `status: "peer"`.
  5. Finally, it `await`s `store.syncFriendsToCloud()`.

This allows direct expense upserts to hit Convex before the required friend rows exist and/or with the wrong status.

### Convex rule

`convex/expenses.ts` validates direct expenses by querying `account_friends` and requiring `friend.status === "friend"` for all non-current-user involved members. It does **not** require that the friend has a linked account.

## Observed on-disk export variants (must stay compatible)

We have multiple real exports in the wild showing these format variants. Import must accept all of them.

### Variant A: Legacy header + minimal columns

- Header: `===PAYBACK_EXPORT_V1===`
- `[FRIENDS]` rows: **6 columns**
  - `member_id,name,nickname,has_linked_account,linked_account_id,linked_account_email`
- `[GROUP_MEMBERS]` rows: **3 columns**
  - `group_id,member_id,member_name`
- No `[EXPENSE_SUBEXPENSES]` section

### Variant B: Current header + minimal columns

- Header: `===PAYBACK_EXPORT===`
- `[FRIENDS]` rows: **6 columns**
- `[GROUP_MEMBERS]` rows: **3 columns**
- `[EXPENSE_SUBEXPENSES]` section exists

### Variant C: Current header + profile columns

- Header: `===PAYBACK_EXPORT===`
- `[FRIENDS]` rows: **8 columns**
  - adds: `profile_image_url,profile_avatar_color`
- `[GROUP_MEMBERS]` rows: **5 columns**
  - adds: `profile_image_url,profile_avatar_color`
- `[EXPENSE_SUBEXPENSES]` section exists

### Planned Variant D: Current header + friend status column

- Header: `===PAYBACK_EXPORT===`
- `[FRIENDS]` rows: **9 columns**
  - adds: `status`

Authoritative per-version schema definitions live in `docs/import-export/VERSIONS.md`.

## Implementation Plan

### Phase 0 — Documentation + compatibility discipline (no behavior change)

**Deliverables**
- `docs/import-export/VERSIONS.md` describing each observed format variant + detection rules.
- `docs/import-export/MOCKS.md` describing the mock CSV fixture matrix.
- `docs/import-export/WORKLOG.md` tracking progress across sessions.
- Add a short note in `AGENTS.md`: when import/export format changes, update VERSIONS+MOCKS+fixtures+tests.

**Acceptance criteria**
- Docs exist and reflect real-world variants without containing PII.

### Phase 1 — iOS importer: make every imported person a “friend” before expenses

**Files**
- `apps/ios/PayBack/Sources/Services/Core/DataImportService.swift`

**Changes**
1) **Promote implicit contacts to friends**
   - Any time the importer synthesizes an `AccountFriend` for a member encountered in groups/expenses, set `status = "friend"` (not `"peer"`).
   - This matches the product requirement: anyone in the imported export is “my friend”, even if unlinked.

2) **Reorder importer phases**
   - Ensure all group members are resolved (memberId mapping) and friends exist in `store.friends` before importing any expenses.

3) **Sync friends before expense creation (best effort)**
   - Call `await store.syncFriendsToCloud()` after friend creation and before adding expenses.
   - Note: tests run without Convex; in production this reduces the chance of direct-expense upsert rejection.

**Acceptance criteria**
- After importing any fixture, for every direct group expense, every involved member other than the current user has a corresponding `AccountFriend` in `store.friends` with `status == "friend"`.

### Phase 2 — iOS exporter: preserve friend status

**Files**
- `apps/ios/PayBack/Sources/Services/Core/DataExportService.swift`

**Changes**
- Append a 9th column to FRIENDS rows: `status`.
- Update the FRIENDS header comment to include `status`.

**Acceptance criteria**
- Export → Import round-trip preserves `status` for friends.
- Older importers remain tolerant (they should ignore extra columns; our importer already does).

### Phase 3 — Mocks: versioned CSV fixtures (generic/non-PII)

**Files/dirs (proposed)**
- `apps/ios/PayBack/Tests/Fixtures/ImportExport/CSV/` (or `.../Fixtures/csv_import_export/` if we prefer lower-case)
  - `v1/` (Variant A)
  - `v2-min/` (Variant B)
  - `v2-profile/` (Variant C)
  - `v3-status/` (Variant D)

**Fixture policy**
- Fixtures must be fully synthetic (no real emails/names/IDs from user data).
- Fixtures must be stable: fixed timestamps and UUIDs.
- Any time the export format changes, update:
  - `docs/import-export/VERSIONS.md`
  - `docs/import-export/MOCKS.md`
  - fixtures under `Tests/Fixtures/ImportExport/CSV/`
  - tests validating old and new fixtures.

See `docs/import-export/MOCKS.md` for the full matrix.

### Phase 4 — Tests: enforce backwards compatibility offline

**Constraints**
- CI cannot run Convex; tests must run without a backend.

**Test strategy**
1) Parsing tests
   - Ensure `parseExport` accepts all fixture variants (missing sections, smaller column counts, optional columns).

2) Import integration tests
   - Import each fixture into a fresh `AppStore(skipClerkInit: true)`.
   - Assert postconditions on local store state:
     - Expected counts.
     - No synthesized contacts are left as `status == "peer"`.
     - For direct groups, involved members map to existing friends with `status == "friend"`.

3) Export/import round-trip tests
   - Export generated state with status → import → validate status preserved.

**Acceptance criteria**
- `FAIL_ON_WARNINGS=1 ./scripts/test-ci-locally.sh` passes.

## Risk mitigation

- Importer still can’t guarantee network ordering in every failure mode (sync errors are swallowed in some paths). The goal is to make the common case correct and testable offline.
- Rollback plan: revert importer ordering/status changes; fixtures and docs remain (no runtime risk).
