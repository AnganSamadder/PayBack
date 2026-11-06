# Implementation review record

The plan review is recorded in `REVIEW_LOG.md`. This file records reviews of the
implementation. An approval applies to the code inspected in that round, not to
later changes. Pending fixes and test runs do not count as approvals.

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
performance tests. Address Sanitizer and post-PR review are still pending.
