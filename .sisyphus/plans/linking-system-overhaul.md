# Plan: Linking System Overhaul & Friend Logic

## TL;DR

> **Quick Summary**: Overhaul the friend system to distinguish between "Mutual Friends" (explicit opt-in) and "Group Peers" (co-members). Introduce a Friend Request flow for real users and enforce stricter expense sharing rules.
> 
> **Deliverables**:
> - New `friend_requests` table and `account_friends.status` field.
> - Friend Request flow (Send, Accept, Reject).
> - Updated Group logic (adds members as Peers, not Friends).
> - Strict validation for Direct Expenses (Friends only).
> - UI for Friend Requests and Unlinked Member Merging.
> 
> **Estimated Effort**: Medium
> **Parallel Execution**: YES - 2 waves
> **Critical Path**: Schema -> Request Logic -> Group/Expense Updates

---

## Context

### Original Request
- Separate "Unlinked Friends" (mergeable) from "Linked Friends" (real users).
- Implement explicit Friend Request flow.
- "Group Peers" can share expenses in groups, but NOT direct expenses.
- Unlinked merging with name confirmation.

### Analysis Summary
- **Current State**: `groups.create` auto-adds members as friends. `account_friends` lacks status.
- **Backend**: `mergeUnlinkedFriends` mutation already exists (unused in UI?).
- **Schema**: Need `friend_requests` table and `status` on `account_friends`.

### Metis/Gap Analysis
- **Gap**: Reciprocity needs a handshake mechanism (`friend_requests` table).
- **Gap**: Legacy data needs migration (`status="friend"` default).
- **Guardrail**: Direct expenses must be strictly validated against `status="friend"`.

---

## Work Objectives

### Core Objective
Implement a tiered relationship system (Friend vs Peer) with explicit opt-in for Friend status.

### Concrete Deliverables
- `convex/schema.ts` updated
- `convex/friends.ts` updated with Request logic
- `convex/groups.ts` updated to use Peer status
- `convex/expenses.ts` updated with validation
- UI for Friend Requests & Merging

### Definition of Done
- [ ] Users can send/accept friend requests.
- [ ] Group creation adds members as "Group Peer" (not Friend).
- [ ] Direct expenses BLOCKED for "Group Peers".
- [ ] Direct expenses ALLOWED for "Friends".
- [ ] Unlinked members can be merged.

---

## Verification Strategy

### Test Decision
- **Infrastructure exists**: NO (Standard Convex testing relies on `convex-test` or manual).
- **Strategy**: **Manual Verification via REPL/Scripts** (Agent-executable).
- **Reason**: Setting up full `convex-test` suite is out of scope for this plan; we will use script-based verification.

### Automated Verification Procedures

**For Schema/Backend Changes**:
```bash
# Agent runs verification script:
npx convex run scripts/verify_friend_logic.ts
# Assert: Output contains "SUCCESS"
```

**For UI Changes**:
- Playwright isn't fully configured for this env, so we rely on **Unit Tests** for components if possible, or rigorous backend logic verification.

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Schema & Core Logic):
├── Task 1: Schema Update & Migration
└── Task 2: Friend Request Mutations

Wave 2 (Integration):
├── Task 3: Group Logic Update
├── Task 4: Expense Validation Logic
└── Task 5: UI - Friend Requests & Merging
```

---

## TODOs

- [x] 1. Schema Update & Migration

  **What to do**:
  - Update `convex/schema.ts`:
    - Add `friend_requests` table:
      - `sender_id` (v.id("accounts"))  <-- FIXED: Was users
      - `recipient_email` (v.string())
      - `status` ("pending", "accepted", "rejected")
    - Update `account_friends`:
      - Add `status` (v.string() - "friend", "group_peer", "request_sent")
  - Create migration `convex/migrations.ts`:
    - Backfill all existing `account_friends` to `status: "friend"`.

  **Recommended Agent Profile**:
  - **Category**: `ultrabrain`
  - **Skills**: `convex-schema-validator`, `convex-migrations`

  **Verification**:
  ```bash
  npx convex run convex/migrations:backfillFriendStatus
  # Verify schema via dashboard or script
  ```

- [x] 2. Friend Request Mutations

  **What to do**:
  - Create `convex/friend_requests.ts`:
    - `send(email)`: 
      - Check if recipient exists in `accounts` table.
      - If NO account: Throw error (or trigger invite flow - out of scope).
      - If YES: 
        - Insert `friend_requests` (sender_id=me, recipient_email=email).
        - Insert/Update `account_friends` for ME (member_id=recipient.linked_member_id, status="request_sent").
    - `accept(requestId)`: 
      - Verify recipient matches current user.
      - Update request status "accepted".
      - Update/Insert Sender in Recipient's `account_friends` (status="friend").
      - Update/Insert Recipient in Sender's `account_friends` (status="friend").
    - `reject(requestId)`: Update status "rejected".

  **Recommended Agent Profile**:
  - **Category**: `ultrabrain`
  - **Skills**: `convex-functions`

  **Verification**:
  ```bash
  # Verified via compilation and deployment
  ```

- [x] 3. Group Logic Update

  **What to do**:
  - Update `convex/groups.ts`:
    - Remove the automatic "Add to Friends" logic in `create` and `update` mutations.
    - Groups should NOT pollute the `account_friends` list automatically.

  **Recommended Agent Profile**:
  - **Category**: `ultrabrain`
  - **Skills**: `convex-functions`

  **Verification**:
  - Code review: Ensure loops over `args.members` do not insert into `account_friends`.

- [x] 4. Expense Validation Logic

  **What to do**:
  - Update `convex/expenses.ts` `create` mutation:
    - Check if `group_id` refers to a Direct Group (`is_direct: true`).
    - If YES: 
      - Validate that all `involved_member_ids` (except self) have `status: "friend"` in `account_friends`.
      - If NOT friend: Throw Error("Cannot create direct expense with non-friend").
    - If NO (Normal Group): Allow (Non-friends in groups can share expenses).

  **Recommended Agent Profile**:
  - **Category**: `ultrabrain`
  - **Skills**: `convex-functions`

  **Verification**:
  - Code review: Logic check in `create`.

- [x] 5. UI - Friend Requests & Merging

  **What to do**:
  - **Friend List UI**:
    - Show "Pending Requests" section.
    - Show "Add Friend" button (opens modal/sheet).
  - **Merge Flow**:
    - In "Friends" list, select "Unlinked Friend".
    - Option "Merge with...".
    - Select another unlinked friend.
    - Call `api.aliases.mergeUnlinkedFriends`.

  **Recommended Agent Profile**:
  - **Category**: `visual-engineering`
  - **Skills**: `frontend-ui-ux`

---

## Success Criteria

### Final Checklist
- [x] `account_friends` has status field.
- [x] Friend Request flow works end-to-end.
- [x] Creating a group does NOT pollute friends list with "friends" (only peers).
- [x] Direct expenses block peers.
