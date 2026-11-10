# Account linking pipeline runbook

V3 linking preserves the original expense rows and reconciles access through resumable jobs.
This runbook describes the repository implementation. It does not establish that a deployment has
received the code, completed its migrations, or passed a production rollout check.

## Identity and financial records

| Record                                                   | Authority and purpose                                                                                                                                           |
| -------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `accounts.member_id`                                     | Immutable registered-account identity, assigned by the server.                                                                                                  |
| `accounts.alias_member_ids` and trusted `member_aliases` | Account aliases established through consent-bound linking. Alias materializations carry `materialization_source: "account_alias"` and `source_account_id`.      |
| `account_friends`                                        | An owner's confirmed relationship. Group membership and direct expense storage do not establish friendship.                                                     |
| `account_friends.local_alias_member_ids`                 | Owner-local equivalence created by an explicit local merge. These IDs never become global account aliases through that merge.                                   |
| `owner_member_aliases`                                   | Indexed candidates for the owner's local alias closure. Resolution rereads the bound friend and validates its current owner, closure, and linked-account proof. |
| `member_references`                                      | Indexed group and expense candidates containing a normalized raw member ID. A reference is not authorization.                                                   |
| `group_visibility` and `user_expenses`                   | Derived access indexes. Reads recheck current identity, inactive participants, deletion state, and expense suppression.                                         |

Canonical IDs cannot be adopted from another person's placeholder. `users:store` assigns a missing
canonical ID server-side. `users:bootstrapMemberIdentityV2` returns
`{account_id, member_id, version: 2}` for explicit recovery. The old
`users:updateLinkedMemberId` endpoint only acknowledges an exact existing canonical match; a
mismatch requires refresh or upgrade. Never repair this by assigning the requested placeholder.

V3 claims establish only the explicitly consented placeholder-to-account alias. A selected reciprocal
friend merge, or an inviter's existing local aliases, gets a separate owner-scoped operation. A
shared dependency chain keeps the returned claim pending until those operations finish.

V3 does not rewrite original payer IDs, involved IDs, split IDs, amounts, settlement flags,
participant names, or ownership. For example, $10 settled under an old ID and $15 unpaid under the
canonical ID remain two historical rows with $15 outstanding. Readers must include every matching
raw row. A person is settled only when all their applicable rows are settled. Currency-aware
readers keep explicitly recorded denominations separate. Pre-currency records retain their legacy
locale-based display and balance behavior through a read-only presentation fallback; their raw
currency remains absent in storage, transport, and backups. This fallback does not prove a
historical denomination or convert a recorded currency.

The synchronous legacy merge path can physically coalesce uniform settlement rows. It rejects a
mixed settled/unpaid collision atomically. Changing the settlement flag aggregation cannot repair
that collision without either reviving paid debt or forgiving unpaid debt.

Group reads, leaving, Clear All, and owner-initiated member removal resolve membership using the
group's actual owner and current identity proof. A participant represented by an owner-local alias can
leave the group they can read. A revoked materialized alias cannot authorize leaving or identify
someone for canonical-ID removal. Member removal still requires the group owner and preserves
unaffected expense records.
Clear All removes the caller's matching raw membership IDs from shared groups before discarding
visibility. Later reconciliation cannot restore access from the old membership. Expense suppression
remains separate and survives group cleanup.

Adding a friend or sending an invitation does not create a direct expense ledger. The first
successful direct expense creates or selects the ledger in the same transaction as the expense.

## Endpoint contracts

Financial capability and linking result versions are separate. Current clients send
`financial_contract_version: 2`. Mutations also send the captured actor as `expected_account_id`
and, where supplied, `expected_account_email`. The server derives the real actor from authentication
and rejects a mismatch.

