# Verification record

Current status: all local gates pass on final511-file80061a9d source. Standard2 SDK2933/0/0; TSan2891selected/0/0; ASan repeat2933/0/0 with valid result artifacts. Both sanitizer wrappers pass883backend/89files and checks. All primary source/test reviews approve. TSan excludes42performance tests, not skips. E52’s incomplete artifact is historical and resolved by E53’s unchanged-binary rerun. Live/operator requirements remain separate.

## Historical checkpoints

The following entries preserve what was known at each recorded source snapshot. “Pending,” “underway” and “REQUEST CHANGES” within these historical entries describe that earlier checkpoint, not the current approved implementation. The latest source approval and runtime results follow them.

Core R3 repairs are committed at `996c098b`; restore design v3 is approved at `4c1b047a`. E31 passes 321 focused SDK tests and client/backup reviews approve their inspected slices. Final backend reviews found the additional R56–R66 cases. E36/E37 pass 18 and 128 owning repair tests, respectively; independent final rechecks, the full current-source gates and all14 acceptance gates remain open. Earlier canonical/sanitizer passes apply only to their recorded source snapshots.

## Historical results by source snapshot

| Snapshot and gate                                         | Observed result                                                                                                                                           | Limit                                                                                                                                 |
| --------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Pre-R3 canonical source `d20cd85c`, reviewed as `b192217` | 2,887 SDK-enabled iOS tests passed, zero failures/skips; 730 backend tests across 73 files; lint, typecheck, formatting and web build; one browser smoke. | Does not verify subsequent R3 repairs or the pending restore contract.                                                                |
| `b192217` source: Thread Sanitizer                        | 2,845 selected tests passed, zero failures/skips; diagnostic and warning checks passed.                                                                   | Existing four-class selectors exclude 42 performance tests from selection. They are not skipped tests.                                |
| `b192217` source: Address Sanitizer                       | 2,887 tests passed, zero failures/skips; diagnostic and warning checks passed.                                                                            | Functional R3 defects were found despite this pass. Later source needs new gates.                                                     |
| R3 client focused1                                        | 88 selected SDK tests passed.                                                                                                                             | Predates the cancelled-save rollback repair.                                                                                          |
| R3 client focused2                                        | 81 selected SDK/AppStore tests passed, including cancellation, current projection and acknowledged group-friend actions.                                  | Current client repair scope only; not a full canonical/sanitizer run.                                                                 |
| R3 repository CI                                          | 760 backend tests across 75 files and repository checks passed.                                                                                           | Predates latest cleanup fixtures; not a final current-source gate.                                                                    |
| R3 owning regressions                                     | Integrator reports 68 owning tests passed. Independent identity reviewer separately ran 38 owning tests and four private proofs.                          | Scoped evidence only; the 68-test result is integrator-reported rather than a matched local artifact here.                            |
| Financial restore recheck                                 | Original create/delete/restore proof and 67 owning tests pass; real 64-member export/restore boundary fails.                                              | Financial REQUEST CHANGES remains; historical-manifest v3 approved, implementation and all 14 acceptance proofs pending.              |
| Hosted GitHub CI                                          | Never started due to billing lock.                                                                                                                        | No hosted pass or test failure is inferred.                                                                                           |
| Production/provider integration                           | Not performed.                                                                                                                                            | Backfill/readiness, Clerk credentials/account continuity, live devices and Release cutover remain operator/integration prerequisites. |

The dedicated device is an arm64 iPhone 17 Pro simulator on iOS 26.0.1 using
Xcode 26.0.1. Tests use production SDK adapters with injected network boundaries.
They do not prove live Clerk login or deployed Convex behavior.

Canonical commands use the same dedicated simulator and DerivedData directory:

```bash
PAYBACK_SIMULATOR_UDID=AAE9A4B4-3497-47A5-AA36-B592783D8ECD \
DERIVED_DATA_PATH=/tmp/PayBackReviewDerivedData \
./scripts/test-ci-locally.sh
```

Sanitizer runs add `SANITIZER=thread` or `SANITIZER=address` and `RUN_WEB_E2E=0`.
The browser smoke had already passed in the corresponding standard run.

