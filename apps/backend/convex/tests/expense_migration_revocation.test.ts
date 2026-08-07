import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { internal } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

async function insertRevokedExpenseFixture(
  t: ReturnType<typeof convexTest>,
  options: { expenseId: string; ownerName: string; includeActiveTarget?: boolean }
) {
  await t.run(async (ctx) => {
    const isNameRepair = options.ownerName === "Repair Owner";
    const ownerMemberId = isNameRepair
      ? `${options.expenseId}_new_member`
      : `${options.expenseId}_owner_member`;
    const ownerId = await ctx.db.insert("accounts", {
      id: `${options.expenseId}_owner_auth`,
      email: `${options.expenseId}-owner@test.com`,
      display_name: options.ownerName,
      created_at: Date.now(),
      member_id: ownerMemberId
    });
    await ctx.db.insert("accounts", {
      id: `${options.expenseId}_target_auth`,
      email: `${options.expenseId}-target@test.com`,
      display_name: "Target",
      created_at: Date.now(),
      member_id: isNameRepair
        ? `${options.expenseId}_target_member`
        : `${options.expenseId}_new_member`
    });
    if (isNameRepair) {
      await ctx.db.insert("groups", {
        id: `${options.expenseId}_group`,
        name: "Repair group",
        members: [
          { id: `${options.expenseId}_old_member`, name: options.ownerName },
          { id: `${options.expenseId}_active_member`, name: "Active" }
        ],
        owner_email: `${options.expenseId}-owner@test.com`,
        owner_account_id: `${options.expenseId}_owner_auth`,
        owner_id: ownerId,
        created_at: Date.now(),
        updated_at: Date.now()
      });
    }

    const activeTargetMemberIds =
      options.includeActiveTarget && !isNameRepair ? [`${options.expenseId}_new_member`] : [];
    await ctx.db.insert("expenses", {
      id: options.expenseId,
      group_id: `${options.expenseId}_group`,
      description: "Revoked history",
      date: Date.now(),
      total_amount: 20,
      paid_by_member_id: isNameRepair ? `${options.expenseId}_old_member` : ownerMemberId,
      involved_member_ids: [ownerMemberId, ...activeTargetMemberIds],
      splits: [
        {
          id: `${options.expenseId}_revoked_split`,
          member_id: `${options.expenseId}_old_member`,
          amount: 10,
          is_settled: false
        },
        ...(options.includeActiveTarget
          ? [
              {
                id: `${options.expenseId}_active_target_split`,
                member_id: `${options.expenseId}_new_member`,
                amount: 10,
                is_settled: false
              }
            ]
          : [
              {
                id: `${options.expenseId}_owner_split`,
                member_id: ownerMemberId,
                amount: 10,
                is_settled: false
              }
            ])
      ],
      is_settled: false,
      owner_email: `${options.expenseId}-owner@test.com`,
      owner_account_id: `${options.expenseId}_owner_auth`,
      owner_id: ownerId,
      participant_member_ids: [ownerMemberId, ...activeTargetMemberIds],
      inactive_participant_member_ids: [`${options.expenseId}_old_member`],
      participant_emails: [
        `${options.expenseId}-owner@test.com`,
        `${options.expenseId}-target@test.com`
      ],
      participants: [
        {
          member_id: `${options.expenseId}_old_member`,
          name: options.ownerName,
          linked_account_id: `${options.expenseId}_target_auth`,
          linked_account_email: `${options.expenseId}-target@test.com`
        },
        ...(options.includeActiveTarget
          ? [
              {
                member_id: `${options.expenseId}_new_member`,
                name: "Active target",
                linked_account_id: isNameRepair
                  ? `${options.expenseId}_owner_auth`
                  : `${options.expenseId}_target_auth`,
                linked_account_email: isNameRepair
                  ? `${options.expenseId}-owner@test.com`
                  : `${options.expenseId}-target@test.com`
              }
            ]
          : [])
      ],
      created_at: Date.now(),
      updated_at: Date.now()
    });
    await ctx.db.insert("user_expenses", {
      user_id: `${options.expenseId}_owner_auth`,
      expense_id: options.expenseId,
      updated_at: Date.now()
    });
    await ctx.db.insert("user_expenses", {
      user_id: `${options.expenseId}_target_auth`,
      expense_id: options.expenseId,
      updated_at: Date.now()
    });
  });
}

