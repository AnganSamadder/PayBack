# Historical restore contract addendum

Status: design candidate v1; frozen for three independent Sol reviews before production changes.
Scope: repair the proven canonical-expense/raw-group restore failure and the 64-member export boundary without expanding group membership limits or importing identity authority.

## Decision and boundary

Keep the current group roster unchanged and bounded to 64 members. Remove portable roster expansion. Keep every expense's original group/context, payer, participant IDs and names, split IDs, amounts, currency, subexpenses, notes, and settlement flags. Existing financial validation and per-expense participant limits remain unchanged.

An authenticated owner may restore a historical financial row into their own group even when a participant is absent from its current roster, provided that exact row declares the historical identities in the same import request. **Storing that owner's private history does not authorize sharing it with the account named by a raw ID.** Every raw financial participant of every newly restored GROUP/DIRECT expense remains subject to a persisted sharing restriction, including participants currently in the group. This is a deliberate restored-history privacy rule, not selective compatibility: later membership or identity removal can withdraw sharing while the owner's data stays intact. Grouped-individual history retains its existing rules. The manifest cannot create group membership, a friendship, a global/local alias, a direct-ledger pair, or a trusted linked-account field.

This replaces both rejected alternatives: a 128-member roster is not closed under repeated linking/export cycles; a permanent group-wide restore exemption would authorize unrelated later rows. No durable restore operation or transferable restore token is introduced.

## Wire contract and exact binding

Add optional `history_manifest` to `bulkImport` alongside its existing actor/capability arguments:

```ts
history_manifest?: Array<{
  expense_id: string;
  group_id: string;
  historical_member_ids: string[];
}>;
```

Each entry binds only to one expense in this invocation's `expenses` array. IDs use the existing member-UUID normalization rules; expense/group client IDs keep their existing identifier rules.

Before any writes, validate:

1. The authenticated actor matches `expected_account_id`/email and passes capability, pending-identity, and deletion fences. A manifest requires financial capability 2.
2. Expense IDs, manifest expense IDs, and each manifest's normalized member IDs are unique. Reject dangling entries, repeated entries, group-ID mismatches, empty declarations, and declarations that differ from that expense's complete validated raw financial participant set. The declared set must equal the normalized union of payer/involved/split IDs; validated participant ID/object sets must already agree with it.
3. Every referenced group is either created by this request for the actor or already consistently owned by the actor. Caller visibility alone is insufficient. Reject foreign ownership, conflicting owner tuples, deleting groups, and pending group-history reconciliation. Incoming group records never update an existing group's roster or ownership.
4. Validate the historical money and matching payer/involved/split/participant sets before applying the exception. A manifest cannot repair mismatched sets or authorize fabricated/coalesced financial rows.
5. Compute the expense participants authorized by the live stored group owner's identity scope, as in the repaired ordinary restore path. With a valid complete declaration, an outside participant may be stored as private history, subject to the persisted rule below. Without a declaration, every participant must pass the existing live membership check. A declaration cannot expand active sharing.

No manifest means the existing live-owner-equivalence membership rule applies. A successful group-backed restore still stores the full participant restriction server-side; no-manifest compatibility does not bypass the restored-history privacy rule. The manifest is required only to authorize private storage of outside-context historical rows. A grouped-individual expense remains on its existing group-free restore path; reject a manifest for it. This addendum does not relax its confirmed-participant rules.

A later request has no permission inherited from an earlier manifest. It must bind its own declaration to its own newly restored rows. This is safe without a durable restore table because the exception only permits private storage of a precisely declared row, not access to another account or a current group-member capability. Persisted per-expense restrictions, rather than a reusable group exemption, enforce that distinction after the request ends.

## Persisted restriction and sharing authority

Add optional server-owned fields to expenses:

```ts
restored_historical_member_ids?: string[];
restored_history_context_member_ids?: string[];
has_restored_history?: true;
```

Only validated bulk import can introduce these fields. Store the full normalized raw financial participant set for every newly restored GROUP/DIRECT expense, with or without a manifest. Ordinary authoring, metadata updates, settlement, legacy writers, retries, and client DTOs cannot introduce, replace, or clear it. The server also captures the actual stored group's original raw member IDs in `restored_history_context_member_ids` (at most 64); the client does not supply these as alias assertions. They are dependency metadata only, not payer/split/participant/viewer identities. `has_restored_history: true` is an index discriminator, not authorization. Absence retains existing document behavior.

Member references for a restricted expense include its original financial IDs plus these context dependency IDs. This lets an accepted link of current raw context X discover historical canonical B rows even when X does not occur in their financial fields. Context references must never enter financial math, participant arrays, viewer enumeration, self classification, or destructive cleanup's financial-participant matching. Existing reference bounds (1024/entity) cover at most 129 distinct financial/context IDs; their actual read/write cost remains charged.

For each declared ID, decide active sharing from current server truth:

