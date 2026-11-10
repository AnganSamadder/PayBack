import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import schema from "../schema";
import { modules } from "../test.setup";
import {
  expenseDependencyMemberIds,
  expenseReferenceMemberIds,
  replaceExpenseMemberReferences
} from "../memberReferences";
import {
  createHistoryWorkerScope,
  historyScopeAllowsGroup,
  assertHistoryProjectionReady
} from "../financialContract";
import { insertRestoredGroupWithVisibility, insertGroupWithVisibility } from "../groupVisibility";

async function setup() {
  const t = convexTest(schema, modules);
  const ids = await t.run(async (ctx) => {
    const owner = await ctx.db.insert("accounts", {
      id: "owner",
      email: "owner@test.com",
      member_id: "a",
      display_name: "A",
      created_at: 1
    });
    const other = await ctx.db.insert("accounts", {
      id: "other",
      email: "other@test.com",
      member_id: "b",
      display_name: "B",
      created_at: 1
    });
    const group = await ctx.db.insert("groups", {
      id: "g",
      name: "Group",
      members: [
        { id: "a", name: "A" },
        { id: "x", name: "Context X" }
      ],
      owner_id: owner,
      owner_account_id: "owner",
      owner_email: "owner@test.com",
      created_at: 1,
      updated_at: 1
    });
    return { owner, other, group };
  });
  return { t, ...ids };
}

test("context references discover restricted history without becoming financial cleanup identities", async () => {
  const f = await setup();
  await f.t.run(async (ctx) => {
    const id = await ctx.db.insert("expenses", {
      id: "e",
      group_id: "g",
      group_ref: f.group,
      context_kind: "group",
      description: "History",
      date: 1,
      total_amount: 10,
      paid_by_member_id: "a",
      involved_member_ids: ["a", "b"],
      splits: [
        { id: "s1", member_id: "a", amount: 5, is_settled: true },
        { id: "s2", member_id: "b", amount: 5, is_settled: false }
      ],
      is_settled: false,
      owner_id: f.owner,
      owner_account_id: "owner",
      owner_email: "owner@test.com",
      participant_member_ids: ["a", "b"],
      participant_emails: [],
      participants: [
        { member_id: "a", name: "A" },
        { member_id: "b", name: "B" }
      ],
      restored_historical_member_ids: ["a", "b"],
      restored_history_context_member_ids: ["a", "x"],
      has_restored_history: true,
      created_at: 1,
      updated_at: 1
    });
    const expense = (await ctx.db.get(id))!;
    expect(expenseReferenceMemberIds(expense)).toEqual(["a", "b"]);
    expect(expenseDependencyMemberIds(expense)).toEqual(["a", "b", "x"]);
    await replaceExpenseMemberReferences(ctx, expense);
    const refs = await ctx.db
      .query("member_references")
      .withIndex("by_owner_member_kind_history", (q) =>
        q
          .eq("owner_id", f.owner)
          .eq("member_id", "x")
          .eq("entity_kind", "expense")
          .eq("has_restored_history", true)
      )
      .collect();
    expect(refs).toHaveLength(1);
    expect(refs[0].entity_document_id).toBe(String(id));
    expect((await ctx.db.get(id))!.participant_member_ids).not.toContain("x");
  });
});

test("history scopes reject forgery, stale generations, foreign groups, and unrelated identity jobs", async () => {
  const f = await setup();
  await f.t.run(async (ctx) => {
    const job = await ctx.db.insert("group_history_reconciliations", {
      group_ref: f.group,
      owner_id: f.owner,
      generation: "generation",
      page_size: 8,
      phase: "pending",
      attempts: 0,
      created_at: 1,
      updated_at: 1
    });
    await ctx.db.patch(f.group, { history_reconciliation_id: job });
    const group = (await ctx.db.get(f.group))!;
    await expect(
      historyScopeAllowsGroup(
        ctx,
        {
          descriptors: [{ kind: "group_history", job_id: job, generation: "generation" }]
        } as never,
        group
      )
    ).rejects.toThrow("Invalid internal history scope");
    await expect(
      createHistoryWorkerScope(ctx, { kind: "group_history", job_id: job, generation: "stale" })
    ).rejects.toThrow("Stale group history generation");
    const scope = await createHistoryWorkerScope(ctx, {
      kind: "group_history",
      job_id: job,
      generation: "generation"
    });
    expect(await historyScopeAllowsGroup(ctx, scope, group)).toBe(true);
    expect(
      await historyScopeAllowsGroup(ctx, scope, {
        ...group,
        _id: "other-group" as never,
        history_reconciliation_id: undefined
      })
    ).toBe(false);
    await ctx.db.insert("identity_operations", {
      actor_id: f.owner,
      creator_id: f.owner,
      kind: "claim",
      source_member_ids: ["unrelated"],
      target_member_id: "elsewhere",
      generation: "other-generation",
      cutoff: Date.now(),
      phase: "groups",
      member_index: 0,
      attempts: 0,
      created_at: 1,
      updated_at: 1
    });
    await expect(
      assertHistoryProjectionReady(ctx, {
        ownerId: f.owner,
        memberIds: ["x"],
        groupId: f.group,
        scope
      })
    ).rejects.toThrow("IDENTITY_OPERATION_PENDING");
  });
});