| Endpoint                                | Arguments beyond capability and actor fields                                                      | Result and behavior                                                                                                                   |
| --------------------------------------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `inviteTokens:createV2`                 | `id`, `target_member_id`, `target_member_name`                                                    | Stored token DTO. Reuses the active token for the same eligible owned friend. Build the share URL from returned `id`.                 |
| `inviteTokens:create`                   | Same creation fields                                                                              | Legacy Convex document ID. A different client UUID for an already active invitation still rejects.                                    |
| `inviteTokens:claimV3`                  | `id`, optional `mergeLocalFriendMemberId`                                                         | Stable V3 operation result.                                                                                                           |
| `linkRequests:acceptV3`                 | `id`, optional `mergeLocalFriendMemberId`                                                         | Stable V3 operation result, bound to the authenticated recipient email.                                                               |
| `aliases:mergeUnlinkedFriendsV3`        | `friendId1` is target; `friendId2` is source; optional legacy `accountEmail` must match the actor | Stable owner-local operation result.                                                                                                  |
| `identityOperations:status`             | `operation_id`                                                                                    | Authenticated actor or creator can read the operation result.                                                                         |
| `identityOperations:pending`            | No arguments                                                                                      | A pending or recoverable failed operation for the actor or creator, or `null`. Useful after a lost response.                          |
| `identityOperations:resume`             | `operation_id`, optional `expected_account_id`                                                    | Resumes eligible work and dependencies, returning current progress. A completed or fully reconciled revoked operation stays terminal. |
| `identityOperations:snapshotGeneration` | `financial_contract_version`                                                                      | `{generation}` for coordinated identity and financial hydration. Pending work rejects before returning a generation.                  |

V3 claim and merge mutations require capability 2. Their identity-neutral response is:

```json
{
  "contract_version": 3,
  "operation_id": "<Convex identity_operations ID>",
  "status": "pending"
}
```

`status` is `pending`, `complete`, or `failed`. An error can include `error`. A fully reconciled
revocation returns `status: "failed"` and `outcome: "revoked"`. It is not a successful link, but safe
snapshot reads are available again. Other failed operations remain pending for snapshot purposes
until recovery succeeds.

The compatibility endpoints `inviteTokens:claim` and `linkRequests:accept` return the existing
version-2 identity payload only for synchronous legacy work. That payload contains
`target_member_id`, `canonical_member_id`, `alias_member_ids`, `linked_member_id`,
`linked_account_id`, and `linked_account_email`. They never report a V3 job as completed legacy
success. A pending V3 job produces processing or upgrade-required errors, and a stored V3 operation
continues to require the V3 path even after completion.

Same-actor, same-selection replay returns the original V3 operation while its consent is still
current. Local-merge replay also checks the surviving friend document, current owner and target,
absorbed alias closure, and absence of a restored source friend. Restoring the same UUIDs after
deletion starts a new merge when valid; obsolete history cannot report false completion. Changing
the selected friend or claimant rejects. A completed legacy claim can be resumed
through V3 by creating a visibility operation when the new readiness gates are satisfied. Request
replay also requires durable accepting-account evidence; older ambiguous accepted rows are not
silently assigned to a claimant.

## Consent and request lifecycle

Invite and email acceptance share `prepareClaimForUser` and `applyClaimForUser` in
[`inviteTokens.ts`](../../apps/backend/convex/inviteTokens.ts). Both verify active accounts,
canonical and alias conflicts, self-claim, exact target ownership, and the optional selected local
friend. V3 passes `preserveFinancialReferences: true`.

New claims require an unexpired token or pending request. Existing successful replay verifies its
stored claimant and merge selection rather than starting a new claim. Invite tokens bind the exact
owned friend through `target_friend_id`. Unbound old tokens must be recreated. The compatibility
email-request path can recover a missing binding only from one exact owned target.

Email requests bind the recipient email. Invite URLs remain bearer links; the signed-in claimant
must confirm the inviter and identity being attached. Forwarding a URL can therefore change who
claims it. Do not infer a recipient from a name or automatically select a merge friend.

Decline and cancel act only on pending requests. Accepted request evidence remains intact.
`inviteTokens:revoke` is creator-only and rejects claimed invitation history. Worker revocation
handling responds to changed live identity or friend provenance and account deletion; it does not
turn the claimed-token revoke endpoint into an unlink operation.

Fresh account signup preserves valid incoming email-link requests. Auth-provider email changes
remain an unsupported account transition and require identity-preserving operator recovery. Do not
rewrite email-keyed ownership or create a replacement account as an incidental linking repair.

## Migration gates and rollout

