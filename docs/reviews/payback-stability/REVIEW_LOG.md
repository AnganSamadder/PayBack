# Review log

User brief: plan all stability/linking repairs, have three GPT-6.1 Sol reviewers
and an advisory Gemini adversarial reviewer evaluate it, iterate until all approve,
then implement through subagents, repeatedly review/fix code, and open a PR with
all before/after cases. Do not merge or deploy.

## Plan round 1 — draft v1

- Sol identity/security: REQUEST CHANGES. Required a concrete indexed reference/job
  protocol and live read authorization; legacy bootstrap response reconciliation;
  currency missing-field policy; complete split/settlement compatibility.
- Sol financial/compatibility: REQUEST CHANGES. Duplicate split members unsafe for
  old clients; currency reads need capability fencing; money validator needs
  authoring/metadata/restore modes and explicit limits; backup must preserve full
  precision/zero rows and never fabricate liability; ledger reuse needs V2 response.
- Sol integration/lifecycle: REQUEST CHANGES. Required exact currency and job
  contracts; mixed-state selectors/reversal semantics; assign C148 directory
  privacy; idempotent email acceptance and bearer/email-change dispositions;
  ordered rollout/rollback; real adapter race tests and full auth environment matrix.
- Gemini 3.8 Flash High task ID:
  `node:delegated-task:command%3Amcp%3Add9e163e-799f-4796-b250-154c0a849fc2%3Adelegate-task%3Apayback-plan-gemini-r1-20261105`.
  REQUEST CHANGES on v1: mixed split compatibility, bootstrap return mismatch, persisted-ledger service response, Clear All/link precedence, import names and unresolved currency. Source-supported concerns incorporated in v2. The suggested updated-at cutoff was rejected: later modification must not resurrect a previously cleared record. Explicit stable per-record suppression wins, while newly linked never-cleared history may appear. A suggested no-op for mismatched bootstrap IDs was also rejected because old callers would continue with a wrong local ID; store assigns missing IDs before hydration, exact canonical retries are idempotent, mismatches fail safely. No approval inferred.

## Response in draft v2

- V3 identity operations preserve original financial rows using global consent or
  owner-local alias equivalence; no new duplicate-member physical representation.
  Old synchronous mixed coalescing rejects atomically. All matching row selectors,
  settlement/acknowledgement behavior are explicit.
- Chosen raw-member reference index, transactional dual-maintained writers,
  resumable backfill and readiness, stable operation/generation/cutoff/cursors,
  live revocation/suppression authorization and completed/pending endpoint contracts.
- Chosen USD new authoring, immutable optional currency, individually retained
  unknown history, per-currency known totals, single-currency batch settlement,
  capability-2 financial reads/writes, and precise validation modes/amount bound.
- Added bootstrap V2 result, createV2 persisted ledger response, lossless CSV number
  and zero-row rules, idempotent accept evidence, C148 implementation, external
  email-change and bearer policy dispositions, environment matrix and rollout.
- v1 is retained in PLAN-v1.md. No production source changes were made before
  approval. v2 still awaits all four reviews; unsupported objections will be
  challenged with evidence, not ignored or rubber-stamped.

## Plan round 2 — draft v2

Review target SHA256:
`e44d684d472397b6e835e557212de7ea44196ce9aece751880e9731ff26b06d7`.
Three fresh GPT-6.1 Sol reviewers and a fresh Gemini 3.8 Flash High task received
the original brief, all prior objections, responses and outstanding uncertainty.
Approvals pending; no production implementation authorized by the review gate yet.

Round 2 results: Sol financial APPROVE v2; Sol integration APPROVE v2; Gemini
APPROVE v2. Sol identity REQUEST CHANGES: alias-bearing account/friend responses
could update equivalence over cached financial state while expense reads were
blocked. This was the only remaining supported plan blocker.

## Response in draft v3

The capability/pending fence explicitly covers users:viewer, friends:list and
realtime/paginated identity responses, directory/group enrichment and operation
results. Current clients preserve a complete identity/financial generation;
pending/upgrade is not sign-out. Identity-neutral status bootstrap remains
available for recovery. A cached mixed-state history regression is required.
All reviewers must approve this new exact revision; earlier approvals do not count
as v3 approvals. No production source changes yet.

## Plan round 3 — draft v3

Review target SHA256:
`63afdaee62354dc30477de42ec091faa271390f3390a445261a9a80e31a0df29`.
Fresh three Sol reviews and fresh Gemini review launched with original brief,
prior objections, responses, and the sole v3 delta. Results pending.

Round 3 result: **APPROVED by all four reviewers** for SHA256
`63afdaee62354dc30477de42ec091faa271390f3390a445261a9a80e31a0df29`:

- GPT-6.1 Sol identity/security: APPROVE v3.
- GPT-6.1 Sol financial/compatibility: APPROVE v3.
- GPT-6.1 Sol integration/lifecycle: APPROVE v3.
- Gemini 3.8 Flash High adversarial reviewer: APPROVE v3.
  Task: `node:delegated-task:command%3Amcp%3Add9e163e-799f-4796-b250-154c0a849fc2%3Adelegate-task%3Apayback-plan-gemini-r3-20261105`.

Approval authorizes implementation against the plan. It is not evidence that code
or runtime behavior is correct; all regression, sanitizer and code-review gates
remain required. Production implementation starts only after this recorded gate.
