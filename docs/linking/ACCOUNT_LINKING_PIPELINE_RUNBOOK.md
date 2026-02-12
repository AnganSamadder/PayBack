# Account Linking Pipeline Runbook

## Purpose

This runbook defines the canonical identity/linking pipeline for PayBack across Convex + iOS, with Android/web compatibility.

## Canonical Model (Locked)

- `accounts.member_id`: canonical member ID (immutable after account creation).
- `accounts.alias_member_ids`: account-level alias list (denormalized read path).
- `member_aliases`: alias index/cache table (`alias_member_id -> canonical_member_id`).

## Hard Invariants

1. Canonical identity is always `accounts.member_id`.
2. `member_id` is never overwritten during linking/claim acceptance.
3. All member IDs must be normalized with `normalizeMemberId()` (lowercase) before writes and lookups.
4. `alias_member_ids` never contains canonical self ID.
5. Alias conflicts (alias already mapped to a different canonical) must fail with deterministic error code `ALIAS_CONFLICT`.
6. Alias cycles must fail with deterministic error code `ALIAS_CYCLE`.
7. Invite claim and link-request accept must run the same backend claim core.

## Contract Versioning

- Source of truth: `convex/identity.ts` (`LINKING_CONTRACT_VERSION = 2`).
- Link acceptance payload (`inviteTokens:claim`, `linkRequests:accept`):
  - `contract_version`
  - `target_member_id`
  - `canonical_member_id`
  - `alias_member_ids`
  - `linked_member_id` (legacy compatibility; equals canonical)
  - `linked_account_id`
  - `linked_account_email`

## End-to-End Claim Flow

### 1) Token/request validation

Files:

- `convex/inviteTokens.ts`
- `convex/linkRequests.ts`

Checks:

- Authenticated claimant.
- Not expired / not already claimed (`invite_tokens`, `link_requests`).
- Not self-claim (`SELF_CLAIM`).

### 2) Shared claim core

File:

- `convex/inviteTokens.ts` (`claimForUser`)

Core steps:

1. Normalize target + canonical member IDs.
2. Resolve target canonical via `aliases.resolveCanonicalMemberIdInternal`.
3. Reject deterministic conflict if target already resolves to different canonical.
4. Insert alias mapping when required.
5. Update claimant `accounts.alias_member_ids`.
6. Update owner `account_friends` row for target member.
7. Canonicalize group membership and expense participant/split IDs from target -> canonical.
8. Reconcile `user_expenses` visibility fanout for impacted participants.
9. Return contract v2 payload.

### 3) Link request accept delegates to claim core

File:

- `convex/linkRequests.ts`

`linkRequests:accept` must call:

- `internal.inviteTokens._internalClaimTargetMemberForAccount`

This avoids drift between invite and link-request semantics.

## iOS Consumption Flow

### DTO + model mapping

Files:

- `apps/ios/PayBack/Sources/Services/Convex/ConvexDTOs.swift`
- `apps/ios/PayBack/Sources/Models/LinkingModels.swift`
- `apps/ios/PayBack/Sources/Services/Convex/ConvexInviteLinkService.swift`
- `apps/ios/PayBack/Sources/Services/Convex/ConvexLinkRequestService.swift`

Rules:

- Decode `target_member_id`, `canonical_member_id`, `alias_member_ids`, `contract_version`.
- Keep legacy fallback (`linked_member_id`/`member_id`) for older backend payloads.

### State update policy

File:

- `apps/ios/PayBack/Sources/Services/State/AppStore.swift`

Rules:

- Do not perform local cloud writeback as part of accept/claim mutation response.
- Apply returned canonical/alias IDs to local session (`linkedMemberId`, `equivalentMemberIds`).
- Trigger fresh remote data sync + reconciliation.

## Friend Deduplication + Identity Resolution

### Backend friend enrichment

File:

- `convex/friends.ts`

Rules:

- Always return alias-rich friend payload for linked accounts (`alias_member_ids`).
- Normalize `member_id` and `linked_member_id` in response.

### Client dedupe

File:

- `apps/ios/PayBack/Sources/Services/State/AppStore.swift`

Rules:

- Build `memberAliasMap` from alias-rich DTOs.
- Dedupe precedence:
  1. linked friend
  2. larger alias set
  3. stable tie-breaker by member UUID string
- Identity checks must use `store.areSamePerson(...)`.

## Balance/History/Detail Selectors (Never Strict-ID)

Files:

- `apps/ios/PayBack/Sources/Features/People/FriendsTabView.swift`
- `apps/ios/PayBack/Sources/Features/People/FriendDetailView.swift`
- `apps/ios/PayBack/Sources/Services/State/AppStore.swift`

Rules:

- Never rely only on `friend.id == split.memberId`.
- For friend identity, always use alias equivalence (`store.areSamePerson`).
- For current user identity, include canonical + linked + equivalent IDs.

## Import Policy

File:

- `convex/bulkImport.ts`

Rules:

- Resolve canonical IDs from aliases before write.
- Normalize all member ID fields.
- Never perform name-only auto merge as a canonical identity decision.

## Troubleshooting Checklist

### Symptom: duplicate friend rows

1. Query `friends:list` for affected owner.
2. Check linked friend has non-empty `alias_member_ids`.
3. Verify `AppStore.processFriendsUpdate` receives alias-rich DTOs.
4. Verify dedupe tie-break behavior not oscillating.

### Symptom: “All Settled” while direct expense exists

1. Inspect expense splits: confirm friend appears under alias/canonical mismatch.
2. Verify UI selector uses `areSamePerson` for split and payer matching.
3. Verify claim flow canonicalized expense IDs on acceptance.

### Symptom: group/direct expenses disappear after linking

1. Verify `groups:list` contains membership via canonical+aliases and `user_expenses` path.
2. Verify `user_expenses` rows exist for participant user IDs.
3. Verify claim flow patched `participant_emails` + reconciled fanout.

## Convex CLI Debug Commands

Run from repo root:

```bash
bunx convex run aliases:resolveCanonicalMemberId '{"memberId":"<id>"}'
bunx convex run aliases:getAliasesForMember '{"canonicalMemberId":"<canonical>"}'
bunx convex run friends:list '{}'
bunx convex run groups:list '{}'
bunx convex run expenses:list '{}'
```

For one-off deep inspection, use `bunx convex run` with debug helper mutations/queries in `convex/debug.ts`.

## Never Change Without Tests

Any change touching these paths requires tests:

- `convex/inviteTokens.ts` claim core
- `convex/linkRequests.ts` accept flow
- `convex/aliases.ts` resolution/merge cycle/conflict behavior
- `apps/ios/PayBack/Sources/Services/Convex/ConvexDTOs.swift` link DTO decode
- `apps/ios/PayBack/Sources/Services/State/AppStore.swift` friend dedupe and identity checks
- `apps/ios/PayBack/Sources/Features/People/FriendDetailView.swift`
- `apps/ios/PayBack/Sources/Features/People/FriendsTabView.swift`

Minimum required coverage:

1. Invite claim never overwrites canonical `member_id`.
2. Link request accept shares invite claim semantics.
3. Mixed-case IDs resolve consistently.
4. Alias conflict/cycle deterministic errors.
5. Friend dedupe stable across realtime reloads.
6. Friend detail + dashboard balances include alias-equivalent IDs.
7. Activity/direct history includes alias-backed expenses.

## Future Client Compatibility

- Android/web must consume contract v2 fields exactly.
- Keep additive backward compatibility until at least 2 client generations are fully migrated.
- Do not remove `linked_member_id` fallback until migration window is complete.