The deployment needs all these completed markers before V3 operations can start:

| Table and key                                          | Required state    |
| ------------------------------------------------------ | ----------------- |
| `identity_materialization_state`, `member_identity_v3` | `status: "ready"` |
| `sync_materialization_state`, `group_visibility_v1`    | `status: "ready"` |
| `sync_materialization_state`, `user_expense_refs_v1`   | `status: "ready"` |
| `member_reference_state`, `member_references_v1`       | `phase: "ready"`  |

Deploy additive schema and all maintaining writers together before backfilling. Group and expense
canonical writers prepare and apply reference changes in the same transaction, with their existing
read/write budgets. Friend writers maintain `owner_member_aliases`. Email-only maintenance that
changes neither member IDs nor authoritative owner ID leaves reference sets unchanged.

The reference backfill reads one source document per invocation, even if a larger `batchSize` is
supplied. Its durable phases are `groups`, `expenses`, `friends`, then `ready`. The friends phase
reads `account_friends` and materializes legacy local aliases before publishing readiness. Retrying
a page replaces or reconciles reference sets without creating duplicates. Source ownership
conflicts stop the transaction and preserve the cursor; they must be investigated before readiness
can advance.

`member_references` covers group members and expense payer, involved, split, participant, and
inactive-participant IDs. It records the authoritative `owner_id` and source revision, and indexes
member/kind, entity, and owner/member/kind. After readiness, owner-local resolution uses
`owner_member_aliases` for requested IDs rather than scanning an owner's unrelated friends. The
bounded compatibility lookup remains available before this new index is ready; a larger unsupported
legacy dataset fails closed instead of claiming index completeness.

The existing identity migration normalizes aliases, validates canonical accounts, classifies
provenance, and materializes account aliases. Pending migration reads retain bounded compatibility
for corroborated historical account arrays and mixed-case aliases. They reject conflicting owners,
canonical shadowing, and oversized compatibility scans. Unproven global alias rows cannot grant
access. A historical v2 readiness marker does not satisfy the v3 identity gate.

### Operator execution

The following commands mutate the selected deployment. Use them only within an approved rollout
or repair, after confirming the deployment name and current code. They are examples, not evidence
that production migrations have run. Do not add `--push` as an incidental migration step.

From the repository root, run the identity migration until it reports `status: "ready"`:

```bash
bunx convex run --deployment-name <approved-deployment> migrations:runIdentityMaterializationMigration '{"batchSize":128}'
```

Run each visibility migration until its own result reports ready. `scheduleNext: false` keeps each
operator invocation explicit:

```bash
bunx convex run --deployment-name <approved-deployment> migrations/groupVisibility:run '{"scheduleNext":false}'
bunx convex run --deployment-name <approved-deployment> migrations/userExpenseRefs:run '{"scheduleNext":false}'
```

Run the reference backfill repeatedly until `complete: true` and `phase: "ready"`:

```bash
bunx convex run --deployment-name <approved-deployment> memberReferences:backfill '{"batchSize":1}'
```

Inspect errors and progress between calls. Do not manually insert readiness rows, flip their state,
or enlarge live limits to clear a migration failure. A clean installation uses these same gates.
Verify the completed markers, capability-2 client deployment, and an authenticated staging claim
before enabling the dependent UI. Production account continuity and authentication-environment
readiness are separate release prerequisites; completing these indexes does not prove them.

## Operation execution and recovery

[`identityOperations.ts`](../../apps/backend/convex/identityOperations.ts) stores the actor and
creator accounts, bound token/request/friend, selected source, source closure, target identity,
generation, cutoff, phase, member position, cursor, attempts, and error. Consent, alias/friend
changes, operation records, capability markers, and initial scheduling commit atomically.

Operation member markers also carry an indexed active barrier. Global markers fence every affected
record, including third-party owners; local markers apply only within their owner scope. Public
reads and mutation projections check raw members and owner-local targets before resolving aliases.
Older completed markers cannot hide a later pending operation. Successful completion or fully
reconciled revocation retires at most 257 markers atomically; recoverable failures remain fenced.
Expense reconciliation explicitly bumps retained viewers' revisions even when visibility is
unchanged, so a pre-claim pagination cursor cannot publish the new identity map after completion.