- Derive that financial ID in the **expense owner's** live identity scope.
- Derive current group-member IDs in the **group owner's** live identity scope.
- Allow that historical identity to contribute a viewer or participant mutation authority only when those derived identities match. Direct canonical IDs alone, imported linked metadata, names, a manifest, and a manual friendship do not satisfy this test.
- Inactive identities, deleting/deleted accounts, pending identity generations, and account/expense-client-ID suppression still exclude access. The authenticated expense owner always retains their own private history, subject to account deletion and their own clear/delete actions.

An accepted link that makes current group placeholder X equivalent to historical B can therefore activate B. A participant genuinely removed from the current group needs an authorized membership change; adding a friend alone does not reshare removed group history. If expense and group ownership later differ, their local alias scopes remain separate: a foreign owner's local alias cannot silently redefine the expense's financial identity. Global equivalence or independently consistent owner scopes can still establish the match.

Apply this rule to all visibility reconciliation, public reads before filtering, settlement, and non-owner metadata/delete authorization. Hidden historical payer IDs must not retain a delete or settlement side channel. The response financial map remains derived advice, never write authority; it preserves the expense-owner scope and original rows. Owners may still view amounts assigned to a historical person who currently receives no shared expense.

The canonical write helper must enforce this filter even when an import/legacy caller supplies explicit viewer IDs. Final durable suppression filtering runs after all candidate eligibility checks. Neither membership changes nor relinking remove suppression records.

## Reconciliation and snapshot generations

Do not scan unrelated account history. Reuse `member_references` for accepted global/local linking and the existing indexed owner-local dependencies. Declared historical IDs and the server-captured original context dependency IDs remain in the expense references. Link workers reconcile affected expenses with `forceRevision: true`, including owners and viewers whose membership did not change. Existing raw-member, local-target, and owner pending barriers block snapshots until the relevant operation completes.

Group membership can change eligibility without a link operation. Add a bounded group-history reconciliation path:

- Index declared-history expenses by `group_ref` plus a server-maintained `has_restored_history` boolean, set and preserved with the declaration. The boolean is an index discriminator, not authorization.
- A successful membership change checks that index and atomically starts a new generation when affected history exists. Use `group_history_reconciliations` records with `group_ref`, `owner_id`, `generation`, optional `cursor`, `phase: pending | failed | complete`, `attempts`, optional `error`, and timestamps; index by group and phase. Store the active job ID on the group. This is reconciliation state, not a restore grant. Schedule the first page in the same transaction. Only one active job is allowed per group; completion clears its pointer atomically with the final revision bump.
- Process one bounded indexed page at a time (initial maximum 8 expenses, with existing aggregate budget checks), resolve live eligibility, and use canonical visibility writes with forced prior/current-viewer revisions. Limit each transaction by the existing query/row/byte/write budgets; use the canonical prepared-write path. Persist the cursor only with the successful page. Retries are idempotent; stale generations cannot publish completion.
- Fence reads and participant mutations for affected group history before authorization/filtering while its generation is pending or failed. Serialize further group membership changes against that generation; metadata-only group edits may proceed without changing its membership snapshot. Reject imports/authoring into the pending group with a recoverable reconciliation error.
- Bump group revision when scheduling and when completing so clients retry the authoritative snapshot. The expense worker bumps all affected expense-viewer revisions. A continuation from before the change must fail its expected-revision check after completion, including when access remained unchanged.
- Group deletion/account cleanup cancels or supersedes the job and removes its records through the existing bounded lifecycle. Workers recheck group existence/deletion/ownership generation before writes. A failed job remains fenced and retryable; do not publish partially reconciled pages.

Current-group relinking can affect a historical canonical B even when the financial rows reference B but not group placeholder X. The captured context member references cover original X. Acceptance workers must include both source and target identities and their owner-local dependent references, then run the same sharing filter. If a link changes a current group identity added after the restore snapshot, discovery of that group must also enqueue or process its indexed restricted-history reconciliation; the fixed original context list is not sufficient alone. Tests must prove the actual reference discovery, not only a direct helper call.

## Export, chunks, retries, and compatibility

No new CSV section is required. Preserve the original group/member section. For every GROUP/DIRECT expense in a network chunk, the production request builder declares its complete raw financial participant set, even when all participants currently belong to the exported group. Emit exactly one manifest entry per such expense. Grouped-individual expenses emit none. Compute declarations after the existing explicit ID remapping step, from payer/involved/split IDs only; descriptive-name keys are never financial participants. A missing source group is an explicit conversion error, not an empty roster to infer against. It retains the complete parsed group metadata while converting later chunks, even though those chunks omit already-sent group writes. Reconstructing a later `BulkImportRequest` must copy that chunk's `history_manifest`, and the real Convex adapter forwards it unchanged. No derived identity maps or trusted links are exported. Repeated export/clear/restore keeps the roster at 64 and keeps all raw financial identities; it cannot accumulate canonical roster additions.

