# Historical restore acceptance register

All14 local acceptance requirements below are complete within their stated executable seams. Final source `80061a9d5a2775a786dd07d76b6ca89d9f977345` matches511-file manifest SHA256 `064742f486a93f3bb638196f23ec1be0b494f03157e56a9965c817106503d7a5`. All three primary source/test scopes approve; Gemini R2 agrees at lower weight. Standard2 SDK2933,TSan2891selected andASan2933 pass; sanitizer wrappers include883backend89files.42performance tests are excluded from TSan selection, not skipped.

Backend tests execute real local authenticated handlers/workers. Swift composition uses production transformations/SDK adapters with recording transport and explicit state fixtures. Together they prove the specified transformations, wire contracts, storage transitions and recovery boundaries; they do not execute a deployed SDK-to-backend network. Historical failed checkpoints remain in [before-after.json](before-after.json) and [VERIFICATION.md](VERIFICATION.md).

## Contract boundaries

Newly restored GROUP/DIRECT non-owner sharing requires current membership. DIRECT additionally requires the exact canonical pair and an owner-side proven confirmed friend. Ordinary retained history/grouped-individual keep their contracts; restored financial rows require capability2. Authoritative inactive identities are scrubbed on new/replayed headers and active rosters without rewriting money/IDs/flags. Prior user-owned manual labels may remain unlinked until rewritten; inactive target mutations reject. Stewardship never globalizes another owner’s local aliases.

## Acceptance evidence

### RA01 — public_create_delete_restore_live_group

Actual production createV2 A/X→A/B, delete only expense, ordinary restore into still-linked owned A/X group succeeds without a manifest or roster rewrite.

Owners: backend_expenses.

Observed: Actual createV2→deleteExpense→no-manifest restore passes with unchanged raw group roster and financial rows.

- `apps/backend/convex/tests/groupAuthoringIdentityScope.test.ts`: create then delete then restore authorizes canonical history through the live group owner (E42).

Limits: Actual local authenticated functions/worker assertions pass E42/E43; standard2 and TSan pass, ASan passes E53; operator/live checks remain separate.

### RA02 — portable_64_member_repeated_restore

Actual exporter/parser/request builder for a full 64-member raw group plus canonical B emits 64 group members and a bound complete financial-participant declaration; clear all three surfaces and restore succeeds with unchanged rows. Repeat twice with a later relink and no roster growth.

Owners: backup_config, backend_expenses, backend_identity.

Observed: Actual backend two64-member clear-all3/restore cycles plus accepted relink pass; production Swift exporter/parser/importer/adapter/refresh two-cycle64/100 composition passes E49 with recording server.

- `apps/backend/convex/tests/restored_history_capacity_cycles.test.ts`: RA02 backend DTO snapshots clear all three surfaces and restore a 64-member history twice before accepted relink (E44).
- `apps/ios/PayBack/Tests/Services/ConvexRestoreTransportTests.swift`: testTwo64MemberRestoreCyclesRefreshRawAndCanonicalHistoryWithoutImportingRelinkAuthority (E49).

Limits: Actual backend DTO clear/restore/relink plus production Swift exporter/adapter/refresh with recording server. Named SDK selectors pass E49; no deployed network claim. TSan/ASan pass E51/E53.

### RA03 — raw_history_precision_roundtrip

Mixed raw X and canonical B historical rows, fractional legacy amounts, zero shares, split IDs/flags, currency, names, subexpenses, notes, and direct context round-trip unchanged.

Owners: backup_config, backend_expenses.

Observed: All3 mixed raw/canonical direct roundtrip selectors pass E49, preserving fractional/zero amounts, IDs/flags, names, notes, subexpenses, nil/USD/EUR and raw roster without imported authority.

- `apps/ios/PayBack/Tests/Services/BackupMixedDirectHistoryRoundTripTests.swift`: testMixedRawAndCanonicalDirectHistoryPreservesUnknownAndExplicitCurrency; testEqualNamesAndReversedSplitOrderDoNotCoalesceDirectHistory; testExplicitOwnerRemappingPreservesDistinctRawAndCanonicalHistory (E49).

Limits: Actual production Swift transformation/encoded-wire selectors pass E49 canonical SDK target. No alias coalescing or imported authority; TSan/ASan pass E51/E53.

### RA04 — declared_outsider_private_all_routes

A guessed registered outsider declared as historical is stored only in the owner's private history. The outsider cannot list/read, settle, edit, or delete it; forged linked metadata and unrelated link operations do not activate it.

Owners: backend_expenses.

