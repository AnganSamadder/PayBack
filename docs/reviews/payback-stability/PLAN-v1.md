# PayBack stability repair plan

Status: draft v1, awaiting independent review. No production implementation begins until approved.
Baseline: commit `4fa2bedecaf14c1079a4eef631c4842557036c6a`; 29 grouped findings and 152 scenario classes in `baseline.json`.

## Safety facts and scope

1. Neither linking nor cleanup may change historical total liability or revive/forgive settled debt. Canonical account IDs remain immutable; only consent-bound server operations establish global alias provenance. Owner-local merges cannot alter another owner's financial content.
2. Every async mutation stays bound to its starting actor. New storage/wire fields are optional on existing documents, validators and Swift DTOs evolve together, and old-client writes cannot erase server-owned identity, revocation, currency or completion state.

Implement all code-remediable findings F01–F29, including supporting compatibility and tests. Do not invent a historical currency, rotate live Clerk identity infrastructure, repair production records, or flip migration readiness markers. External operational requirements must be explicitly tracked rather than labeled fixed. This PR can prepare production auth configuration and enforce release readiness; actual provider setup/account continuity requires operator action and must not silently strand current accounts.

## Implementation sequence

### 1. Lock behavior with regressions and track every case

Promote the archived 36 backend cases and four iOS regressions into maintainable owning tests, converting characterization assertions to intended outcomes. Preserve failing-before evidence. Bring import/export harness cases into executable owning tests. Copy every baseline scenario into a before/after manifest with a test/source reference, result and any operational dependency; do not mark source-only cases as runtime-tested. Keep unaffected passing guards.

### 2. Identity, provenance and financial-history preservation (F02–F05, F10, F24)

- Remove normal hydration/import/name-only identity inference. Use authenticated canonical/alias equivalence; preserve distinct same-name UUIDs. Manual add reuses a historical identity only when truly unambiguous before display projection, otherwise creates a distinct candidate or requires selection.
- Preserve separate settled and unpaid splits when their member IDs consolidate. The existing expense shape supports multiple split rows per member and settlement summaries already aggregate them: coalesce by `(member_id, is_settled)` (stable split IDs), not member alone. Validate every serializer, selector, settlement writer and group/expense participant set against this representation. If a path cannot safely support mixed states, reject that path atomically before mutation rather than modify the money.
- Legacy accounts missing member_id receive a new server-generated canonical UUID. Client bootstrap cannot adopt arbitrary placeholder IDs. Historical identity attachment always requires consent-bound claim core.
- A trusted global alias must reconcile group and expense visibility for affected shared/foreign-owned history without rewriting foreign financial content. Introduce an indexed member-reference surface if existing indexes cannot find affected records. Backfill it through bounded, resumable jobs; maintain it through canonical write helpers. Claim success and old-client behavior must not report a finished link whose required financial visibility is permanently missing. Use explicit pending/readiness state if materialization cannot complete atomically; test retries, deletion fences, revision bumps and revocation during pending work.

### 3. Request and invitation lifecycle (F01, F14–F15, F23, F26–F27)

- Fresh signup preserves live, unexpired incoming email requests bound to a valid active requester and owned target, across both cleanup paths. Deleted-account artifacts still clean up safely.
- Decline/cancel only act on pending requests. Accepted evidence remains durable. Repeating legacy send preserves confirmed status.
- Invite creation recovers an existing active token for the same owned unlinked friend. Client builds its URL from the returned canonical token ID. Different payload/owner collisions still reject; explicit revoke remains owner-only.
- Add optional owner-validated merge selection to email acceptance, atomically matching invite claim semantics. iOS offers the selection before accept; no name-based automatic merge. Retry selection is stable.
- Friend-add UI updates confirmed state only after persistence succeeds. Failed request creation may retain an already persisted manual friend; failed friend persistence may not.
- Use paginated incoming/outgoing request APIs in iOS; keep compatibility endpoints for old clients. Preview must not present inaccessible pre-link history as a proven zero balance.

### 4. Expense authorization, money and direct ledgers (F06–F07, F20–F22, F28–F29)

- One canonical validation path for all expense contexts and updates: finite valid money, payer in involved identities, consistent participant/split sets, allowed identities from current group or confirmed direct/grouped-individual friends. Derive linked accounts/emails from trusted member/link provenance, never arbitrary input email. Preserve narrow historical owner edits with unchanged identities after friendship removal.
- Self derives from authenticated canonical equivalence, never persisted creator-relative is_current_user. Require confirmed friend for every genuinely new direct expense in both directions.
- Transactionally select/reuse a ledger by canonical identity pair, not draft UUID. Return actual persisted group ID and reconcile iOS drafts; handle alias transitions and legacy duplicate ledgers deterministically without deleting financial records. Concurrent first writes must converge.
- Extract production minor-unit split allocation shared by equal/percent/shares/manual/itemized modes; deterministic remainder distribution, nonnegative finite amounts, exact total conservation at supported precision. Adjustments must be offset/rebalanced or rejected before save and by server validators. Existing legacy fractional values stay readable; notes-only edits do not gratuitously rewrite historical money.
- Currency contract: add optional persisted ISO currency metadata for new writes and round-trip it through Swift/Convex/import/export. New expenses use an explicit product settlement currency; remove unsupported crypto and misleading unpersisted conversion UI. Never silently assign missing historical denomination. Display legacy missing currency explicitly; do not combine different/unknown denominations as if equivalent. Implement per-currency balance/settlement selection or constrain creation to the explicit supported currency while keeping legacy values inspectable. Reviewers must resolve the smallest complete UI/storage option before implementation; hiding the picker alone is insufficient.

