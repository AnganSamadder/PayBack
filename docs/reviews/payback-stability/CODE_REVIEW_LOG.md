# Implementation review record

Current checkpoint: all three Sol scopes and final test-only deltas APPROVE; Gemini R2 agrees. Standard2/TSan/ASan execution gates pass on unchanged final511-file source. Earlier review rounds retain historical verdicts; live/operator checks remain separate.

The plan review is recorded in `REVIEW_LOG.md`. This file records reviews of the
implementation. An approval applies to the code inspected in that round, not to
later changes. Pending fixes and test runs do not count as approvals.

## Current state

Core R3 repairs are committed at `996c098b`; restore design v3 is approved at `4c1b047a`. E31 passes 321 focused SDK tests and client/backup reviews approve their inspected slices. Final backend reviews found the additional R56–R66 cases. E36/E37 pass 18 and 128 owning repair tests, respectively; independent final rechecks, the full current-source gates and all14 acceptance gates remain open. Earlier canonical/sanitizer passes apply only to their recorded source snapshots.

The approved original v3 plan remains recorded separately in `REVIEW_LOG.md`.

Full canonical and both sanitizer passes apply to the source reviewed at
`b1922174925d502fe6ac332c3bb4c57339a6c1dd`, not the later R3 repair set. Current
client regressions passed 81/81 after an earlier 88/88 run. The 760-test backend
CI run predates the latest cleanup fixtures. The integrator also reports 68
owning tests passing; that is a scoped result, not a final assembled gate.
Hosted CI never started because of the billing restriction. No final approval,
production migration, deployment or provider cutover is claimed.

## First implementation reviews

Independent reviewers reproduced these defects during implementation. Owners fixed
them and added focused regressions before the assembled-code review.

| Defect                                                                        | Repair and evidence                                                                                                                      |
| ----------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| A locally merged placeholder could not be claimed through V3.                 | Canonicalize the surviving friend record while preserving financial rows. `review_locally_merged_claim.test.ts` covers both claim paths. |
| An omitted direct-expense context bypassed participant validation.            | Validate the effective stored context. `reviewFinancialR1Proof.test.ts` covers rejection and rollback.                                   |
| Editing notes could delete an imported single subexpense.                     | Preserve unchanged subexpenses. `reviewFinancialR1Proof.test.ts` covers the metadata edit.                                               |
| Restore could replay cleared or skipped source records into local state.      | Publish an authoritative server refresh. `scripts/test-backup-production.sh` exercises the production import branch.                     |
| A cancelled restore could leave the import gate active or clear a newer gate. | Fence gate ownership by operation and actor. The production import check covers cancellation and account switching.                      |
| Restore could replace a historical participant name with the current profile. | Preserve exported names. `BackupRoundTripRegressionTests` covers the name.                                                               |
| Invalid settlement booleans silently became false.                            | Reject malformed values. Backup regression tests cover both fields.                                                                      |
| Indexed alias lookup still scanned unrelated owner aliases.                   | Query and cache requested seeds only. `expenseStabilityV3.test.ts` covers 1,025 unrelated alias rows.                                    |

## Assembled-code review, round 1

Three fresh GPT-6.1 Sol reviewers independently inspected identity, financial, and
client behavior. All three requested changes. Gemini approved, but missed the
reproduced defects below. Its lower-weight approval does not override those
findings or satisfy the final gate.

| Reviewer        | Defect                                                                                                                             | Current disposition                                                                |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Identity        | The production Merge Friends adapter sent argument names absent from the V3 validator.                                             | Fixed; concrete adapter regressions pass in the canonical iOS suite.               |
| Client          | Ordinary friend writes encoded absent optional strings as null, rejected by the backend.                                           | Fixed; concrete adapter regressions pass in the canonical iOS suite.               |
| Identity        | Revoked materialized aliases still appeared in the viewer response and authorized group changes.                                   | Fixed; live-provenance and cross-account regressions pass.                         |
| Identity        | Group leave and member removal ignored the group owner's local aliases.                                                            | Fixed; owner-scoped lifecycle regressions pass.                                    |
| Financial       | The settlement sheet and mutation used different alias scopes. Selecting $10 could settle $25, or the reverse.                     | Fixed; exact split selection and owner-scoped financial identity regressions pass. |
| Client          | An interrupted friend deletion prevented account lookup and could lose its recovery operation ID.                                  | Fixed; neutral recovery, lost receipts, and multiple-job tests pass.               |
| Client          | Explicit login bypassed pending identity-operation recovery.                                                                       | Fixed; staged login and account-switch recovery tests pass.                        |
| Client          | Legacy display-preference migration called a disabled mutation overload.                                                           | Fixed; actor-bound settings migration tests pass.                                  |
| Transport audit | Group pagination and clear batches sent invalid null cursors or cutoffs. Legacy paging sent Int64 limits and omitted capability 2. | Fixed; emitted-argument and actual backend validator tests pass.                   |