Observed: Privacy sequence passes all available list/context-detail/paged readers and edit/settle/delete denial, forged metadata and unrelated accepted link. No standalone get endpoint exists.

- `apps/backend/convex/tests/restored_history_privacy_sequences.test.ts`: RA04 declared outsider stays private across all public routes, forged metadata and an unrelated accepted link (E42).

Limits: Actual local authenticated functions/worker assertions pass E42/E43; standard2 and TSan pass, ASan passes E53; operator/live checks remain separate.

### RA05 — manifest_chunk_atomic_validation

Dangling/duplicate/mismatched manifests, foreign group/expense IDs, undeclared outsiders, pending/deleting groups, and over-budget payloads reject without partial authority or financial writes.

Owners: backend_expenses, backend_identity, ios_transport.

Observed: Malformed/ownership/undeclared/deleting-group/budget rejections pass. E48 actual pending-history import snapshots15surfaces including scheduler with zero partial writes; identical payload succeeds after real drain. Included in E51 backend883.

- `apps/backend/convex/tests/restoredHistoryAccess.test.ts`: a malformed later manifest rolls back every header and expense in the chunk; %s manifest fails before any header writes; missing manifest group rolls back every table even when expense already exists: %s (E42).
- `apps/backend/convex/tests/import_robustness.test.ts`: bulkImport rejects conflicting group ownership before applying friend writes; bulkImport rejects an expense ID owned by another account (E42).
- `apps/backend/convex/tests/restored_history_capacity_cycles.test.ts`: RA11 real friend request budget rolls back 16 headers then succeeds in fitting halves; RA11 real group request budget rolls back 24 fresh 64-member headers then bisects four-header chunks into fitting requests (E44).
- `apps/backend/convex/tests/restored_history_pending_import.test.ts`: RA05 pending restored-history import rolls back every header and financial effect, then the same payload succeeds after reconciliation (E48).

Limits: Actual pending-group import atomicity passes E48, final source/test reviewers approve E50, and full883backend suites include it in E51/E52. All local gates pass; no deployed backend proof.

### RA06 — restriction_replay_immutable_scope

Existing groups ignore incoming roster changes. Same-owner idempotent replay preserves its original restriction and rows. A later unmanifested row obtains no exception to live membership from prior imports; any successful backed restore still receives its own complete sharing restriction. Explicitly add then remove B between repeated backups and prove the restriction remains effective.

Owners: backend_expenses, backend_identity.

Observed: Actual add/remove B and repeated backend DTO replay preserve original restriction/rows/current roster; forged incoming roster ignored and later unmanifested outsider gets no prior-import exception.

- `apps/backend/convex/tests/restored_history_capacity_cycles.test.ts`: RA06 repeated backend DTO replay preserves restrictions across actual member add and remove without inheriting an outsider declaration (E44).

Limits: Actual local authenticated functions/worker assertions pass E42/E43; standard2 and TSan pass, ASan passes E53; operator/live checks remain separate.

### RA07 — link_membership_reference_generations

Actual accepted link X→B activates eligible history through indexed reference discovery; another owner's local merge does not. Actual group membership addition/removal reconciles history through bounded pages. Capture before/pending/after reads and reject stale revision continuations.

Owners: backend_identity, backend_expenses.

Observed: Actual invite/email claims discover context-only history; unrelated local merge cannot grant stranger authority. Public group removal gates pending reads, removes stored grants and rejects old revision continuation after completion.

- `apps/backend/convex/tests/restored_history_recovery_sequences.test.ts`: RA07 public group removal blocks pending reads, retires the same generation, removes grants and rejects the old continuation (E42).
- `apps/backend/convex/tests/restored_history_linking.test.ts`: V3 %s discovers restored canonical history through an original context-only placeholder; V3 %s drains later-added group context: revoke old A eligibility and grant B across a foreign owner (E42).

Limits: Actual local authenticated functions/worker assertions pass E42/E43; standard2 and TSan pass, ASan passes E53; operator/live checks remain separate.

### RA08 — suppression_survives_all_restore_transitions

Cleared shared history stays suppressed after import replay, link, membership changes, metadata edits, settlement, and worker retries.

Owners: backend_accounts, backend_expenses, backend_identity.

Observed: Actual shared clear creates durable suppression; replay, relink, remove/add membership, metadata, settlement and worker resume all preserve hidden stored grant state for the same expense.

- `apps/backend/convex/tests/restored_history_privacy_sequences.test.ts`: RA08 actual shared clear survives replay, relink, membership changes, edits, settlement and worker resume (E42).