test("restore-only groups omit authoritative inactive identities while retaining unknown and unproven raw IDs", async () => {
  const f = await setup();
  await f.t.run(async (ctx) => {
    await ctx.db.patch(f.other, { status: "deleted", alias_member_ids: ["old-b"] });
    await ctx.db.insert("member_aliases", {
      alias_member_id: "old-b",
      canonical_member_id: "b",
      materialization_source: "account_alias",
      source_account_id: "other",
      account_email: "other@test.com",
      created_at: 1
    });
    await ctx.db.insert("member_aliases", {
      alias_member_id: "unproven",
      canonical_member_id: "b",
      materialization_source: "account_alias",
      account_email: "other@test.com",
      created_at: 1
    });
  });
  const value = {
    id: "restore",
    name: "History",
    members: [
      { id: "a", name: "A" },
      { id: "b", name: "B" },
      { id: "old-b", name: "Old B" },
      { id: "offline", name: "Offline" },
      { id: "unproven", name: "Unproven" }
    ],
    owner_id: f.owner,
    owner_account_id: "owner",
    owner_email: "owner@test.com",
    created_at: 1,
    updated_at: 1
  };
  await expect(f.t.run((ctx) => insertGroupWithVisibility(ctx, value))).rejects.toThrow();
  const result = await f.t.run((ctx) => insertRestoredGroupWithVisibility(ctx, value));
  expect(result.omittedInactiveMemberIds.sort()).toEqual(["b", "old-b"]);
  const group = await f.t.run((ctx) => ctx.db.get(result.groupId));
  expect(group!.members.map((member) => member.id)).toEqual(["a", "offline", "unproven"]);
  const grants = await f.t.run((ctx) =>
    ctx.db
      .query("group_visibility")
      .withIndex("by_group_id", (q) => q.eq("group_id", result.groupId))
      .collect()
  );
  expect(grants.map((row) => row.account_id)).toEqual([f.owner]);
});

test("derived friend history joins only its owner's deletion and retains real identity barriers", async () => {
  const f = await setup();
  await f.t.run(async (ctx) => {
    const friend = await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "offline",
      name: "Offline",
      has_linked_account: false,
      profile_avatar_color: "blue",
      updated_at: 1
    });
    const job = await ctx.db.insert("friend_deletion_jobs", {
      owner_id: f.owner,
      friend_id: friend,
      member_id: "offline",
      member_ids: ["offline"],
      linked: false,
      phase: "expenses",
      member_index: 0,
      processed: 0,
      created_at: 1,
      updated_at: 1
    });
    const operation = await ctx.db.insert("identity_operations", {
      actor_id: f.owner,
      creator_id: f.owner,
      local_owner_id: f.owner,
      kind: "friend_history",
      source_member_ids: ["b"],
      target_member_id: "b",
      generation: "derived",
      cutoff: 1,
      phase: "expenses",
      member_index: 0,
      attempts: 0,
      created_at: 1,
      updated_at: 1
    });
    const scope = await createHistoryWorkerScope(ctx, {
      kind: "identity",
      operation_id: operation,
      generation: "derived"
    });
    await assertHistoryProjectionReady(ctx, { ownerId: f.owner, memberIds: ["b"], scope });
    const unrelated = await ctx.db.insert("identity_operations", {
      actor_id: f.owner,
      creator_id: f.owner,
      kind: "local_merge",
      source_member_ids: ["other"],
      target_member_id: "elsewhere",
      generation: "unrelated",
      cutoff: 1,
      phase: "groups",
      member_index: 0,
      attempts: 0,
      created_at: 1,
      updated_at: 1
    });
    await expect(
      assertHistoryProjectionReady(ctx, { ownerId: f.owner, memberIds: ["b"], scope })
    ).rejects.toThrow("IDENTITY_OPERATION_PENDING");
    const mergeScope = await createHistoryWorkerScope(ctx, {
      kind: "identity",
      operation_id: unrelated,
      generation: "unrelated"
    });
    await ctx.db.patch(operation, { phase: "complete" });
    await expect(
      assertHistoryProjectionReady(ctx, {
        ownerId: f.owner,
        memberIds: ["other"],
        scope: mergeScope
      })
    ).rejects.toThrow("FRIEND_DELETION_PENDING");
    await ctx.db.patch(job, { phase: "cancelled" });
    await expect(
      assertHistoryProjectionReady(ctx, { ownerId: f.owner, memberIds: ["b"], scope })
    ).rejects.toThrow("Stale identity reconciliation generation");
  });
});