The first complete repository CI run after fixture integration passed 665 backend
tests across 65 files, lint, typecheck, formatting, and the web build. That run
predates the round 1 repairs above. Final verification remains pending. The first
full iOS run exposed failures that are retained in the review logs; it is not a
passing gate. Disk exhaustion also corrupted that run's result bundle. No iOS or
sanitizer approval is claimed until the repaired code passes those gates.

## Financial scope repair under review

The settlement finding exposed two separate requirements. A capability-2 caller
must select immutable raw split IDs so a selected $10 row cannot silently expand
to a $25 alias group. Legacy member-ID selection keeps its existing contract only
where the capability floor permits it.

Selection alone does not fix balances. If A locally merges placeholder X into B,
B can receive an expense containing raw X without knowing A's local alias. The
client therefore needs an additive, derived expense identity map from the
authorized server response. It must reflect the expense owner's live identity
scope. Clients use it for financial classification; servers never accept it as
write authority. Payer, split IDs, amounts, names and settlement flags remain
unchanged. Read, save and settlement responses must agree, and cached snapshots
must obey the existing generation fences. This implements the approved plan's
owner-scoped identity rule; the exact response contract requires the next review.

## Assembled-code review, round 2

Three fresh Sol reviewers found the following defects. Their verdicts remain
request changes until the repairs are independently checked. The current full
iOS run reuses the previously compiled bundle, so it cannot verify later source
changes from this round.

| Defect                                                                                                                     | Repair state                                                                                                                               |
| -------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Clear All removed visibility but retained a foreign owner's locally aliased membership; reconciliation restored the group. | Shared live group-membership resolution now serves leave and both clear paths. New public lifecycle regressions and 23 focused tests pass. |
| Recreating deleted friends with the same backup UUIDs replayed an obsolete completed merge.                                | Fixed; restored UUIDs start a fresh operation while valid retries reuse the current operation.                                             |
| Removing an owner-local friend alias changed peer expense identity maps without advancing their snapshot generation.       | Fixed; peer revisions advance and old unfinished jobs replay bounded reconciliation.                                                       |
| Expense deletion trusted raw account alias arrays even when live provenance rejected the alias.                            | Fixed; both deletion paths require live identity proof and preserve unauthorized records.                                                  |
| Friend-detail cards and group filters ignored the expense's identity map.                                                  | Fixed; the shared production helper and all four scoped card/filter tests pass.                                                            |
| Add Expense treated the group creator's persisted self flag as the current caller.                                         | Fixed; caller identity and projected group participants drive authoring and labels.                                                        |
| Early explicit-login recovery failures exposed empty authenticated tabs with no retry state.                               | Fixed; staging, visible recovery, successful retry, and stale completion tests pass.                                                       |

The backend and web gates in the first canonical wrapper run passed 697 tests
across 69 backend files and one browser smoke test. The wrapper then stopped at
simulator selection because it matched a device's custom name rather than its
iPhone device type. The selector now uses the device type and selects the same
dedicated simulator. That run did not execute iOS tests.

The next linked-group authoring check reproduced a related case. B selected raw
group member X, which group owner A locally identified as B. A new expense owned
by B then retained X without B's identity mapping. New authoring must resolve that
group context before persistence. Historical edits and imports keep their raw
rows. Group read responses will also provide an additive `member_identity_map`
so Add Expense can offer one participant per resolved group identity and choose
the signed-in caller correctly. The map is derived, cached with the snapshot,
and omitted from mutation and backup inputs. This contract and its bounded read
cost require the next review.

The full SDK-enabled iOS bundle built before the round 2 changes passed 2,866
tests with zero failures. It verifies the earlier repair set, not the later
authoring, login, deletion, or People-view changes. Final canonical and sanitizer
gates are still pending.

