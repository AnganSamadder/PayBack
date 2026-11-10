# Implementation ownership

All work is in this already isolated worktree. Agents must not commit, push,
deploy or edit another owner's files. Coordinate shared contracts by messages;
parent integrates. No production data access/mutation.

| Owner               | Files and responsibility                                                                                                                                                                                                                                                                                                                                            |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| backend_identity    | schema.ts, groups.ts, groupVisibility.ts, new memberReferences/identityOperations/financialContract modules; backend reference index/jobs/gates and identity/link protocols                                                                                                                                                                                         |
| backend_linking     | aliases.ts, inviteTokens.ts, linkRequests.ts and focused linking tests; legacy lifecycle, alias-only commit helpers for V3, owner/local provenance                                                                                                                                                                                                                  |
| backend_expenses    | expenses.ts, helpers.ts, expenseWrites.ts, bulkImport.ts, new money validation/ledger helpers; expense authorization, currency contract, createV2, suppression-aware visibility; call reference hooks owned by identity                                                                                                                                             |
| backend_accounts    | users.ts, orphanCleanup.ts, friend_requests.ts, friends.ts, cleanup.ts and account/cleanup tests; bootstrap/signup, actor fences, privacy directory, deletion/suppression; coordinate schema and contract gates                                                                                                                                                     |
| ios_state           | AppStore.swift, account/link/invite protocols and Convex adapters, ConvexSyncManager/ConvexRevisionedSync, iOS state mocks/tests; identity/job generations, actor binding, acknowledged friend/deletion, canonical saved ledger commit                                                                                                                              |
| ios_people          | FriendDetailView, LinkRequestDetailView, InviteLinkClaimView and Settings/MergeFriendsView; acknowledged friendship, explicit merge and truthful/currency-safe preview UI                                                                                                                                                                                           |
| ios_transport       | GroupCloudService/ConvexGroupService, minimal injected actual-adapter mutation/read seam and real delayed actor-switch tests; agreed narrow ConvexAccountService/import seams                                                                                                                                                                                       |
| backend_test_compat | Existing backend test fixture contract migration, preserving explicit legacy/negative cases; no production changes                                                                                                                                                                                                                                                  |
| ios_money           | DomainModels.swift, LinkingModels.swift, ConvexDTOs.swift, ConvexExpenseService.swift, ExpenseCloudService.swift, AddExpenseView.swift, Activity/ExpenseDetail, Groups views, FriendsTab/MergeExistingFriendSheet currency presentation; money/currency contract, production split allocator, all-row settlement UI; request AppStore helper changes from ios_state |
| backup_config       | DataImportService.swift, DataExportService.swift, BulkImportDTO.swift, AppConfig.swift, project.yml, auth.config.ts, new release/config scripts and backup/config tests; lossless roundtrip and coordinated environment readiness                                                                                                                                   |
| case_matrix         | before-after.json and BEFORE_AFTER.md; all 152 scenarios/29 findings with evidence and truthful pending/deployment states                                                                                                                                                                                                                                           |
| parent              | Integration, docs/case manifest, CI scripts, shared changes explicitly requested, XcodeGen, full suites/sanitizers, review rounds and PR                                                                                                                                                                                                                            |

Tests may be added/changed in each owner's focused area; avoid editing the same
existing test file as another owner. Use new uniquely named test files or agree
ownership. Parent regenerates Xcode once files stabilize. Expense DTO/model field
is `currencyCode: String?` / wire `currency_code`; legacy nil remains unknown.
Financial capability argument is `financial_contract_version: 2`; expected actor
arguments are `expected_account_id` and/or `expected_account_email` validated
against server-derived actor. Identity owner provides final operation/result
interfaces to iOS state and backend peers before they depend on them.

Prefer adding `saveExpense` (or equivalent acknowledged API) returning persisted
expense+ledger while retaining old `upsertExpense` protocol compatibility via a
default wrapper for existing mocks. The real adapter must use createV2 and return
the real persisted ledger. Do not silently treat a new V2 endpoint error as
permission to invoke an unsafe legacy path.