## Evidence artifacts

Large logs and Xcode bundles remain outside Git. Their hashes identify the exact
recorded artifacts. [before-after.json](before-after.json) includes commands,
source scopes, individual named tests and limits. Earlier failed runs remain
recorded; subsequent green results do not erase them.

<!-- prettier-ignore -->
| Evidence | Local artifact | SHA256 |
| --- | --- | --- |
| E10 | `/tmp/payback-repair-standard4.log` | `a48693e41bf4137bd505913909f09f49c747870880e36ba1f266a4573f891e14` |
| E11 | `/tmp/payback-repair-thread1.log` | `fcfb83cb004f8a9047a4a113afda495e822689bec1deca6f5eb1b26dca566713` |
| E12 | `/tmp/payback-repair-address1.log` | `82b8f1ca82e3c8a82954e2a54c39cfb639a66c90e889155b0313f1c6da808cef` |
| E17 | `/tmp/payback-repair-r3-focused2.log` | `84b49d8902b5be2b16d633d9a81e34de5be3289dcae5044a2724523ce3b7b98c` |
| E18 | `/tmp/payback-post-pr-identity-r3.md` | `f644f46fd852d733a5d5c1185ed5013ffe0e6cf6fa74e5489e535e76fd864969` |
| E19 | `/tmp/payback-repair-r3-ci1.log` | `cce867dffebc80809ec5bfc0dd088ca584eff3f21dc1721a3c93e6a6133f2b0a` |
| E20 | `/tmp/payback-post-pr-financial-r3.md` | `0305bbe510672744f5eb3720c342301bd6cb89f4f1b10e42e1916c9c9d4a4d7b` |
| E21 | `/tmp/payback-post-pr-client-r3-recheck.md` | `b0a17401c635c9ed6fb23ac292f37bfc0308d89eccb1a6b0745150b5be57980a` |

The ASan summary is `/tmp/payback-repair-address1-summary.json`; the TSan summary
is `/tmp/payback-repair-thread1-summary.json`. Exact hashes are in the case
manifest. The R3 financial boundary proof uses the actual exporter/parser and
real authenticated import; it is not a synthetic array-size assertion.