Pre-index markers remain readable through a bounded compatibility check against live operation
state. More than 32 unresolved-format markers for one member/scope fail closed. The internal
`identityOperations:backfillMemberBarriers` mutation processes at most eight markers per call; pass
its returned `continueCursor` as the next `cursor` until `isDone`. It derives each marker's active
state from the operation and does not change financial data. Run this maintenance only on an
explicitly selected, approved deployment; never clear the barriers by hand.

A worker processes `groups`, then `expenses`. A global claim then discovers owner-local
dependencies through `owner_member_aliases` indexed by target: for example, C's local X pointing to
the globally claimed Y. The `owner_aliases` phase validates the live friend and owner-local map,
then stages immutable `identity_operation_dependents` rows. The `dependent_reset` phase resets one
retained item per step using stable operation/creation-order pagination. `dependent_references`
reconciles each raw member only within its recorded owner scope and marks its work complete.
Completed items remain until the operation becomes terminal, so revocation or a failed resume can
replay already granted visibility even if the live reverse alias disappears. Retained owner/member
work also fences reads until the operation finishes. Scheduled terminal completion starts
`cleanupDependents`, which removes at most eight metadata rows per call and refuses nonterminal
operations. Manually stepping with scheduling disabled leaves this harmless metadata for an
explicit cleanup call. No dependent raw member becomes a global alias. Active barriers
remain until this work and any child operation finish. Discovery is limited to one alias candidate
per step with 2,048-query/row and 4 MiB read budgets.

Each reference step selects at most one candidate and rereads the source. It checks live provenance, owner consistency,
participants, suppression, and deletion state before reconciling derived visibility. Foreign-owned
financial content stays unchanged. Completion bumps affected revisions and waits for dependent
local operations.

The cutoff includes reference and owner-local alias rows that existed when the operation began,
including fractional creation timestamps. Indexed `_creationTime` bounds exclude newer references from the drain.
Concurrent canonical writes maintain their current references and visibility synchronously, so
new records need no extra worker pass. Deleted or replaced candidates cannot authorize access or
restore source records.

Successful cursor progress schedules its continuation in the same mutation. The action wrapper
records a failed step only after the step transaction rolls back. Retries use bounded backoff and
stop after five consecutive failures. `resume` restarts recoverable failed work and its dependency
chain without inventing a completed result. A worker's stored generation is distinct from the
client snapshot generation, which combines account update state and financial revisions.

If provenance is revoked or account deletion wins, the worker starts a removal reconciliation.
After the affected work drains, it records `terminal_reconciled: true` with a failed revoked outcome
and releases snapshot blocking. A stale derived visibility row still cannot grant access because
queries check current authorization. Permanent expense suppression from Clear All wins over job
retries, new links, settlement updates, and ordinary import.

The reference and reconciliation helpers retain hard row, byte, query, and write bounds. V3 handles
long histories by splitting transactions, not by increasing those bounds. One oversized entity or
invalid ownership record can still require maintenance. Capture the operation ID, phase, cursor,
attempt count, and error before investigating; do not delete the job or its capability markers.

Legacy synchronous claims reject live foreign owner-local reverse dependencies that are not
already covered by their explicit owner-local source plan, before consent or alias writes. They
require V3 for that shape. Supported atomic claims bump retained expense viewers' revisions as
well as group revisions, preventing old pagination cursors from publishing a new identity map.

Legacy synchronous claims preflight the complete affected set and shared budgets before consent
writes. They currently allow at most eight relevant groups and eight expenses, with at most 64 raw
member IDs per entity in that preflight. Before reference readiness, a complete bounded fallback
is possible only for a tiny source dataset. Larger work requires migration and V3. Any failure
rolls back consent and financial changes; no partial legacy success is returned.

## Client publication and compatibility

`accounts.required_financial_contract` only increases. Currency-aware writes and V3 identity work
raise the affected viewers' floor to 2. Source/target operation markers close the interval before a
worker reaches foreign viewers. Owner-scoped marker indexes avoid reading another owner's local
merge history to decide the caller's capability requirement.

