import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api } from "../_generated/api";
import { Id } from "../_generated/dataModel";
import schema from "../schema";
import { modules } from "../test.setup";

function identity(email: string, subject: string) {
  return {
    subject,
    email,
    name: email.split("@")[0],
    pictureUrl: "",
    tokenIdentifier: subject,
    issuer: "",
    emailVerified: true,
    updatedAt: ""
  };
}

async function seedExpenseBatch(t: ReturnType<typeof convexTest>, withGroup: boolean) {
  return await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "runtime_owner_auth",
      email: "runtime-owner@test.com",
      display_name: "Owner",
      member_id: "runtime_owner_member",
      created_at: 1
    });
    const memberId = await ctx.db.insert("accounts", {
      id: "runtime_member_auth",
      email: "runtime-member@test.com",
      display_name: "Member",
      member_id: "runtime_member_member",
      created_at: 1
    });
    const groupId = await ctx.db.insert("groups", {
      id: "runtime_group",
      name: "Runtime",
      members: [
        { id: "runtime_owner_member", name: "Owner" },
        { id: "runtime_member_member", name: "Member" }
      ],
      owner_email: "runtime-owner@test.com",
      owner_account_id: "runtime_owner_auth",
      owner_id: ownerId,
      created_at: 1,
      updated_at: 1
    });
    const expenseIds: Id<"expenses">[] = [];
    for (let index = 0; index < 2; index += 1) {
      const expenseId = await ctx.db.insert("expenses", {
        id: `runtime_expense_${index}`,
        group_id: "runtime_group",
        group_ref: withGroup ? groupId : undefined,
        description: `Expense ${index}`,
        date: 1,
        total_amount: 20,
        paid_by_member_id: "runtime_owner_member",
        involved_member_ids: ["runtime_owner_member", "runtime_member_member"],
        splits: [
          {
            id: `owner_split_${index}`,
            member_id: "runtime_owner_member",
            amount: 10,
            is_settled: false
          },
          {
            id: `member_split_${index}`,
            member_id: "runtime_member_member",
            amount: 10,
            is_settled: false
          }
        ],
        is_settled: false,
        owner_email: "runtime-owner@test.com",
        owner_account_id: "runtime_owner_auth",
        owner_id: ownerId,
        participant_member_ids: ["runtime_owner_member", "runtime_member_member"],
        participant_emails: ["runtime-owner@test.com", "runtime-member@test.com"],
        participants: [
          { member_id: "runtime_owner_member", name: "Owner" },
          { member_id: "runtime_member_member", name: "Member" }
        ],
        created_at: 1,
        updated_at: 1
      });
      expenseIds.push(expenseId);
      for (const [accountId, authId] of [
        [ownerId, "runtime_owner_auth"],
        [memberId, "runtime_member_auth"]
      ] as const) {
        await ctx.db.insert("user_expenses", {
          user_id: authId,
          expense_id: `runtime_expense_${index}`,
          account_ref: accountId,
          expense_ref: expenseId,
          updated_at: 1
        });
      }
    }
    return { ownerId, memberId, groupId, expenseIds };
  });
}

async function seedRuntimeAccountsAndGroup(t: ReturnType<typeof convexTest>) {
  return await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "runtime_owner_auth",
      email: "runtime-owner@test.com",
      display_name: "Owner",
      member_id: "runtime_owner_member",
      created_at: 1
    });
    const memberId = await ctx.db.insert("accounts", {
      id: "runtime_member_auth",
      email: "runtime-member@test.com",
      display_name: "Member",
      member_id: "runtime_member_member",
      created_at: 1
    });
    const groupId = await ctx.db.insert("groups", {
      id: "runtime_group",
      name: "Runtime",
      members: [
        { id: "runtime_owner_member", name: "Owner", is_current_user: true },
        { id: "runtime_member_member", name: "Member" }
      ],
      owner_email: "runtime-owner@test.com",
      owner_account_id: "runtime_owner_auth",
      owner_id: ownerId,
      created_at: 1,
      updated_at: 1
    });
    return { ownerId, memberId, groupId };
  });
}