## Integrated verification before post-PR review

At source commit `d20cd85c`, the canonical standard wrapper passed repository
checks, all 730 backend tests across 73 files, one web smoke test, and all 2,887
SDK-enabled iOS tests with no failures or skips. The four prior login fixture
failures were repaired without weakening production recovery. The matching
Xcode result summary is retained with the local evidence.

All supported findings from rounds 1 and 2 now have repairs. This is not final
review approval. Thread Sanitizer, Address Sanitizer, and fresh post-PR reviews
remain pending. Production backfills, provider continuity, Release configuration,
and live integration prerequisites remain separate from local test results.

The round 2 payment-breakdown check also found that a canonical payer absent
from the viewer's directory could disappear from the recipient list. The helper
now retains the canonical aggregation key and the recorded raw payer name as a
display fallback. Both the amount and recipient remain visible. Production
helper regressions pass in the canonical suite.

Thread Sanitizer has now passed all 2,845 selected tests with no failures,
warnings, or sanitizer diagnostics. The existing configuration excludes 42
performance tests. At that stage Address Sanitizer and post-PR review were still pending; subsequent results are recorded below.

## Post-PR review, round 3

The initial reviewed snapshot was `b192217`. All three Sol reviewers requested
changes. Gemini approved as a lower-weight challenger; its verdict did not
override the reproduced failures.

| Finding                        | Before                                                                                                                          | Current disposition                                                                                                                                                                         |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Foreign projection generation  | C-owned pages changed their global identity projection during a claim while retaining the previous revision.                    | Pending barriers, retained-viewer revisions and bounded reverse owner-local work are repaired. Identity slice approved after independent tests.                                             |
| Reclaimed local alias deletion | Deleting Y could destroy registered B's independently claimed X history, including a claim after deletion captured its closure. | Every destructive phase uses live authority and preserves linked history. Before-start/in-flight proofs pass.                                                                               |
| Pending saved projection       | Successful local saves could pin an old financial map forever when full equality never matched the server.                      | Current server projection wins with per-entity ownership; real AppStore regressions pass. Client slice approved.                                                                            |
| Group context-menu friend add  | The import bypass published confirmed state and success before persistence.                                                     | Production action waits for acknowledgement and fences duplicate taps, cancellation and session changes. Four action tests pass.                                                            |
| Canonical expense restore      | New authored canonical B rows failed restore into the preserved raw A/X group.                                                  | Original unchanged create/delete/restore proof now passes; the separate full-roster boundary remains open.                                                                                  |
| Portable roster boundary       | A valid 64-member source exported 65 members and failed the backend limit.                                                      | Still REQUEST CHANGES. A bounded historical-manifest contract needs exact design approval and implementation; no truncation, roster-limit increase or imported alias authority is accepted. |

Two additional defects were found during recheck and repaired before the scoped
approvals. Cancelled saves used a cancellation-sensitive predicate for rollback,
leaving their own optimistic rows behind. Rollback now checks actor/epoch/token
ownership independently of cancellation; five cancellation cases pass. Revocation
could retain an advanced dependent cursor and leave a stale derived grant after
terminal completion. Durable dependent work is reset and drained before marker
retirement; the independent proof now leaves zero obsolete viewer rows.

### Scope of the R3 rechecks

- **Identity/cleanup: APPROVE for recorded source hashes only.** Reviewer ran 38
  owning tests and four private proofs. No unhandled errors remained. A nonfatal
  `TimeoutNegativeWarning` in the foundations fixture is retained in the report.
  This does not approve later restore contracts or the whole assembled app.
- **Client: APPROVE for the repaired client slice only.** Reviewer inspected
  production source and `/tmp/payback-repair-r3-focused2.log`, which records 81
  selected real SDK/AppStore tests passing. The prior 88-test run preceded the
  cancellation repair. No final restore or full-app approval is implied.
- **Financial/restore: REQUEST CHANGES.** Reviewer reran the original restore
  proof successfully and 67 owning tests passed, but the actual exporter/parser
  and backend 64-to-65 proof fails. Final approval requires the portable history
  contract to be approved and implemented, then independently rechecked.

