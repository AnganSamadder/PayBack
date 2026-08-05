import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { internal } from "../_generated/api";
import { Id } from "../_generated/dataModel";
import schema from "../schema";
import { modules } from "../test.setup";

async function seedExpense(
  ctx: any,
  ownerId: Id<"accounts">,
  id: string,
  groupId: string,
  options: { ownerId?: Id<"accounts">; groupRef?: Id<"groups"> } = {}
) {
  const expenseId = await ctx.db.insert("expenses", {
    id,
    group_id: groupId,
    description: id,
    date: 1,
    total_amount: 1,
    paid_by_member_id: "maintenance_owner_member",
    involved_member_ids: ["maintenance_owner_member"],
    splits: [
      {
        id: `${id}_split`,
        member_id: "maintenance_owner_member",
        amount: 1,
        is_settled: false
      }
    ],
    is_settled: false,
    owner_email: "maintenance-owner@test.com",
    owner_account_id: "maintenance_owner_auth",
    owner_id: options.ownerId ?? ownerId,
    group_ref: options.groupRef,
    participant_member_ids: ["maintenance_owner_member"],
    participant_emails: ["maintenance-owner@test.com"],
    participants: [{ member_id: "maintenance_owner_member", name: "Owner" }],
    created_at: 1,
    updated_at: 1
  });
  await ctx.db.insert("user_expenses", {
    user_id: "maintenance_owner_auth",
    expense_id: id,
    updated_at: 1
  });
  return expenseId;
}

async function seedOwnerAndDirectGroup(ctx: any) {
  const ownerId = await ctx.db.insert("accounts", {
    id: "maintenance_owner_auth",
    email: "maintenance-owner@test.com",
    display_name: "Owner",
    member_id: "maintenance_owner_member",
    created_at: 1
  });
  const groupId = await ctx.db.insert("groups", {
    id: "maintenance_group",
    name: "Direct",
    members: [
      { id: "maintenance_owner_member", name: "Owner" },
      { id: "maintenance_friend_member", name: "Friend" }
    ],
    is_direct: true,
    owner_email: "maintenance-owner@test.com",
    owner_account_id: "maintenance_owner_auth",
    owner_id: ownerId,
    created_at: 1,
    updated_at: 1
  });
  return { ownerId, groupId };
}

test("context-kind backfill is bounded, retryable, and revision-aware", async () => {
  const t = convexTest(schema, modules);
  const fixture = await t.run(async (ctx) => {
    const { ownerId } = await seedOwnerAndDirectGroup(ctx);
    await seedExpense(ctx, ownerId, "maintenance_context_one", "maintenance_group", { ownerId });
    await seedExpense(ctx, ownerId, "maintenance_context_two", "maintenance_group", { ownerId });
    return { ownerId };
  });

  const first = await t.mutation(internal.migrations.backfillExpenseContextKind, { limit: 1 });
  expect(first).toMatchObject({ processed: 1, patchedDirect: 1, isDone: false });
  expect(first.continueCursor).toEqual(expect.any(String));

  const firstState = await t.run(async (ctx) => ({
    expenses: await ctx.db.query("expenses").order("asc").collect(),
    rows: await ctx.db.query("user_expenses").order("asc").collect(),
    sync: await ctx.db
      .query("account_sync_state")
      .withIndex("by_account_id", (query) => query.eq("account_id", fixture.ownerId))
      .unique()
  }));
  expect(firstState.expenses.map((expense) => expense.context_kind)).toEqual(["direct", undefined]);
  expect(firstState.rows[0]).toMatchObject({
    account_ref: fixture.ownerId,
    expense_ref: firstState.expenses[0]._id
  });
  expect(firstState.sync?.expenses_revision).toBe(1);

  const second = await t.mutation(internal.migrations.backfillExpenseContextKind, {
    cursor: first.continueCursor,
    limit: 1
  });
  expect(second).toMatchObject({ processed: 1, patchedDirect: 1, isDone: false });
  expect(second.continueCursor).toEqual(expect.any(String));

  const afterSecondRevision = await t.run(async (ctx) =>
    ctx.db
      .query("account_sync_state")
      .withIndex("by_account_id", (query) => query.eq("account_id", fixture.ownerId))
      .unique()
  );
  expect(afterSecondRevision?.expenses_revision).toBe(2);

  await t.mutation(internal.migrations.backfillExpenseContextKind, {
    cursor: first.continueCursor,
    limit: 1
  });
  const afterRetryRevision = await t.run(async (ctx) =>
    ctx.db
      .query("account_sync_state")
      .withIndex("by_account_id", (query) => query.eq("account_id", fixture.ownerId))
      .unique()
  );
  expect(afterRetryRevision?.expenses_revision).toBe(2);

  const completed = await t.mutation(internal.migrations.backfillExpenseContextKind, {
    cursor: second.continueCursor,
    limit: 1
  });
  expect(completed).toMatchObject({ processed: 0, isDone: true });
});