test("fixAllExpenseMemberIds carries revocation to the rewritten identity", async () => {
  const t = convexTest(schema, modules);
  await insertRevokedExpenseFixture(t, {
    expenseId: "force_repair",
    ownerName: "Owner"
  });

  const repair = await t.mutation(internal.migrations.fixAllExpenseMemberIds, {
    old_member_id: "force_repair_old_member",
    new_member_id: "force_repair_new_member",
    account_email: "force_repair-owner@test.com"
  });
  expect(repair).toMatchObject({ expensesFixed: 1, expensesSkipped: 0, isDone: true });

  const result = await t.run(async (ctx) => {
    const expense = await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "force_repair"))
      .unique();
    const visibility = await ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) => q.eq("expense_id", "force_repair"))
      .collect();
    return { expense, visibility };
  });

  expect(result.expense?.splits.map((split) => split.member_id)).toContain(
    "force_repair_new_member"
  );
  expect(result.expense?.participants.map((participant) => participant.member_id)).toContain(
    "force_repair_new_member"
  );
  expect(result.expense?.inactive_participant_member_ids).toEqual(["force_repair_new_member"]);
  expect(result.expense?.participant_emails).toEqual(["force_repair-owner@test.com"]);
  expect(result.visibility.map((row) => row.user_id)).toEqual(["force_repair_owner_auth"]);
});

test("fixExpenseMemberIds skips a rewrite that would merge revoked and active history", async () => {
  const t = convexTest(schema, modules);
  await insertRevokedExpenseFixture(t, {
    expenseId: "name_repair",
    ownerName: "Repair Owner",
    includeActiveTarget: true
  });
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "name_repair_surface_auth",
      email: "name-repair-surface@test.com",
      display_name: "Surface-only participant",
      created_at: Date.now(),
      member_id: "name_repair_surface_member"
    });
    const expense = await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "name_repair"))
      .unique();
    if (!expense) throw new Error("Expected name repair fixture");
    await ctx.db.patch(expense._id, {
      involved_member_ids: [...expense.involved_member_ids, "name_repair_surface_member"],
      splits: [
        ...expense.splits,
        {
          id: "name_repair_surface_split",
          member_id: "name_repair_surface_member",
          amount: 1,
          is_settled: false
        }
      ],
      participant_emails: [...expense.participant_emails, "name-repair-surface@test.com"]
    });
    await ctx.db.insert("user_expenses", {
      user_id: "name_repair_surface_auth",
      expense_id: "name_repair",
      updated_at: Date.now()
    });
  });

  const repair = await t.mutation(internal.migrations.fixExpenseMemberIds, {});
  expect(repair).toMatchObject({ expensesFixed: 0, expensesSkipped: 1, isDone: false });
  expect(repair.continueCursor).toEqual(expect.any(String));
  const continuation = await t.mutation(internal.migrations.fixExpenseMemberIds, {
    cursor: repair.continueCursor
  });
  expect(continuation).toMatchObject({ isDone: true });

  const result = await t.run(async (ctx) => {
    const expense = await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "name_repair"))
      .unique();
    const visibility = await ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) => q.eq("expense_id", "name_repair"))
      .collect();
    return { expense, visibility };
  });
  expect(result.expense?.splits.map((split) => split.member_id)).toEqual([
    "name_repair_old_member",
    "name_repair_new_member",
    "name_repair_surface_member"
  ]);
  expect(result.expense?.participants.map((participant) => participant.member_id)).toEqual([
    "name_repair_old_member",
    "name_repair_new_member"
  ]);
  expect(result.expense?.inactive_participant_member_ids).toEqual(["name_repair_old_member"]);
  expect(new Set(result.expense?.participant_emails)).toEqual(
    new Set(["name_repair-owner@test.com", "name-repair-surface@test.com"])
  );
  expect(new Set(result.visibility.map((row) => row.user_id))).toEqual(
    new Set(["name_repair_owner_auth", "name_repair_surface_auth"])
  );
});

test("fixExpenseMemberIds pages near its aggregate budget and rejects larger batches", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    for (const [accountIndex, expenseCount] of [128, 128, 1].entries()) {
      const ownerId = await ctx.db.insert("accounts", {
        id: `repair_budget_auth_${accountIndex}`,
        email: `repair-budget-${accountIndex}@test.com`,
        display_name: `Budget Owner ${accountIndex}`,
        created_at: Date.now(),
        member_id: `repair_budget_member_${accountIndex}`
      });
      for (let expenseIndex = 0; expenseIndex < expenseCount; expenseIndex++) {
        await ctx.db.insert("expenses", {
          id: `repair_budget_expense_${accountIndex}_${expenseIndex}`,
          group_id: `repair_budget_group_${accountIndex}`,
          description: "Budget fixture",
          date: Date.now(),
          total_amount: 1,
          paid_by_member_id: `repair_budget_member_${accountIndex}`,
          involved_member_ids: [`repair_budget_member_${accountIndex}`],
          splits: [
            {
              id: `repair_budget_split_${accountIndex}_${expenseIndex}`,
              member_id: `repair_budget_member_${accountIndex}`,
              amount: 1,
              is_settled: false
            }
          ],
          is_settled: false,
          owner_email: `repair-budget-${accountIndex}@test.com`,
          owner_account_id: `repair_budget_auth_${accountIndex}`,
          owner_id: ownerId,
          participant_member_ids: [`repair_budget_member_${accountIndex}`],
          participant_emails: [`repair-budget-${accountIndex}@test.com`],
          participants: [
            {
              member_id: `repair_budget_member_${accountIndex}`,
              name: `Budget Owner ${accountIndex}`
            }
          ],
          created_at: Date.now(),
          updated_at: Date.now()
        });
      }
    }
  });

  const firstPage = await t.mutation(internal.migrations.fixExpenseMemberIds, { limit: 2 });
  expect(firstPage).toMatchObject({
    expensesFixed: 0,
    expensesSkipped: 0,
    expensesScanned: 256,
    isDone: false
  });
  expect(firstPage.continueCursor).toEqual(expect.any(String));
  const finalPage = await t.mutation(internal.migrations.fixExpenseMemberIds, {
    cursor: firstPage.continueCursor,
    limit: 2
  });
  expect(finalPage).toMatchObject({ expensesScanned: 1, isDone: true });

  await expect(t.mutation(internal.migrations.fixExpenseMemberIds, { limit: 3 })).rejects.toThrow(
    "limit must be an integer between 1 and 2"
  );
});