When restoring into an existing owned group whose live membership changed since export, a valid complete declaration preserves the row privately; current eligibility alone controls sharing. An old/no-manifest request with an outsider still receives an explicit row error. Import never changes the existing group to make a row fit. Since every backed restore stores the same complete restriction, later membership changes and repeated export/clear/restore cannot accidentally remove a previous restriction.

Idempotent retries of an already-owned expense do not overwrite financial fields, declarations, or visibility. Reject duplicate IDs within a chunk. A foreign-owned expense ID aborts the transaction as today. A new payload reusing an existing owned ID is reported as already present, not as an applied edit; no manifest can alter that existing row. Actor/session changes stop subsequent chunks, and cancellation does not turn a partial restore into reported complete success.

Old clients omit the new argument and retain ordinary safe membership validation. New clients send the optional manifest to the updated backend; validator errors must not trigger fallback that drops it. Any stored declaration raises the existing financial capability floor for owner and eligible viewers, including nil-currency history. New fields are optional for existing documents. Responses need not expose the server-owned restriction because the backup builder reconstructs complete declarations from original financial rows; DTO decoders tolerate the additive fields.

Direct history keeps its original `is_direct` group flag and original raw roster. A manifest is never evidence of friendship or a two-person pair. New direct authoring still requires a confirmed friend and exactly two live equivalent people. Reuse after relinking follows the existing canonical-pair resolver; restore itself neither creates nor rewrites pair mappings.

## Bounds, cleanup, and implementation owners

Use the existing 512-expense request ceiling and 65-identity expense ceiling. Manifest entries cannot outnumber request expenses; each declaration cannot exceed its expense's validated unique financial set. Reject over-budget payloads before writes. Count manifest bytes, group reads, live identity/eligibility queries, reconciliation lookups, reference writes, capability floors, fanout writes, and revision writes in the existing aggregate import/preflight budgets. Cache group/owner identity work across the chunk; do not add an unaccounted full group or friend scan. Group roster/viewer bounds remain 64/65; per-expense viewer bounds stay unchanged.

Deleting an expense deletes its restrictions with the record and removes member references normally. Clear-all suppression remains keyed to the original expense client ID. Account deletion preserves the distinction between financial references and dependency-only context references: use references to discover candidates, then confirm an actual financial identity before destructive participant cleanup. Restrictions confer no extra identities and cannot suppress required privacy scrubbing. Ownership transfer recomputes eligibility from the resulting live owner scopes and preserves the restriction. Add indexed job cleanup to account/group deletion; no new 128-member cleanup allowance is needed.

- Backend expenses: manifest validation, private-history persistence, shared eligibility filter, import budgets, mutation authorization, focused lifecycle tests.
- Backend identity: optional schema fields/index, group-history generation/job, membership-change hook, link reference-discovery coverage and group/account lifecycle integration with accounts owner.
- Backup: remove roster expansion; derive exactly chunk-local declarations; wire/parser/harness and session-fence coverage.
- Parent: generated API, three design reviews, integration/full gates and PR case table.

## Required acceptance evidence

1. Actual production createV2 A/X→A/B, delete only expense, ordinary restore into still-linked owned A/X group succeeds without a manifest or roster rewrite.
2. Actual exporter/parser/request builder for a full 64-member raw group plus canonical B emits 64 group members and a bound complete financial-participant declaration; clear all three surfaces and restore succeeds with unchanged rows. Repeat twice with a later relink and no roster growth.
3. Mixed raw X and canonical B historical rows, fractional legacy amounts, zero shares, split IDs/flags, currency, names, subexpenses, notes, and direct context round-trip unchanged.
4. A guessed registered outsider declared as historical is stored only in the owner's private history. The outsider cannot list/read, settle, edit, or delete it; forged linked metadata and unrelated link operations do not activate it.
5. Dangling/duplicate/mismatched manifests, foreign group/expense IDs, undeclared outsiders, pending/deleting groups, and over-budget payloads reject without partial authority or financial writes.
6. Existing groups ignore incoming roster changes. Same-owner idempotent replay preserves its original restriction and rows. A later unmanifested row obtains no exception to live membership from prior imports; any successful backed restore still receives its own complete sharing restriction. Explicitly add then remove B between repeated backups and prove the restriction remains effective.
7. Actual accepted link X→B activates eligible history through indexed reference discovery; another owner's local merge does not. Actual group membership addition/removal reconciles history through bounded pages. Capture before/pending/after reads and reject stale revision continuations.
8. Cleared shared history stays suppressed after import replay, link, membership changes, metadata edits, settlement, and worker retries.
9. Group deletion, account deletion/ownership transfer, job retries/failure, legacy no-manifest import, and old-client capability rejection remain covered. Current group/member/viewer limits remain unchanged.