test("only confirmed account deletion can bind its persisted expense across a foreign group job", async () => {
  const f = await setup();
  await f.t.run(async (ctx) => {
    const { bindHistoryExpenseScope } = await import("../financialContract");
    const progress = await ctx.db.insert("account_deletion_progress", {
      auth_subject: "other",
      account_id: f.other,
      account_auth_id: "other",
      account_email: "other@test.com",
      member_ids: ["b"],
      request_id: "request",
      tombstone_email: "deleted@test.com",
      phase: "preflight_expenses_owner_id",
      friendships_unlinked: 0,
      processed_count: 0,
      started_at: 1,
      updated_at: 1
    });
    const id = await ctx.db.insert("expenses", {
      id: "bound",
      group_id: "g",
      group_ref: f.group,
      description: "Bound",
      date: 1,
      total_amount: 1,
      paid_by_member_id: "b",
      involved_member_ids: ["b"],
      splits: [{ id: "split", member_id: "b", amount: 1, is_settled: false }],
      is_settled: false,
      owner_id: f.other,
      owner_account_id: "other",
      owner_email: "other@test.com",
      participant_member_ids: ["b"],
      participant_emails: [],
      participants: [{ member_id: "b", name: "B" }],
      created_at: 1,
      updated_at: 1
    });
    const expense = (await ctx.db.get(id))!,
      group = (await ctx.db.get(f.group))!;
    const preparatory = await createHistoryWorkerScope(ctx, {
      kind: "account_deletion",
      progress_id: progress,
      request_id: "request"
    });
    const beforeFence = await bindHistoryExpenseScope(ctx, preparatory, expense);
    expect(await historyScopeAllowsGroup(ctx, beforeFence, group)).toBe(false);
    await ctx.db.patch(f.other, { status: "deleting" });
    const confirmed = await createHistoryWorkerScope(ctx, {
      kind: "account_deletion",
      progress_id: progress,
      request_id: "request"
    });
    const bound = await bindHistoryExpenseScope(ctx, confirmed, expense);
    expect(await historyScopeAllowsGroup(ctx, bound, group)).toBe(true);
    const { _id, _creationTime, ...otherValue } = expense;
    const otherExpenseId = await ctx.db.insert("expenses", {
      ...otherValue,
      id: "different-expense",
      owner_id: f.owner,
      owner_account_id: "owner",
      owner_email: "owner@test.com"
    });
    await expect(
      bindHistoryExpenseScope(ctx, bound, (await ctx.db.get(otherExpenseId))!)
    ).rejects.toThrow("Account deletion scope belongs to another expense");
    // The same persisted row may be prepared for a new steward without borrowing a second record.
    expect(await bindHistoryExpenseScope(ctx, bound, { ...expense, owner_id: f.owner })).toBe(
      bound
    );
    expect(await historyScopeAllowsGroup(ctx, confirmed, group)).toBe(false);
    await expect(
      bindHistoryExpenseScope(ctx, confirmed, { ...expense, group_ref: "foreign" as never })
    ).rejects.toThrow("Stale account deletion expense binding");
    await ctx.db.patch(id, { owner_id: f.owner });
    expect(await historyScopeAllowsGroup(ctx, bound, group)).toBe(false);
    await ctx.db.patch(progress, { request_id: "replaced" });
    await expect(historyScopeAllowsGroup(ctx, bound, group)).rejects.toThrow(
      "Stale account deletion scope"
    );
  });
});