function runtimeExpenseArgs(description = "Runtime expense") {
  return {
    id: "runtime_created_expense",
    context_kind: "group" as const,
    group_id: "runtime_group",
    description,
    date: 1,
    total_amount: 20,
    paid_by_member_id: "runtime_owner_member",
    involved_member_ids: ["runtime_owner_member", "runtime_member_member"],
    splits: [
      {
        id: "runtime_owner_split",
        member_id: "runtime_owner_member",
        amount: 10,
        is_settled: false
      },
      {
        id: "runtime_member_split",
        member_id: "runtime_member_member",
        amount: 10,
        is_settled: false
      }
    ],
    is_settled: false,
    participant_member_ids: ["runtime_owner_member", "runtime_member_member"],
    participants: [
      { member_id: "runtime_owner_member", name: "Owner" },
      { member_id: "runtime_member_member", name: "Member" }
    ]
  };
}

describe("runtime expense writes", () => {
  test("create and update keep canonical visibility references", async () => {
    const t = convexTest(schema, modules);
    const fixture = await seedRuntimeAccountsAndGroup(t);
    const owner = t.withIdentity(identity("runtime-owner@test.com", "runtime_owner_auth"));

    const expenseId = await owner.mutation(api.expenses.create, runtimeExpenseArgs());

    let result = await t.run(async (ctx) => ({
      expense: await ctx.db.get(expenseId),
      visibility: await ctx.db.query("user_expenses").collect(),
      revisions: await ctx.db.query("account_sync_state").collect()
    }));
    expect(result.expense?.description).toBe("Runtime expense");
    expect(result.visibility).toHaveLength(2);
    expect(
      result.visibility.map((row) => ({
        accountRef: row.account_ref,
        expenseRef: row.expense_ref,
        expenseId: row.expense_id
      }))
    ).toEqual(
      expect.arrayContaining([
        {
          accountRef: fixture.ownerId,
          expenseRef: expenseId,
          expenseId: "runtime_created_expense"
        },
        {
          accountRef: fixture.memberId,
          expenseRef: expenseId,
          expenseId: "runtime_created_expense"
        }
      ])
    );
    expect(
      Object.fromEntries(result.revisions.map((row) => [row.account_id, row.expenses_revision]))
    ).toEqual({ [fixture.ownerId]: 1, [fixture.memberId]: 1 });

    await owner.mutation(api.expenses.create, runtimeExpenseArgs("Updated runtime expense"));

    result = await t.run(async (ctx) => ({
      expense: await ctx.db.get(expenseId),
      visibility: await ctx.db.query("user_expenses").collect(),
      revisions: await ctx.db.query("account_sync_state").collect()
    }));
    expect(result.expense?.description).toBe("Updated runtime expense");
    expect(result.visibility).toHaveLength(2);
    expect(result.visibility.every((row) => row.expense_ref === expenseId)).toBe(true);
    expect(
      Object.fromEntries(result.revisions.map((row) => [row.account_id, row.expenses_revision]))
    ).toEqual({ [fixture.ownerId]: 2, [fixture.memberId]: 2 });
  });

  test("settlement updates bump every active viewer revision once", async () => {
    const t = convexTest(schema, modules);
    const fixture = await seedExpenseBatch(t, false);

    await t
      .withIdentity(identity("runtime-owner@test.com", "runtime_owner_auth"))
      .mutation(api.expenses.setSettlementState, {
        expenseId: "runtime_expense_0",
        memberIds: ["runtime_member_member"],
        settled: true
      });

    const result = await t.run(async (ctx) => ({
      expense: await ctx.db.get(fixture.expenseIds[0]),
      revisions: await ctx.db.query("account_sync_state").collect()
    }));
    expect(
      result.expense?.splits.find((split) => split.member_id === "runtime_member_member")
        ?.is_settled
    ).toBe(true);
    expect(
      Object.fromEntries(result.revisions.map((row) => [row.account_id, row.expenses_revision]))
    ).toEqual({ [fixture.ownerId]: 1, [fixture.memberId]: 1 });
  });

  test("multi-delete bumps each viewer revision once", async () => {
    const t = convexTest(schema, modules);
    const fixture = await seedExpenseBatch(t, false);

    await t
      .withIdentity(identity("runtime-owner@test.com", "runtime_owner_auth"))
      .mutation(api.expenses.deleteExpenses, {
        ids: ["runtime_expense_0", "runtime_expense_1"]
      });

    const result = await t.run(async (ctx) => ({
      expenses: await ctx.db.query("expenses").collect(),
      visibility: await ctx.db.query("user_expenses").collect(),
      revisions: await ctx.db.query("account_sync_state").collect()
    }));
    expect(result.expenses).toEqual([]);
    expect(result.visibility).toEqual([]);
    expect(
      Object.fromEntries(result.revisions.map((row) => [row.account_id, row.expenses_revision]))
    ).toEqual({ [fixture.ownerId]: 1, [fixture.memberId]: 1 });
  });

  test("group cascades batch expense revisions across the whole group", async () => {
    const t = convexTest(schema, modules);
    const fixture = await seedExpenseBatch(t, true);

    await t
      .withIdentity(identity("runtime-owner@test.com", "runtime_owner_auth"))
      .mutation(api.groups.deleteGroup, { id: "runtime_group" });

    const result = await t.run(async (ctx) => ({
      group: await ctx.db.get(fixture.groupId),
      expenses: await ctx.db.query("expenses").collect(),
      revisions: await ctx.db.query("account_sync_state").collect()
    }));
    expect(result.group).toBeNull();
    expect(result.expenses).toEqual([]);
    expect(
      Object.fromEntries(result.revisions.map((row) => [row.account_id, row.expenses_revision]))
    ).toEqual({ [fixture.ownerId]: 1, [fixture.memberId]: 1 });
  });

  test("multi-group cascades batch expense and group revisions once per viewer", async () => {
    const t = convexTest(schema, modules);
    const fixture = await seedExpenseBatch(t, true);
    const secondGroupId = await t.run(async (ctx) => {
      const groupId = await ctx.db.insert("groups", {
        id: "runtime_group_2",
        name: "Runtime 2",
        members: [
          { id: "runtime_owner_member", name: "Owner" },
          { id: "runtime_member_member", name: "Member" }
        ],
        owner_email: "runtime-owner@test.com",
        owner_account_id: "runtime_owner_auth",
        owner_id: fixture.ownerId,
        created_at: 1,
        updated_at: 1
      });
      await ctx.db.patch(fixture.expenseIds[1], {
        group_id: "runtime_group_2",
        group_ref: groupId
      });
      return groupId;
    });

    await t
      .withIdentity(identity("runtime-owner@test.com", "runtime_owner_auth"))
      .mutation(api.groups.deleteGroups, { ids: ["runtime_group", "runtime_group_2"] });

    const result = await t.run(async (ctx) => ({
      firstGroup: await ctx.db.get(fixture.groupId),
      secondGroup: await ctx.db.get(secondGroupId),
      expenses: await ctx.db.query("expenses").collect(),
      revisions: await ctx.db.query("account_sync_state").collect()
    }));
    expect(result.firstGroup).toBeNull();
    expect(result.secondGroup).toBeNull();
    expect(result.expenses).toEqual([]);
    expect(
      Object.fromEntries(
        result.revisions.map((row) => [
          row.account_id,
          { expenses: row.expenses_revision, groups: row.groups_revision }
        ])
      )
    ).toEqual({
      [fixture.ownerId]: { expenses: 1, groups: 1 },
      [fixture.memberId]: { expenses: 1, groups: 1 }
    });
  });

  test("oversized delete and participant arrays fail before expense writes", async () => {
    const t = convexTest(schema, modules);
    await t.run((ctx) =>
      ctx.db.insert("accounts", {
        id: "runtime_owner_auth",
        email: "runtime-owner@test.com",
        display_name: "Owner",
        member_id: "runtime_owner_member",
        created_at: 1
      })
    );
    const owner = t.withIdentity(identity("runtime-owner@test.com", "runtime_owner_auth"));

    await expect(
      owner.mutation(api.expenses.deleteExpenses, {
        ids: Array.from({ length: 513 }, (_, index) => `expense_${index}`)
      })
    ).rejects.toThrow("at most 512 IDs");
    await expect(
      owner.mutation(api.groups.deleteGroups, {
        ids: Array.from({ length: 513 }, (_, index) => `group_${index}`)
      })
    ).rejects.toThrow("at most 512 IDs");

    const memberIds = Array.from({ length: 66 }, (_, index) => `member_${index}`);
    await expect(
      owner.mutation(api.expenses.create, {
        id: "oversized_expense",
        context_kind: "grouped_individual",
        group_id: "",
        description: "Oversized",
        date: 1,
        total_amount: 66,
        paid_by_member_id: memberIds[0],
        involved_member_ids: memberIds,
        splits: memberIds.map((memberId, index) => ({
          id: `split_${index}`,
          member_id: memberId,
          amount: 1,
          is_settled: false
        })),
        is_settled: false,
        participant_member_ids: memberIds,
        participants: memberIds.map((memberId) => ({ member_id: memberId, name: memberId }))
      })
    ).rejects.toThrow("at most 65 participants");
    expect(await t.run((ctx) => ctx.db.query("expenses").collect())).toEqual([]);
  });

  test("oversized clear-all completes in bounded resumable batches", async () => {
    const t = convexTest(schema, modules);
    const ownerId = await t.run((ctx) =>
      ctx.db.insert("accounts", {
        id: "runtime_owner_auth",
        email: "runtime-owner@test.com",
        display_name: "Owner",
        member_id: "runtime_owner_member",
        created_at: 1
      })
    );
    for (let start = 0; start < 513; start += 100) {
      await t.run(async (ctx) => {
        for (let index = start; index < Math.min(start + 100, 513); index += 1) {
          await ctx.db.insert("expenses", {
            id: `clear_all_expense_${index}`,
            group_id: "",
            context_kind: "grouped_individual",
            description: "Clear all bound",
            date: 1,
            total_amount: 1,
            paid_by_member_id: "runtime_owner_member",
            involved_member_ids: ["runtime_owner_member"],
            splits: [
              {
                id: `clear_all_split_${index}`,
                member_id: "runtime_owner_member",
                amount: 1,
                is_settled: false
              }
            ],
            is_settled: false,
            owner_email: "runtime-owner@test.com",
            owner_account_id: "runtime_owner_auth",
            owner_id: ownerId,
            participant_member_ids: ["runtime_owner_member"],
            participant_emails: ["runtime-owner@test.com"],
            participants: [{ member_id: "runtime_owner_member", name: "Owner" }],
            created_at: 1,
            updated_at: 1
          });
        }
      });
    }

    const owner = t.withIdentity(identity("runtime-owner@test.com", "runtime_owner_auth"));
    let result = await owner.mutation(api.expenses.clearAllForUserV2, {});
    for (let attempt = 0; result.inProgress && attempt < 520; attempt += 1) {
      result = await owner.mutation(api.expenses.clearAllForUserV2, {
        cutoff: result.cutoff
      });
    }
    expect(result.inProgress).toBe(false);

    const state = await t.run(async (ctx) => ({
      expenses: await ctx.db.query("expenses").collect(),
      revisions: await ctx.db.query("account_sync_state").collect()
    }));
    expect(state.expenses).toHaveLength(0);
    expect(state.revisions).toEqual([]);
  });
});