test("ID backfill expense phase writes canonical refs and fails closed on duplicate client IDs", async () => {
  const t = convexTest(schema, modules);
  const fixture = await t.run(async (ctx) => {
    const { ownerId, groupId } = await seedOwnerAndDirectGroup(ctx);
    const expenseId = await seedExpense(
      ctx,
      ownerId,
      "maintenance_backfill_id",
      "maintenance_group"
    );
    return { ownerId, groupId, expenseId };
  });

  const result = await t.mutation(internal["migrations/backfill_ids"].backfillIds, {
    phase: "expenses",
    limit: 1
  });
  expect(result).toMatchObject({
    phase: "expenses",
    isDone: false,
    expenses: { processed: 1, ownerUpdated: 0, groupUpdated: 1 }
  });
  expect(result.continueCursor).toEqual(expect.any(String));

  const repaired = await t.run(async (ctx) => ({
    expense: await ctx.db.get(fixture.expenseId),
    row: await ctx.db.query("user_expenses").unique(),
    sync: await ctx.db
      .query("account_sync_state")
      .withIndex("by_account_id", (query) => query.eq("account_id", fixture.ownerId))
      .unique()
  }));
  expect(repaired.expense).toMatchObject({
    owner_id: fixture.ownerId,
    group_ref: fixture.groupId
  });
  expect(repaired.row).toMatchObject({
    account_ref: fixture.ownerId,
    expense_ref: fixture.expenseId
  });
  expect(repaired.sync?.expenses_revision).toBe(1);

  await t.mutation(internal["migrations/backfill_ids"].backfillIds, {
    phase: "expenses",
    limit: 1
  });
  const afterRetry = await t.run(async (ctx) =>
    ctx.db
      .query("account_sync_state")
      .withIndex("by_account_id", (query) => query.eq("account_id", fixture.ownerId))
      .unique()
  );
  expect(afterRetry?.expenses_revision).toBe(1);

  const completed = await t.mutation(internal["migrations/backfill_ids"].backfillIds, {
    phase: "expenses",
    cursor: result.continueCursor,
    limit: 1
  });
  expect(completed).toMatchObject({ phase: "complete", isDone: true });

  const duplicate = convexTest(schema, modules);
  await duplicate.run(async (ctx) => {
    const { ownerId } = await seedOwnerAndDirectGroup(ctx);
    await seedExpense(ctx, ownerId, "duplicate_maintenance_id", "maintenance_group");
    await seedExpense(ctx, ownerId, "duplicate_maintenance_id", "maintenance_group");
  });
  await expect(
    duplicate.mutation(internal["migrations/backfill_ids"].backfillIds, {
      phase: "expenses",
      limit: 2
    })
  ).rejects.toThrow(/appears more than once|not unique/);
  const duplicateState = await duplicate.run(async (ctx) => ({
    expenses: await ctx.db.query("expenses").collect(),
    sync: await ctx.db.query("account_sync_state").collect()
  }));
  expect(duplicateState.expenses.every((expense) => expense.group_ref === undefined)).toBe(true);
  expect(duplicateState.sync).toEqual([]);
});