Reports are `/tmp/payback-post-pr-identity-r3.md`,
`/tmp/payback-post-pr-client-r3-recheck.md`, and
`/tmp/payback-post-pr-financial-r3.md`. Their hashes and executed commands are
recorded in [before-after.json](before-after.json). The complete matrix now has
39 additional review cases. `PR_CASES.md` intentionally retains its previous
36-review-case snapshot until the integrator requests body regeneration.

### Hosted CI

GitHub did not start the job because of a billing-lock annotation. This is neither
a hosted pass nor an executed code failure. The blocked job is
[GitHub Actions job 127689290523](https://github.com/AnganSamadder/PayBack/actions/runs/42155729035/job/127689290523).
Local results remain valid only for their recorded source snapshots.

## Restore addendum v3 design approval

Commit `4c1b047a60f9d6b15f886a14e67ed7d850bb7b23` records approval of exact
SHA256 `645d86e0f581dcb57c6179ddaa8a979f01260595e5d55cca233264bff927e7ad`.
All three Sol design reviewers and Gemini approved. This is design approval only;
it does not close the financial restore finding or approve implementing code.

[RESTORE_ACCEPTANCE.md](RESTORE_ACCEPTANCE.md) assigns all 14 acceptance gates to
owners and names the required production-path proofs. Every gate starts pending.
Newly restored GROUP/DIRECT sharing restrictions are distinct from unchanged
ordinary-history access. Authoritative deleted-party privacy can scrub display
identity and active membership; it cannot rewrite or drop historical money rows.
No current-source full or sanitizer gate is claimed for the addendum.

## Restore implementation evidence, first checkpoint

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

## Restore focused checkpoint, with open defects

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

## Import UI ownership, cheap repair proof

The R54 production ownership-helper before/after proof now passes: a second
start is refused while the first owns the import, and only `first:success`
publishes. This closes the cheap reproduction at that helper seam. The three
new `ImportOperationOwnershipTests` and independent reviewer recheck are still
pending, so no full UI or RA11 approval is inferred. Log hashes are E30 in the
case manifest.

## Restore focused SDK checkpoint2: green at recorded hashes

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

## Restore final-review checkpoint: additional cases R56–R66

Client and backup reviews approve their E31-bound slices (E34/E35). Financial and identity reviews request changes (E32/E33); final assembled approval remains open. Independent proofs found missing-group partial commits, inactive replay/schema and privacy defects, pending authoring, grouped-individual friendship bypass, two deletion/history dependency cycles, ordinary local-alias stewardship loss, and stale explicit-direct grants/revisions. R65 is an intended policy outcome, not a defect: after stewardship, financial projection uses the new owner’s scope without copying the old owner’s local alias authority; original money/flags remain intact.

The accounts repair checkpoint passes 18/18 tests in two owning files (`/tmp/restore-accounts-review-fixes1.log`). The financial checkpoint passes 128/128 across eight owning files (`/tmp/payback-restore-financial-owning6.log`), including restoredHistoryAccess29 and budget6. These are working-tree checkpoints with the named cases in [before-after.json](before-after.json), not final source-bound approvals or canonical/sanitizer results. The financial owner’s hash manifest is `/tmp/payback-final-financial-source-hashes2.txt`; later edits still require revalidation. An earlier owning run with passing assertions but unhandled scheduler errors is not counted as a successful gate.

Independent reports: `/tmp/payback-restore-code-financial-r1.md`, `/tmp/payback-restore-code-identity-r1.md`, `/tmp/payback-restore-code-client-r1.md`, and `/tmp/payback-restore-backup-review-r1.md`. Temporary reviewer proofs use actual backend schema, functions and helpers; no live deployed backend was exercised. All14 restore acceptance gates remain incomplete, and hosted CI remains blocked before execution by billing.

## Full CI failure and subsequent repair checkpoint

`bun run ci` failed: 835 of847 backend tests passed and12 failed across6 files. Preserve `/tmp/payback-restore-ci1.log` (raw ANSI/NUL) and `/tmp/payback-restore-ci1-clean.log` (readable); E38 is a failed gate. Later focused passes are59/59 for the65-participant deletion budget,68/68 for typed metadata group boundaries,125/125 fixture cases, and4/4 metadata fixtures. No caps were raised. After a valid optimization made the old large worker fixture fit, a distinct-identity fixture now proves actual rollback8→4→completion through worker and publicV3 paths:45/45 in `/tmp/payback-history-budget-final.log`. These targeted checks do not substitute for rerunning full CI.

R67 records missing capability fencing for restored grouped-individual duplicate splits (A0 paid/B10 paid/B15 unpaid): an old first-row reader can forgive15. Repair is underway; unknown currency and group-free access must remain unchanged, without introducing GROUP/DIRECT privacy restrictions. R68 records the sole-local-alias ordinary GROUP stewardship variant, with4 focused passes and8 filter-excluded tests in `/tmp/restore-ordinary-group-steward-green.log`. Earlier source manifests and approvals are stale after these repairs; fresh freeze, independent rechecks and final canonical/sanitizer runs remain pending.

## Current committed assembled3 checkpoint

Production is committed at `8c50d693f551e6b66916579e1590d4f72949c478` (backend `5dfd5dd3`, client `8c50d693`), matching the510-file assembled3 manifest SHA256 `45f5cc5e5e9d2d8e7243f8615198cc908e3bb1c80ccf3103e2779ffeab448550`. Repository CI3 passes882/882 across88files plus lint/typecheck/format/web build (`/tmp/payback-restore-ci3-clean.log`). Financial Sol R4, identity Sol R3 and client Sol R4 APPROVE this source. Gemini R2 also approves with all510 hashes matching; its earlier drifting R1 report is not current approval. Reports and hashes are E43.

The acceptance audit produced real backend capacity8, privacy3, deletion-timing4 and recovery4 sequences. R69 captures the64-member two-restores/later-relink page-budget failure; R70 captures a maximum129-dependency single-record worker failure. Canonical-only visibility preparation, a shared transaction-local page cache and removal of redundant incorrectly owner-scoped readiness work repair these without raising limits. Raw claim/membership/proven-alias variants measure1386/1371/1639 queries against2048; preserve exact source rows,64-member roster and financial-only grants. Independent reviewers reran these paths and prior negative proofs.

The new SDK acceptance run executes110 tests with one old JSON object-key-order assertion failure. The new two-cycle64/100 composition and three mixed direct roundtrip tests pass. The test-only comparison now canonicalizes object keys while preserving array/value/numeric-wrapper checks; its full runtime rerun remains pending. Final canonical SDK, TSan and ASan are not yet claimed passed. RA05 pending-history bulkImport rollback remains under audit; other named local behavioral seams are mapped explicitly in RESTORE_ACCEPTANCE.md. All review and test evidence remains bounded to local execution, not deployed network or provider operation.

## Canonical standard1: failed whole gate, named acceptance passes

`/tmp/payback-restore-standard1-summary.json` records2933 total,2931 passed,2 failed,0 skipped; the raw test log reports2 unexpected failures. Both are obsolete MockAccountService success expectations in `ConvexAccountServiceTests/testBulkImport` and `testBulkImport_WithData_ReturnsCorrectCounts`, which receive `IMPORT_UNSUPPORTED_SERVICE`. Preserve `/tmp/payback-restore-standard1.log`, `/tmp/payback-restore-standard1-test-output.log` and `/tmp/PayBackRestoreStandard1.xcresult.zip`. This is a separate failed run from E45’s110-test JSON-order failure.

The real-adapter two-cycle64-member/100-expense test, all3 mixed raw/canonical direct roundtrips, both adaptive import composition tests and the corrected canonical-JSON lost-response test each pass in this full run. RA02/03/11 therefore have actual named full-suite runtime evidence while the whole gate remains failed. Two test-only mock expectation corrections await client review and standard2. Production is unchanged; current TSan/ASan remain pending. E47 stores exact artifact hashes.

## Pending-history import acceptance proof

E48 (`/tmp/payback-pending-import-acceptance.log`) passes the new test-only RA05 selector `RA05 pending restored-history import rolls back every header and financial effect, then the same payload succeeds after reconciliation`. An actual public membership mutation creates the pending job; failed import preserves all15 snapshots including scheduler/account floors. Real worker drain followed by the identical payload creates1friend/1group/1expense and preserves raw financial rows. Test SHA256 `50a94e74c872dd98a26ab0cc19e3ef840a0da11b3b4efb3ab6aa692c276afa8e`. No production edit was required. This closes the previously unlocated behavioral seam; full-suite inclusion and final test-source binding remain pending.

## Canonical standard2 passed on final source

`/tmp/payback-restore-standard2-summary.json`:2933 SDK tests passed,0 failed,0 skipped. The canonical wrapper exits0 with882backend tests across88files, browser smoke1, all repository checks and warnings gate passing. The already-started backend list did not include the new RA05 test; E48 separately passes1/1. Preserve `/tmp/payback-restore-standard2.log` and `/tmp/PayBackRestoreStandard2.xcresult.zip`.

Final binding: commit `80061a9d5a2775a786dd07d76b6ca89d9f977345`,511-file `/tmp/payback-restore-final-source.sha256`, SHA256 `064742f486a93f3bb638196f23ec1be0b494f03157e56a9965c817106503d7a5`. Production remains unchanged from approved8c50d693. Client approves the obsolete mock-test correction, financial reviewer approves the new pending-import test at this binding; identity test-delta recheck is pending. Current Thread Sanitizer is running at `/tmp/payback-restore-thread1.log`; current Address Sanitizer remains pending. These facts supersede earlier pending canonical statuses, while historical failed runs remain recorded. No live/backend-provider rollout is claimed.

## Current Thread Sanitizer passed

`SANITIZER=thread ./scripts/test-ci-locally.sh` exits0 on unchanged final511-file source. `/tmp/payback-restore-thread1-summary.json` records2891 selected SDK tests,0 failures,0 skips. Existing selectors exclude42 performance tests; they are not skipped test results. The same wrapper passes883backend tests across89files, including RA05, and repository/warning/sanitizer-diagnostic checks. Artifacts: `/tmp/payback-restore-thread1.log`, `/tmp/payback-restore-thread1-summary.json`, `/tmp/PayBackRestoreThread1.xcresult.zip` (E51 hashes).

Address Sanitizer is running in `/tmp/payback-restore-address1.log`. Standard2 and current TSan are green, all14 local behavioral proof mappings are present, and all final source/test reviews approve. ASan is the remaining local execution gate; live/provider and rollout prerequisites remain separate.

## Historical completion checkpoint: first ASan execution and incomplete artifact

All current local execution gates pass on unchanged final511-file source80061a9d: standard2 SDK2933/0failures; TSan2891selected/0failures/0skips; ASan2933/0failures. Existing TSan selectors exclude42performance tests, not42skips. Both sanitizer wrappers pass883backend tests/89files including RA05; repository, warning and sanitizer-diagnostic gates pass. Final primary production/test reviews approve, with lower-weight Gemini R2 agreement. All14 acceptance requirements have named local proof with explicit backend/recording-transport seams.

ASan log `/tmp/payback-restore-address1.log` independently records2933tests/0failures and successful wrapper completion. Parent reports0skips. The summary export currently reports unknown/zero and is being reconciled; no hash of that empty summary is represented as pass evidence. Archive `/tmp/PayBackRestoreAddress1.xcresult.zip` is being retained. E52 binds the passing execution log, unchanged source and this metadata limitation.

Hosted CI never executed because of the billing lock. Source-only/partial cases, meaningful web unit-coverage gap and live/operator requirements remain explicit. Local gates do not claim production deployment, migration or real-provider/device execution.

## Final Address Sanitizer artifact verified

E53 repeats the exact E52 ASan-instrumented binary with `xcodebuild test-without-building`; no source or build change occurred. `/tmp/payback-restore-address2-summary.json` is valid: Passed2933/2933,0 failures,0 skips. `/tmp/payback-restore-address2-raw.log` retains the full command and2933 individual passed results; no failed/skipped test lines or warnings. The sanitizer diagnostic check passes, and the parent confirmed `libclang_rt.asan_iossim_dynamic.dylib` linkage. `/tmp/PayBackRestoreAddress2.xcresult.zip` is archived.

The first ASan wrapper’s passing log/backend883 result remains E52; its empty result-tree/unknown-zero summary is an explicitly historical artifact limitation. E53 supplies the clean structured SDK proof without rerunning or changing the build. All current local gates and final source/test reviews now pass. All14 local acceptance requirements are complete within the recorded backend/client seams. The original20 source-only,34 partial,8 external,1 policy and1 web coverage-gap cases are not relabeled as fully runtime-tested. Hosted CI billing and live/operator prerequisites remain separate.