Capability and pending checks apply to financial reads/writes and alias-bearing identity responses,
including viewer, friends, directory resolution, and group enrichment. Handle
`FINANCIAL_CONTRACT_UPGRADE_REQUIRED`, `IDENTITY_OPERATION_PENDING`, and `FRIEND_DELETION_PENDING`
as explicit upgrade or processing states. They are not authentication failures or evidence that an
endpoint is missing. Never retry an unsafe legacy endpoint in response to one of these errors.

The iOS flow stores the pending operation ID per account and resumes after relaunch. It keeps the
last complete identity and financial snapshot while processing. Full hydration reads
`identityOperations:snapshotGeneration` before and after fetching account, friends, groups, and
expenses; mismatched generations must not publish. Realtime friend or account updates cannot
advance alias equivalence over older cached financial rows. Every async completion remains bound
to its captured session and data epoch.

Group read responses include a derived `member_identity_map` from each normalized raw member ID
to its live resolved ID under the group owner's identity scope. `expenses:createV2` includes the
same map on its returned group. The map is response-only; group mutations and imports do not
accept it as identity authority. Add Expense builds a transient canonical, deduplicated participant
list from that snapshot while preserving stored group members and historical expense rows.

Group projection shares owner and member caches across the whole response and limits actual reads
to 2,048 queries, 2,048 rows, and 8 MiB. `groups:listV2` pages contain at most eight candidates. A
`GROUP_PROJECTION_PAGE_TOO_LARGE` error makes the iOS reader retry the same cursor and expected
revision with half the page size, down to one. It retains the smaller size for later pages and
revision restarts. A page of one that still exceeds the budget requires maintenance. Tests cover
eight groups sharing 64 identities within budget, and eight disjoint 64-person groups retrying at
two per page without gaps or duplicates. Capability, pending, and authorization errors must never
trigger this retry or a legacy fallback.

The complete-list compatibility endpoints `groups:list` and `groups:listPaginated` examine at most
64 source groups, including unrelated groups, with a 4 MiB source-scan budget. A source dataset
that exceeds either bound fails explicitly and requires modern indexed pagination. They never
return a silently truncated complete list. Within that
bound, `listPaginated` honors its numeric offset cursor and page limit. `listLegacyPage` remains a
bounded compatibility scan. This limit is a compatibility restriction, not a limit on the total
number of groups available through `listV2`.

Friend deletion also fences records owned by the changing account before an affected group or
expense can be filtered out of a viewer's response. Preserved shared records reconcile visibility
and revisions before the fence releases. Older unfinished deletion jobs restart bounded preflight
when their `identity_projection_version` is missing, retaining their destructive-phase marker so
cancellation cannot undo already applied work.

After completion, refresh the complete snapshot. A revoked terminal result refreshes safe current
data and reports the revocation, not linking success. A nonterminal failure retains recovery
information. Never perform financial rewrite writeback as a side effect of receiving the V3 result.

Future clients must implement all-row alias selectors, currency separation, coordinated snapshots,
and operation recovery before advertising capability 2. Optional schema fields alone do not make
an old client safe. `LINKING_CONTRACT_VERSION = 2` in `identity.ts` still describes the legacy payload;
it does not describe the identity-neutral V3 operation result.

## Restored history and reconciliation

`bulkImport.history_manifest` binds each declaration to one expense client ID and group client ID
in that request. Its member set must exactly match the expense's validated raw financial IDs. It
permits private historical storage outside the current roster; it establishes no membership,
friendship, alias, or viewer grant. The server validates the complete chunk before writing anything.
Malformed declarations roll back that chunk. Completed earlier chunks remain committed.
Every new financial restore, including group-free individual history, raises capability floors for
its owner and eligible viewers through the canonical write budget. Independently, stored expenses
with duplicate normalized split member IDs require capability 2 even when older data has no floor
or restore metadata. Legacy linking rejects affected duplicate-row history before rewriting it;
modern reads preserve every split ID and settlement flag.