Limits: Actual local authenticated functions/worker assertions pass E42/E43; standard2 and TSan pass, ASan passes E53; operator/live checks remain separate.

### RA09 — lifecycle_legacy_limits_compatibility

Group deletion, account deletion/ownership transfer, job retries/failure, legacy no-manifest import, and old-client capability rejection remain covered. Current group/member/viewer limits remain unchanged.

Owners: backend_identity, backend_accounts, backend_expenses.

Observed: Actual group/account deletion, eligibility-based transfer, retries/failures, no-manifest import, legacy capability rejection and unchanged supported limits pass owning tests; current source scopes approve.

- `apps/backend/convex/tests/restored_history_cleanup.test.ts`: account deletion only promotes an originally eligible history participant (%s); a foreign group history job cannot strand its deleting expense owner (E42).
- `apps/backend/convex/tests/restoredHistoryAccess.test.ts`: every restored duplicate-member shape requires capability2 (all settled=%s); all newly restored financial rows set the capability floor while friend-only headers do not (E42).
- `apps/backend/convex/tests/group_history_worker.test.ts`: transient attempts are bounded and a stale worker cannot advance a replaced generation (E42).

Limits: Actual local authenticated functions/worker assertions pass E42/E43; standard2 and TSan pass, ASan passes E53; operator/live checks remain separate.

### RA10 — pretransfer_steward_privacy

Exercise actual soft account deletion of A with a current A/C group and private restored A/B expense. B never becomes owner/viewer or gains list/read/settle/edit/delete authority at intermediate pages or completion; C's separate group stewardship cannot promote either non-financial C or hidden B. Prove an eligible financial successor positive and a suppressed-successor negative, including changes between cleanup pages.

Owners: backend_accounts, backend_expenses, backend_identity.

Observed: Actual public deletion checks hidden B/C access and valid mutation denial at intermediate pages/completion; positive eligible and negative suppressed/between-page successors retain exact policy.

- `apps/backend/convex/tests/restored_history_deletion_timing.test.ts`: private historical mutations remain denied at intermediate deletion pages and completion (E42).
- `apps/backend/convex/tests/restored_history_cleanup.test.ts`: account deletion only promotes an originally eligible history participant (%s) (E42).

Limits: Actual local authenticated functions/worker assertions pass E42/E43; standard2 and TSan pass, ASan passes E53; operator/live checks remain separate.

### RA11 — production_adaptive_import_exact_outcomes

Actual parser → remapping → production importer → DTO → real adapter restores one 64-member group with 100 two-person expenses, at least 24 fresh 64-member groups across multiple header requests, and supported maximum financial/context sets. Force deterministic budget rollback and successful bisection in every phase; assert exact IDs/manifests/money and final truthful outcomes. Test lost-after-commit response replay, cancellation/account switch during backoff/subdivision, single-item failure, and final refresh failure.

Owners: backup_config, ios_transport, backend_expenses, ios_state.

Observed: Real backend friend/group/expense request budget rollback and fitting subdivision pass, including24fresh64-member groups and max65financial/64context. SDK actual transformations/adapter composition, exact outcomes/replay and harness cancellation/refresh controls pass their separate seams.

- `apps/backend/convex/tests/restored_history_capacity_cycles.test.ts`: RA11 real friend request budget rolls back 16 headers then succeeds in fitting halves; RA11 real group request budget rolls back 24 fresh 64-member headers then bisects four-header chunks into fitting requests; RA11 maximum 65 financial and 64 context identities fit singly after a real eight-expense budget rollback and serial bisection (E44).
- `apps/ios/PayBack/Tests/Services/ConvexRestoreTransportTests.swift`: testParserRemappingImporterRealAdapterPreserves64Member100ExpenseHistory; testParserImporterRealAdapterSubdivides24FreshGroupHeadersAndFriends (E49).
- `apps/ios/PayBack/Tests/Services/ConvexRestoreTransportTests.swift`: testLostCommittedResponseReplaysSameIDsAndReportsPresentInsteadOfInventedCreationCount (E49).

Limits: Actual backend real-budget tests plus production Swift adapter with injected transport; E49 passes canonical-JSON replay and full composition, harness covers cancel/backoff/single-item/refresh. Separate local seams, not deployed network. TSan/ASan pass E51/E53.

### RA12 — adaptive_worker_neutral_recovery

Force the real history worker's eight-item prepared page over budget and prove smaller successful pages advance the cursor without skipping/duplicating exposure or publishing stale generations. Inject transient and durable job failures; source owner and eligible foreign reader can discover/retry through the actual service without successful blocked snapshots or login retry loops. Hidden outsiders cannot discover private job scope or reschedule it.