### 5. Actor fencing and acknowledged lifecycle results (F08–F09, F17–F19)

- Make reconciliation always capture account ID/data epoch and check after each await. Friend-sync and bulk-import chunks carry expected actor to server validation and stop on cancellation/session changes. Mocks must model current-auth behavior rather than mask races with input email partitioning.
- Persist shared-expense per-account suppression/revocation for Clear All. Reconciliation honors it after settlement, migration, linking and retries. New explicitly created/shared records may remain visible; old cleared records do not resurrect. Preserve other viewers' history.
- Linked-friend deletion handles current server state atomically or returns an enforced typed failure. iOS only retains deletion tombstones after acknowledged success.
- Replace scans of all unrelated owner expenses during friend deletion with targeted indexes and bounded resumable work; test unused-friend deletion after 513 unrelated expenses.

### 6. Bounded long-history linking/merge (F16)

- Charge actual indexed identity work rather than 80 worst-case lookups per distinct person; keep hard query/row/byte/write safety limits.
- Provide resumable work for history beyond one transaction. Prefer alias/reference reconciliation where financial data need not be rewritten; any staged local rewrite has durable job cursor, owner/entity generation, deletion fencing, idempotent batches, stable identity semantics during progress and a completion/readiness contract. Do not just raise constants or run unbounded loops. Test 65+ expenses, 12-person history, dense aliases, failure/resume and writes racing the operation.
- Keep the existing atomic small-case path if useful; preflight every destructive batch before applying it. If a larger architecture is needed, settle its exact contract with reviewers before coding.

### 7. Lossless backup and release readiness (F11–F13, F25)

- Version portable export while preserving legacy reads. Parse logical CSV records including quoted newlines; preserve source UUIDs, contextKind, notes, currency, splits and settlement flags. Grouped-individual import has no fake group requirement. Only explicit friend records create confirmed friends. Production/CI paths share the same transformations; tests hit the real payload boundary.
- Configure Clerk key/issuer by build/deployment environment using project.yml and backend env configuration. Add validation that rejects mismatched production/development settings at release readiness rather than silently switching existing users. Retain documented development setup. No credentials in commits. Provide an operator runbook for production Clerk setup, supported account continuity, backend-first deployment, migrations and rollback; test code-level selection/validation. Unknown live production credentials are an explicit operational prerequisite, not fabricated values.

## Delegation and integration

Three GPT-6.1 Sol plan reviewers evaluate the entire plan independently, with identity/security, financial/compatibility, and lifecycle/integration emphasis. Gemini 3.8 Flash High is the adversarial jester: look for counterexamples, but unsupported suggestions do not outweigh executable evidence. All reviewers must explicitly approve the same revision or provide actionable objections. Each round retains prior objections and responses. Do not solicit rubber-stamp approvals; unresolved supported objections block implementation.

After plan approval, assign separate ownership for backend identity/linking, backend expenses/visibility/cleanup, iOS state/UI/adapters, money/currency cross-layer contract, and backup/configuration/tests. Shared schema/helpers require a single integrator or explicit ownership coordination. Use worktree isolation for independent risky edits when needed, or disjoint file ownership in this already isolated checkout. Do not overwrite other agents' changes. Parent integrates and runs full checks. Review the assembled diff with at least three independent Sol code reviewers and a Gemini challenge pass; fix supported issues and repeat fresh review rounds until approval with no unresolved actionable findings.

## Verification and delivery gates

- Focused regressions fail before and pass after; success, rollback, unauthorized cross-account and old-record cases for each boundary. Preserve original positive guards and avoid assertions that merely mirror implementation.
- Backend owning suites, fresh lint/typecheck, format and `bun run ci` pass.
- Canonical iOS parity plus TSan and ASan for changed AppStore/services/concurrency; one dedicated simulator/stable DerivedData. Use build-for-testing/test-without-building selectors where practical. Do not erase shared caches or kill unrelated processes. Record any environment blocker exactly; do not claim completion over failing required gates.
- Web smoke passes if affected configuration/delivery changes touch it. Regenerate Xcode only through project.yml/xcodegen; exclude unrelated generated churn.
- Maintain all 152 before/after scenario rows and an F01–F29 disposition table. Clearly distinguish fixed/tested, preserved guard, source trace, pending deployment prerequisite and unverified integration.
- Commit reviewable behavioral units with Conventional Commit subjects. Push the feature branch and create one PR (explicitly authorized by user), without merging or deploying. Register the PR with this T3 thread immediately. PR includes concrete behavior changes, full before/after case artifact, reviewer rounds/approvals, exact validation and rollout/rollback/operational requirements. Recheck linked PRs before handoff.