Every newly restored group or direct expense stores `has_restored_history`, the complete
`restored_historical_member_ids`, and server-captured `restored_history_context_member_ids`.
These optional fields leave older documents compatible. Only validated restore can introduce them;
ordinary edits cannot replace or clear them. The context IDs enter `member_references` solely for
reconciliation discovery. Cleanup must use financial IDs when deciding whose history to remove.
The group roster still has the ordinary 64-member limit.

A restored financial identity can contribute a viewer only when its live expense-owner identity
matches the current group's live owner-scoped membership. Direct history also requires the eligible
confirmed relationship and exact pair. An imported canonical ID or manifest alone never proves
consent. Suppression and inactive-participant exclusions still apply. Restore omits authoritative
inactive parties from new live group rosters and scrubs their participant display metadata, while
preserving their raw amounts, split IDs, currency, and settlement flags.

A roster change with restricted history starts a `group_history_reconciliations` generation in the
same transaction and sets `groups.history_reconciliation_id`. Reads and participant mutations
reject before filtering until that generation completes. Further roster changes wait; a name-only
edit may proceed. The worker scans `expenses.by_group_ref_restore_history`, prepares a whole page
through canonical write budgets, and applies only derived visibility/revision changes. Page sizes
start at 8 and reduce to 4, 2, then 1 after a typed budget failure rolls back the attempted mutation.
The saved cursor advances only after success. The page budget remains 2,048 queries, 2,048 read
rows, 4 MiB read bytes, 2,048 writes, and 8 MiB write bytes. A supported single record can contain
65 financial identities and a separate 64-member current context; the canonical preparation shares
its transaction-local identity cache and resolves eligibility once. An unsupported single record
produces a recoverable maintenance failure rather than being skipped. Cursor, page-size, and generation checks reject
stale standalone failure reports; identity-worker `progress_version` also rejects stale steps and
failure reports after a newer checkpoint.

Link workers discover both consented sources and target identities, plus original context references
and live owner-local reverse dependencies. Discovery IDs do not expand the consented alias closure.
When a discovered current group has restricted history, the identity worker persists an inline
history cursor and drains all its restricted expenses, including expenses owned by another account,
before advancing the group reference or retiring its identity barriers. This handles a member added
to the group after restoration. A link may withdraw an old viewer as well as add a new one: verify
stored `user_expenses` rows and both viewers' revisions, not only filtered query results.
Legacy synchronous linking rejects affected restricted history before consent or financial writes;
use V3 for that case.

Confirmed-friend changes schedule indexed `friend_history` identity operations only when relevant
restricted expense references exist. These operations use existing identity status/resume recovery.
They reconcile direct history and do not establish alias authority. A derived friend-history worker
may finish under an already-authorized deletion of another friend owned by the same account; the
friend-deletion fence continues to block public reads and its later cleanup reconciles final consent.
Real claim and local-merge operations retain their separate barriers.

Account deletion selects a financial steward under the original expense/group owner scopes, with
suppression and live eligibility rechecked. A hidden historical participant is not a steward. Once
an account has crossed its deletion fence, its exact persisted owned expense may be inspected even
if a different group's owner started a history refresh; that refresh waits for deletion. This
exception is tied to the persisted expense and deletion request. Active preflight before the deletion
fence cannot borrow it. Group ownership transfer/deletion cancels the obsolete job generation;
terminal records are removed in bounded cleanup.

History recovery is available independently of blocked financial hydration:

- `groupHistory:pending` uses `paginationOpts`, capability 2, and `expected_account_id`.
- `groupHistory:status` and `resume` use `job_id`, the same actor/capability fields, and optional
  `visible_expense_id` containing the expense's client UUID.
- Results contain `job_id`, `group_id`, `phase`, `retryable`, and optional `error_code`.
  Errors use `HISTORY_RECONCILIATION_PENDING` or `HISTORY_RECONCILIATION_FAILED`; identifiers are
  included only when the caller has verified recovery access.

Recovery validates the current job generation and source owner or eligible caller-visible financial
record. Its internal scope can share an actually overlapping identity generation; it cannot bypass
an unrelated identity operation. After recovery, fetch a fresh coordinated snapshot. Do not retain
an old identity map or publication cursor across the generation change.