test("fixExpenseMemberIds skips rewriting an active identity onto a revoked target", async () => {
  const t = convexTest(schema, modules);
  await insertRevokedExpenseFixture(t, {
    expenseId: "reverse_name_repair",
    ownerName: "Repair Owner",
    includeActiveTarget: true
  });
  await t.run(async (ctx) => {
    const expense = await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "reverse_name_repair"))
      .unique();
    if (!expense) throw new Error("Expected reverse repair fixture");
    await ctx.db.patch(expense._id, {
      involved_member_ids: ["reverse_name_repair_old_member"],
      participant_member_ids: ["reverse_name_repair_old_member"],
      inactive_participant_member_ids: ["reverse_name_repair_new_member"]
    });
  });

  const repair = await t.mutation(internal.migrations.fixExpenseMemberIds, {});
  expect(repair).toMatchObject({ expensesFixed: 0, expensesSkipped: 1, isDone: false });
  expect(repair.continueCursor).toEqual(expect.any(String));
  const continuation = await t.mutation(internal.migrations.fixExpenseMemberIds, {
    cursor: repair.continueCursor
  });
  expect(continuation).toMatchObject({ isDone: true });

  const expense = await t.run(async (ctx) =>
    ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "reverse_name_repair"))
      .unique()
  );
  expect(expense?.paid_by_member_id).toBe("reverse_name_repair_old_member");
  expect(expense?.splits.map((split) => split.member_id)).toEqual([
    "reverse_name_repair_old_member",
    "reverse_name_repair_new_member"
  ]);
  expect(expense?.inactive_participant_member_ids).toEqual(["reverse_name_repair_new_member"]);
});

test("participant email backfill rejects conflicting owner tuples without granting visibility", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    const ownerAId = await ctx.db.insert("accounts", {
      id: "owner_conflict_a_auth",
      email: "owner-conflict-a@test.com",
      display_name: "Owner A",
      created_at: Date.now(),
      member_id: "owner_conflict_a_member"
    });
    await ctx.db.insert("accounts", {
      id: "owner_conflict_b_auth",
      email: "owner-conflict-b@test.com",
      display_name: "Owner B",
      created_at: Date.now(),
      member_id: "owner_conflict_b_member"
    });
    await ctx.db.insert("expenses", {
      id: "owner_conflict_expense",
      group_id: "owner_conflict_group",
      description: "Conflicting owner tuple",
      date: Date.now(),
      total_amount: 10,
      paid_by_member_id: "owner_conflict_a_member",
      involved_member_ids: ["owner_conflict_a_member"],
      splits: [
        {
          id: "owner_conflict_split",
          member_id: "owner_conflict_a_member",
          amount: 10,
          is_settled: false
        }
      ],
      is_settled: false,
      owner_email: "owner-conflict-b@test.com",
      owner_account_id: "owner_conflict_b_auth",
      owner_id: ownerAId,
      participant_member_ids: ["owner_conflict_a_member"],
      participant_emails: ["owner-conflict-a@test.com"],
      participants: [{ member_id: "owner_conflict_a_member", name: "Owner A" }],
      created_at: Date.now(),
      updated_at: Date.now()
    });
    await ctx.db.insert("user_expenses", {
      user_id: "owner_conflict_a_auth",
      expense_id: "owner_conflict_expense",
      updated_at: Date.now()
    });
  });

  await expect(t.mutation(internal.migrations.backfillParticipantEmails, {})).rejects.toThrow(
    "Expense owner identity is inconsistent"
  );

  const result = await t.run(async (ctx) => {
    const expense = await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "owner_conflict_expense"))
      .unique();
    const visibility = await ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) => q.eq("expense_id", "owner_conflict_expense"))
      .collect();
    return { expense, visibility };
  });
  expect(result.expense?.participant_emails).toEqual(["owner-conflict-a@test.com"]);
  expect(result.visibility.map((row) => row.user_id)).toEqual(["owner_conflict_a_auth"]);
});