Hosted CI is blocked at
[GitHub Actions job 127689290523](https://github.com/AnganSamadder/PayBack/actions/runs/42155729035/job/127689290523).
The restriction must be resolved before hosted CI can provide evidence.

No production mutation or deployment was performed. Follow
[release readiness](../../linking/RELEASE_READINESS.md) and the
[linking runbook](../../linking/ACCOUNT_LINKING_PIPELINE_RUNBOOK.md) before rollout.
At this historical design-approval checkpoint, restore implementation, the14 acceptance proofs and assembled review had not yet completed. Later sections record their implementation, named proof and source approvals. The original v3 plan remains unchanged; current acceptance boundaries are in [RESTORE_ACCEPTANCE.md](RESTORE_ACCEPTANCE.md).

## Historical: Restore implementation evidence, first checkpoint

The parent-run production importer harness passed at the source hashes in
`/tmp/payback-restore-production1-source.sha256` (log
`/tmp/payback-restore-production1.log`). It exercises 24 fresh 64-member groups
and 100 expenses, every phase's deterministic bisection, stable manifests/rows,
truthful lost-commit outcomes, malformed outcomes, single-item rejection,
bounded retries, cancellation/account changes, notices and refresh results.
AccountService, network and AppStore are test substitutes: **RA11 is partial**.
Actual SDK composition and actual backend budget behavior remain pending.

The real SDK build for the two new AppStore recovery tests succeeded, then both
selectors produced seven expected assertion failures and zero unexpected ones.
`/tmp/payback-restore-state-red1.log` and its source-hash manifest preserve that
**RA12 fail-before** evidence. It exposes lost neutral-session/visible-recovery
state under pending history. No green recovery or complete history-worker gate
is claimed. The state repair is underway.

## Historical: Restore focused checkpoint, with open defects

`/tmp/payback-restore-focused1.log` records **310 tests, 9 failures, 0 unexpected**.
All nine failures are older ImportSummary description assertions. Eight concrete
ConvexRestoreTransportTests and seven AppStore history-state selectors passed,
including both prior red recovery cases. This is a partial checkpoint, not a
passing suite. Later neutral-session guards and typed expense-catch tests are
newer than the compiled binary and need rerun. No current-source hash is claimed.

`/tmp/payback-restored-history-first.log` records four backend passes and one
failure: valid unmarked legacy X→B consent was missed when canonical A/B rows
did not contain X and the account alias array was absent. An indexed repair is
underway; RA14 is not green. The independent backup/UI reviewer also requested
changes for overlapping imports: the second request fails the active core gate,
then the first delayed result overwrites the second UI result. Financial state
remains fenced. A production coordinator/token repair is underway, with no green
runtime result yet. See review cases R54/R55 and RA11/RA14.

## Local type generation for restore integration

The first local attempt failed before generation because `CONVEX_DEPLOYMENT`
was absent (`/tmp/payback-restore-codegen1.log`):

```bash
bunx --no-install convex codegen --typecheck disable
```

The successful **local-only** command exited 0
(`/tmp/payback-restore-codegen2.log`):

```bash
bunx --no-install convex codegen --typecheck disable --system-udfs
```

Source verification uses installed Convex 1.31.7,
`node_modules/convex/src/cli/lib/components.ts:85–151`. With `systemUdfs`, this
branch calls local `doCodegen`; it does not take the deployment-credential and
component-push branch. No deployment or production mutation occurred. This gate
proves type generation only, not runtime behavior or API compatibility. Logs
contain a nonfatal Node localStorage experimental warning. Preserve this exact
command in the final verification record; frozen design files are unchanged.

## Historical: Import UI ownership proof

The cheap production-helper proof changed from `AFTER_SECOND [second:failed]`,
`FINAL [second:failed,first:incomplete]` to `AFTER_SECOND []`,
`FINAL [first:success]`. Logs are `/tmp/payback-import-ui-before.log` and
`/tmp/payback-import-ui-after.log`. The production `ImportOperationOwnership`
helper now rejects overlap and fences completion. Its three new XCTest cases
and independent reviewer recheck remain pending; this does not complete RA11.

## Historical: Restore focused SDK checkpoint2: green at recorded hashes

`/tmp/payback-restore-focused2.log` and its Xcode summary record **321 tests passed,
0 failures, 0 unexpected, 0 skips**. The parent verified the source manifest stayed
unchanged during the build. AppStoreLinking80 includes12 history cases;
ConvexRestoreTransport10 and ImportOperationOwnership3 passed, alongside selected
import/export, actor, adaptive and expense suites. The prior nine summary-copy
failures, newer neutral recovery guards, typed expense errors and UI ownership
regressions are closed at this checkpoint.

- Log SHA256: `b11a64ddf02114ad74b4d22bd21c2014b2716796e20d511d2e359ca7bfd562db`.
- Summary SHA256: `bf26897832065d6a59e78f9c093a230265b7c2557585db728e4bdfe75ab21da6`.
- `/tmp/payback-restore-focused2-source.sha256` SHA256:
  `87118fa3219aeac766d7c81212eabb29807cd6264a5d91ef4b9e6d003ca15bdd`.

This is a focused SDK/client gate, not final assembled or live integration proof.
RA11/RA12 still need real backend budget/job/materialization coverage and fresh
review. The stronger backend linkage test reportedly found a stored grant missing
behind filtered reads; its repair is not marked green here without the exact
current log and final parent verification. All14 acceptance requirements remain
incomplete as whole gates.

## Historical: Restore final-review checkpoint: additional cases R56–R66

Client and backup reviews approve their E31-bound slices (E34/E35). Financial and identity reviews request changes (E32/E33); final assembled approval remains open. Independent proofs found missing-group partial commits, inactive replay/schema and privacy defects, pending authoring, grouped-individual friendship bypass, two deletion/history dependency cycles, ordinary local-alias stewardship loss, and stale explicit-direct grants/revisions. R65 is an intended policy outcome, not a defect: after stewardship, financial projection uses the new owner’s scope without copying the old owner’s local alias authority; original money/flags remain intact.

The accounts repair checkpoint passes 18/18 tests in two owning files (`/tmp/restore-accounts-review-fixes1.log`). The financial checkpoint passes 128/128 across eight owning files (`/tmp/payback-restore-financial-owning6.log`), including restoredHistoryAccess29 and budget6. These are working-tree checkpoints with the named cases in [before-after.json](before-after.json), not final source-bound approvals or canonical/sanitizer results. The financial owner’s hash manifest is `/tmp/payback-final-financial-source-hashes2.txt`; later edits still require revalidation. An earlier owning run with passing assertions but unhandled scheduler errors is not counted as a successful gate.

Independent reports: `/tmp/payback-restore-code-financial-r1.md`, `/tmp/payback-restore-code-identity-r1.md`, `/tmp/payback-restore-code-client-r1.md`, and `/tmp/payback-restore-backup-review-r1.md`. Temporary reviewer proofs use actual backend schema, functions and helpers; no live deployed backend was exercised. All14 restore acceptance gates remain incomplete, and hosted CI remains blocked before execution by billing.

## Historical: Full CI failure and subsequent repair checkpoint

`bun run ci` failed: 835 of847 backend tests passed and12 failed across6 files. Preserve `/tmp/payback-restore-ci1.log` (raw ANSI/NUL) and `/tmp/payback-restore-ci1-clean.log` (readable); E38 is a failed gate. Later focused passes are59/59 for the65-participant deletion budget,68/68 for typed metadata group boundaries,125/125 fixture cases, and4/4 metadata fixtures. No caps were raised. After a valid optimization made the old large worker fixture fit, a distinct-identity fixture now proves actual rollback8→4→completion through worker and publicV3 paths:45/45 in `/tmp/payback-history-budget-final.log`. These targeted checks do not substitute for rerunning full CI.

R67 records missing capability fencing for restored grouped-individual duplicate splits (A0 paid/B10 paid/B15 unpaid): an old first-row reader can forgive15. Repair is underway; unknown currency and group-free access must remain unchanged, without introducing GROUP/DIRECT privacy restrictions. R68 records the sole-local-alias ordinary GROUP stewardship variant, with4 focused passes and8 filter-excluded tests in `/tmp/restore-ordinary-group-steward-green.log`. Earlier source manifests and approvals are stale after these repairs; fresh freeze, independent rechecks and final canonical/sanitizer runs remain pending.

## Historical completion checkpoint: Assembled3 source approval and acceptance checkpoint

Production is committed at `8c50d693f551e6b66916579e1590d4f72949c478` (backend `5dfd5dd3`, client `8c50d693`), matching the510-file assembled3 manifest SHA256 `45f5cc5e5e9d2d8e7243f8615198cc908e3bb1c80ccf3103e2779ffeab448550`. Repository CI3 passes882/882 across88files plus lint/typecheck/format/web build (`/tmp/payback-restore-ci3-clean.log`). Financial Sol R4, identity Sol R3 and client Sol R4 APPROVE this source. Gemini R2 also approves with all510 hashes matching; its earlier drifting R1 report is not current approval. Reports and hashes are E43.

The acceptance audit produced real backend capacity8, privacy3, deletion-timing4 and recovery4 sequences. R69 captures the64-member two-restores/later-relink page-budget failure; R70 captures a maximum129-dependency single-record worker failure. Canonical-only visibility preparation, a shared transaction-local page cache and removal of redundant incorrectly owner-scoped readiness work repair these without raising limits. Raw claim/membership/proven-alias variants measure1386/1371/1639 queries against2048; preserve exact source rows,64-member roster and financial-only grants. Independent reviewers reran these paths and prior negative proofs.

The new SDK acceptance run executes110 tests with one old JSON object-key-order assertion failure. The new two-cycle64/100 composition and three mixed direct roundtrip tests pass. The test-only comparison now canonicalizes object keys while preserving array/value/numeric-wrapper checks; its full runtime rerun was pending at this checkpoint and subsequently passed as a named selector in standard1 below. The complete canonical SDK gate, TSan and ASan are not yet claimed passed. RA05 pending-history bulkImport rollback remains under audit; other named local behavioral seams are mapped explicitly in RESTORE_ACCEPTANCE.md. All review and test evidence remains bounded to local execution, not deployed network or provider operation.

## Historical completion checkpoint: Canonical standard1: failed whole gate, named acceptance passes

`/tmp/payback-restore-standard1-summary.json` records2933 total,2931 passed,2 failed,0 skipped; the raw test log reports2 unexpected failures. Both are obsolete MockAccountService success expectations in `ConvexAccountServiceTests/testBulkImport` and `testBulkImport_WithData_ReturnsCorrectCounts`, which receive `IMPORT_UNSUPPORTED_SERVICE`. Preserve `/tmp/payback-restore-standard1.log`, `/tmp/payback-restore-standard1-test-output.log` and `/tmp/PayBackRestoreStandard1.xcresult.zip`. This is a separate failed run from E45’s110-test JSON-order failure.

The real-adapter two-cycle64-member/100-expense test, all3 mixed raw/canonical direct roundtrips, both adaptive import composition tests and the corrected canonical-JSON lost-response test each pass in this full run. RA02/03/11 therefore have actual named full-suite runtime evidence while the whole gate remains failed. The two test-only mock expectation corrections are committed as `8829c040` and client-approved in `/tmp/payback-restore-client-test-delta.md` (reviewed test SHA256 `7487839d123116e6bcbd61847ea2164a433be66832b531a226dfc882272e8ed8`). Standard2 is running at `/tmp/payback-restore-standard2.log`. Production is unchanged; current TSan/ASan remain pending. E47 stores exact artifact hashes.

## Historical completion checkpoint: Pending-history import acceptance proof

E48 (`/tmp/payback-pending-import-acceptance.log`) passes the new test-only RA05 selector `RA05 pending restored-history import rolls back every header and financial effect, then the same payload succeeds after reconciliation`. An actual public membership mutation creates the pending job; failed import preserves all15 snapshots including scheduler/account floors. Real worker drain followed by the identical payload creates1friend/1group/1expense and preserves raw financial rows. Test SHA256 `50a94e74c872dd98a26ab0cc19e3ef840a0da11b3b4efb3ab6aa692c276afa8e`. No production edit was required. This closes the previously unlocated behavioral seam; full-suite inclusion and final test-source binding remain pending.

## Historical completion checkpoint: Canonical standard2 passed on final source

`/tmp/payback-restore-standard2-summary.json`:2933 SDK tests passed,0 failed,0 skipped. The canonical wrapper exits0 with882backend tests across88files, browser smoke1, all repository checks and warnings gate passing. The already-started backend list did not include the new RA05 test; E48 separately passes1/1. Preserve `/tmp/payback-restore-standard2.log` and `/tmp/PayBackRestoreStandard2.xcresult.zip`.

Final binding: commit `80061a9d5a2775a786dd07d76b6ca89d9f977345`,511-file `/tmp/payback-restore-final-source.sha256`, SHA256 `064742f486a93f3bb638196f23ec1be0b494f03157e56a9965c817106503d7a5`. Production remains unchanged from approved8c50d693. Client approves the obsolete mock-test correction, financial reviewer approves the new pending-import test at this binding; identity test-delta recheck is pending. Current Thread Sanitizer is running at `/tmp/payback-restore-thread1.log`; current Address Sanitizer remains pending. These facts supersede earlier pending canonical statuses, while historical failed runs remain recorded. No live/backend-provider rollout is claimed.

## Primary-source research references

Rechecked2026-11-06 against official Convex documentation and installed sources. These explain the contracts; actual pinned-version tests provide the implementation evidence.

- [OCC and atomicity](https://docs.convex.dev/database/advanced/occ): mutation transactions commit atomically; this supports whole-chunk rollback assertions.
- [Scheduled functions](https://docs.convex.dev/scheduling/scheduled-functions): scheduling from a mutation shares its commit/rollback; action scheduling is not atomic with an action’s eventual outcome.
- [Server Auth](https://docs.convex.dev/api/interfaces/server.Auth): `getUserIdentity()` supplies authenticated identity or null. Local TypeScript Convex1.31.7 source `node_modules/convex/src/server/authentication.ts:236` and `scheduler.ts` were inspected.
- [Data types](https://docs.convex.dev/database/types): Int64 and Float64 are distinct wire/validator types. Actual Swift SDK0.7.0 recording-transport tests establish the app’s encoding, beyond documentation alone.
- [Schemas](https://docs.convex.dev/database/schemas): default validation covers existing documents on schema push and subsequent writes; optional/additive rollout compatibility remains required.
- [Platform limits](https://docs.convex.dev/production/state/limits): current documentation lists4,096 index ranges read per transaction. The2,048 budget in `expenseWrites.ts`, `groupHistory.ts` and `helpers.ts` is PayBack’s stricter guard, not the Convex platform limit.

No newer documentation-only API was introduced, and no backend deployment was performed.

At the E50 historical completion checkpoint, identity `/tmp/payback-restore-final-test-identity.md` joined the financial and client approvals. The TSan wrapper repository CI had passed883tests/89files including RA05; its SDK phase was still running and ASan had not yet completed. Later E51/E53 results below supersede that execution status.

## Historical completion checkpoint: Thread Sanitizer passed

`SANITIZER=thread ./scripts/test-ci-locally.sh` exits0 on unchanged final511-file source. `/tmp/payback-restore-thread1-summary.json` records2891 selected SDK tests,0 failures,0 skips. Existing selectors exclude42 performance tests; they are not skipped test results. The same wrapper passes883backend tests across89files, including RA05, and repository/warning/sanitizer-diagnostic checks. Artifacts: `/tmp/payback-restore-thread1.log`, `/tmp/payback-restore-thread1-summary.json`, `/tmp/PayBackRestoreThread1.xcresult.zip` (E51 hashes).

At this E51 checkpoint, Address Sanitizer was running in `/tmp/payback-restore-address1.log`; standard2 and TSan had passed, all14 local proof mappings were present and final source/test reviews approved. ASan was the remaining local execution gate and subsequently passed as recorded below. Live/provider and rollout prerequisites remain separate.

## Historical completion checkpoint: first ASan execution and incomplete artifact

All current local execution gates pass on unchanged final511-file source80061a9d: standard2 SDK2933/0failures; TSan2891selected/0failures/0skips; ASan2933/0failures. Existing TSan selectors exclude42performance tests, not42skips. Both sanitizer wrappers pass883backend tests/89files including RA05; repository, warning and sanitizer-diagnostic gates pass. Final primary production/test reviews approve, with lower-weight Gemini R2 agreement. All14 acceptance requirements have named local proof with explicit backend/recording-transport seams.

ASan log `/tmp/payback-restore-address1.log` independently records2933tests/0failures and successful wrapper completion. Parent reports0skips. The summary export currently reports unknown/zero and is being reconciled; no hash of that empty summary is represented as pass evidence. Archive `/tmp/PayBackRestoreAddress1.xcresult.zip` is being retained. E52 binds the passing execution log, unchanged source and this metadata limitation.

Hosted CI never executed because of the billing lock. Source-only/partial cases, meaningful web unit-coverage gap and live/operator requirements remain explicit. Local gates do not claim production deployment, migration or real-provider/device execution.

## Final Address Sanitizer artifact verified

E53 repeats the exact E52 ASan-instrumented binary with `xcodebuild test-without-building`; no source or build change occurred. `/tmp/payback-restore-address2-summary.json` is valid: Passed2933/2933,0 failures,0 skips. `/tmp/payback-restore-address2-raw.log` retains the full command and2933 individual passed results; no failed/skipped test lines or warnings. The sanitizer diagnostic check passes, and the parent confirmed `libclang_rt.asan_iossim_dynamic.dylib` linkage. `/tmp/PayBackRestoreAddress2.xcresult.zip` is archived.

The first ASan wrapper’s passing log/backend883 result remains E52; its empty result-tree/unknown-zero summary is an explicitly historical artifact limitation. E53 supplies the clean structured SDK proof without rerunning or changing the build. All current local gates and final source/test reviews now pass. All14 local acceptance requirements are complete within the recorded backend/client seams. The original20 source-only,34 partial,8 external,1 policy and1 web coverage-gap cases are not relabeled as fully runtime-tested. Hosted CI billing and live/operator prerequisites remain separate.