Before rollout, verify the existing member-reference and visibility readiness prerequisites above,
deploy the optional schema/indexes and canonical writers together, and retain the new workers and
recovery endpoints during any rollback. This runbook authorizes no production mutation or migration.

## Diagnostics

| Symptom                                          | Checks                                                                                                                                                                                                         |
| ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Linking remains in processing                    | Read authenticated `identityOperations:pending` or `status`; inspect phase, cursor, dependencies, attempts, and error. Resume recoverable work. Check deletion or revoked provenance before changing anything. |
| New claim rejects readiness                      | Inspect all four markers. Check source ownership conflicts and the friends phase. Do not fabricate readiness.                                                                                                  |
| Shared history is absent after a completed claim | Check raw member references, current global or owner-local provenance, inactive participant IDs, permanent suppression, and derived visibility. Confirm the client published a matching snapshot generation.   |
| A split appears paid or unpaid incorrectly       | Inspect every equivalent raw split and its original amount/flag. Check currency. V3 intentionally leaves IDs and rows intact; a missing physical rewrite is expected.                                          |
| A duplicate invitation cannot be shared          | Use `createV2` and the returned canonical token `id`. The legacy document-ID endpoint has different duplicate behavior.                                                                                        |
| An old client cannot read after linking          | Inspect its financial capability and the account floor. The upgrade gate is deliberate; do not lower the floor.                                                                                                |
| A local merge changes access unexpectedly        | Resolve local aliases using the financial record's owner. Inspect the index's bound friend and current proof, not its candidate row alone.                                                                     |

Read-only internal lookup examples require operator access and an explicitly selected deployment:

```bash
bunx convex run --deployment-name <approved-deployment> aliases:resolveCanonicalMemberId '{"memberId":"<member-id>"}'
bunx convex run --deployment-name <approved-deployment> aliases:getAliasesForMember '{"canonicalMemberId":"<canonical-id>"}'
```

Public viewer/status queries require the affected authenticated actor. Use the app or an approved
identity-bound diagnostic session; CLI administrator access alone does not supply that identity.
Do not invoke generic debug mutations to inspect production data.

## Rollback and verification

A rollback must preserve aliases, financial rows, suppression records, capability floors, reference
indexes, and operation records. Disable new entry points through a reviewed code/configuration
change if necessary, while retaining upgraded authorization and a path to resume outstanding work.
Do not remove readiness gates, lower capability floors, or deploy the old bootstrap and financial
rewrite behavior over V3 data.

Focused executable coverage lives in:

- [`history_identity_foundations.test.ts`](../../apps/backend/convex/tests/history_identity_foundations.test.ts)
- [`restored_history_linking.test.ts`](../../apps/backend/convex/tests/restored_history_linking.test.ts)
- [`group_history_worker.test.ts`](../../apps/backend/convex/tests/group_history_worker.test.ts)
- [`identity_operation_foundations.test.ts`](../../apps/backend/convex/tests/identity_operation_foundations.test.ts)
- [`global_identity_pending.test.ts`](../../apps/backend/convex/tests/global_identity_pending.test.ts)
- [`linking_stability_v3.test.ts`](../../apps/backend/convex/tests/linking_stability_v3.test.ts)
- [`linking_stability_foreign_legacy.test.ts`](../../apps/backend/convex/tests/linking_stability_foreign_legacy.test.ts)
- [`identity_readiness_gates.test.ts`](../../apps/backend/convex/tests/identity_readiness_gates.test.ts)
- [`group_visibility_writes.test.ts`](../../apps/backend/convex/tests/group_visibility_writes.test.ts)
- [`group_identity_lifecycle.test.ts`](../../apps/backend/convex/tests/group_identity_lifecycle.test.ts)
- [`group_member_projection.test.ts`](../../apps/backend/convex/tests/group_member_projection.test.ts)
- [`friend_deletion_generation.test.ts`](../../apps/backend/convex/tests/friend_deletion_generation.test.ts)

Run owning suites and repository checks for a code change. AppStore/service changes also require
the repository's iOS parity and sanitizer gates. The [before/after case record](../reviews/payback-stability/BEFORE_AFTER.md)
distinguishes automated results from source traces and operational prerequisites. Local tests do not
establish production migration completeness or live authentication continuity.