Owners: backend_identity, ios_state, ios_transport, backend_expenses.

Observed: Actual8-row measured overflow rolls back then smaller pages complete without lost grants; real transient/durable worker failures exercise owner/eligible foreign API discovery/resume and hidden-outsider denial. SDK adapter-wire and AppStore state selectors pass; durable maintenance stays blocked.

- `apps/backend/convex/tests/group_history_worker.test.ts`: real measured page overflow rolls back then completes at a smaller size (E42).
- `apps/backend/convex/tests/restored_history_recovery_sequences.test.ts`: RA12 an actual unsupported source becomes durable maintenance failure and public recovery cannot report success; owner/viewer actual transient failure recovery parameterization (E42).
- `apps/ios/PayBack/Tests/Services/AppStoreLinkingTests.swift`: testRestoreHistory_ColdLoginRetainsNeutralActorBehindDataRecovery; testRestoreHistory_TransientResumeFailureKeepsNeutralRecoveryAndMaintenanceDoesNotRetry; testRestoreHistory_ForeignReaderRecoversThroughAuthorizedErrorHint (E49).

Limits: Actual worker/public recovery endpoints plus SDK adapter-wire and AppStore/mock-service state tests; standard2 and TSan pass. Durable maintenance remains visibly blocked, not falsely repaired. No deployed network; Current ASan passes E53.

### RA13 — authoritative_deleted_party_inert_restore

Restore a backup containing a server-proven deleting/deleted B in friend headers, a new A/B group, and A/B financial rows. Header preparation yields ghost B and no active B roster/link; money/IDs survive with scrubbed inactive B metadata, no B viewer/steward. Test canonical and live-proven alias IDs, deletion already past the relevant cleanup phase, a between-request deletion transition, unknown offline B, and unchanged actor/group-owner fencing.

Owners: backend_expenses, backend_accounts, backend_identity, backup_config.

Observed: Actual late deletion and between-request transitions pass canonical/alias scrub/no-active-roster/no-viewer with exact financial rows. Prior user-owned manual label may remain unlinked until header rewrite; inactive target mutations reject; rewritten/new headers scrub.

- `apps/backend/convex/tests/restored_history_deletion_timing.test.ts`: restore scrubs an actual late deletion after relevant sweeps (%s) (E42).
- `apps/backend/convex/tests/restoredHistoryAccess.test.ts`: authoritative deleted alias is scrubbed without rewriting the original alias split IDs; existing inactive friend clears every persisted personal-name field and then replays unchanged (E42).

Limits: A prior user-owned manual historical label may remain with zero linked authority until rewritten. New target expense/link mutations reject inactive B; replayed/new headers scrub, active roster omits B, raw financial money/IDs remain unchanged.

### RA14 — restricted_direct_owner_consent

Restricted restored direct history with only an imported roster/manual B stays private to A even when B is registered. An existing owner-side proven confirmed B plus the exact canonical pair permits B sharing; B's independent reciprocal friend state is irrelevant. Owner-side removal/downgrade/clear revokes only restricted restored-direct sharing through indexed reconciliation; ordinary retained direct history remains unchanged.

Owners: backend_expenses, backend_accounts, backend_identity.

Observed: Manual roster alone stays private; proven owner-side exact-pair consent permits sharing without reciprocal friendship. Clear/downgrade/removal reconciles restricted direct history while preserving ordinary history; three-person direct negative and legacyX positive pass.

- `apps/backend/convex/tests/restored_history_privacy_sequences.test.ts`: RA14 owner-side proven friendship cannot share a restored direct context with three canonical people (E42).
- `apps/backend/convex/tests/restored_direct_friend_cleanup.test.ts`: friend %s revokes restored direct sharing and preserves ordinary history; accepted legacy friendship activates restricted direct sharing through indexed work; friend consent reconciliation must include restored direct contexts after group flag changes (E42).

Limits: Actual local authenticated functions/worker assertions pass E42/E43; standard2 and TSan pass, ASan passes E53; operator/live checks remain separate.

## Separate operator and live checks

Live Clerk continuity, associated domains/deep links, deployed backend semantics, real devices and backfill/readiness activation remain explicit operator/integration requirements. No rollout or production data mutation occurred. PayBack’s2048 guard is stricter than the documented platform limit and was not raised to make tests pass. E53 repeats the same ASan binary and supplies valid2933/0/0 results; E52’s incomplete artifact remains historical.
