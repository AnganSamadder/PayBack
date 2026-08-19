# Production Debug Data Containment Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove generated debug records from production activity/balances, safely clean existing contamination, and prevent generated records from entering production again.

**Architecture:** Inject the selected Convex environment into `AppStore`, filter generated records at initial and realtime boundaries, and gate seed writes to development. Repair the existing authenticated backend cleanup to use indexed canonical account ownership rather than stale financial identity UUIDs.

**Tech Stack:** Swift 5.10, SwiftUI/Combine, XCTest, Convex TypeScript, Vitest, XcodeGen, Xcode/TestFlight.

---

### Task 1: Reproduce production client contamination

**Files:**

- Modify: `apps/ios/PayBack/Tests/Services/AppStoreRemoteDataTests.swift`
- Modify: `apps/ios/PayBack/Tests/Mocks/MockExpenseCloudService.swift`
- Modify: `apps/ios/PayBack/Tests/Mocks/MockGroupCloudService.swift`

1. Add a test store configured for `.production` with one real and one generated group/expense.
2. Assert production loads only real records and requests generated-data cleanup.
3. Add a `.development` case proving generated records remain available.
4. Add a production seed-write test proving neither local state nor cloud mocks receive generated records.
5. Run `xcodebuild ... -only-testing:PayBackTests/AppStoreRemoteDataTests test` and confirm the new assertions fail for the missing environment boundary.

### Task 2: Implement client containment

**Files:**

- Modify: `apps/ios/PayBack/Sources/Services/State/AppStore.swift`

1. Add an injectable `ConvexEnvironment` with `AppConfig.environment` as the application default.
2. Filter generated groups and expenses before initial normalization and in both realtime subscriptions when the environment is production.
3. Sanitize generated records from persisted production state before exposing the cache and immediately rewrite the clean snapshot.
4. Launch the existing production cleanup services concurrently without awaiting them on the real-data hydration path.
5. Guard `addDebugExpense` and `addExistingDebugGroup` so they only mutate development stores.
6. Re-run `AppStoreRemoteDataTests` and confirm all focused client tests pass, including an offline-cache case and a suspended-cleanup case.

### Task 3: Reproduce stale-identity backend cleanup

**Files:**

- Create: `apps/backend/convex/tests/production_debug_cleanup.test.ts`

1. Seed two authenticated accounts with generated and real artifacts.
2. Give the caller's generated artifacts stale payer/member UUIDs while retaining the caller's server-owned owner fields.
3. Call `expenses:clearDebugDataForUser` and `groups:clearDebugDataForUser`.
4. Assert only the caller's generated artifacts are removed; all real and foreign artifacts remain.
5. Run the new Vitest file and confirm it fails against member-ID ownership cleanup.

### Task 4: Implement account-owned cleanup

**Files:**

- Modify: `apps/backend/convex/expenses.ts`
- Modify: `apps/backend/convex/groups.ts`

1. Replace generated-record ownership checks with canonical server-owned `owner_id` ownership.
2. Add compound `owner_id` plus generated-data indexes so unrelated accounts cannot exhaust the cleanup batch.
3. Preserve bounded reads, expense reconciliation, group visibility cleanup, and cascade behavior.
4. Run the new backend test and existing cleanup/security suites.
5. Run backend lint and TypeScript checks.

### Task 5: Release configuration and verification

**Files:**

- Modify: `project.yml`
- Regenerate: `PayBack.xcodeproj/project.pbxproj`

1. Bump marketing/build versions to a unique TestFlight release and run `xcodegen generate`.
2. Verify `PayBack` archives with `Release` and embeds `PAYBACK_CONVEX_ENV=production`.
3. Run `bun run ci` with fresh outputs.
4. Run `FAIL_ON_WARNINGS=1 ./scripts/test-ci-locally.sh`.
5. Run `SANITIZER=thread ./scripts/test-ci-locally.sh` and `SANITIZER=address ./scripts/test-ci-locally.sh`.
6. Archive and validate the signed `PayBack` Release build.
7. Upload the verified archive to TestFlight and verify processing status.
