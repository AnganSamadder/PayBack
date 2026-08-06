import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api } from "../_generated/api";
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

async function seedGroupFixture(t: ReturnType<typeof convexTest>, memberCount = 3) {
  return await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: 1
    });
    const memberId = await ctx.db.insert("accounts", {
      id: "member_auth",
      email: "member@test.com",
      display_name: "Member",
      member_id: "member_canonical",
      alias_member_ids: ["member_alias"],
      created_at: 1
    });
    await ctx.db.insert("member_aliases", {
      account_email: "member@test.com",
      canonical_member_id: "member_canonical",
      alias_member_id: "member_alias",
      created_at: 1
    });
    const groupId = await ctx.db.insert("groups", {
      id: "group_member_removal",
      name: "Trip",
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "member_canonical", name: "Member" },
        ...(memberCount > 2 ? [{ id: "remaining_member", name: "Remaining" }] : [])
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      created_at: 1,
      updated_at: 1,
      is_direct: false
    });

    const insertExpense = async (
      id: string,
      paidBy: string,
      involved: string[],
      participantAccountIds: Array<[typeof ownerId | typeof memberId, string]>
    ) => {
      const expenseId = await ctx.db.insert("expenses", {
        id,
        group_id: "group_member_removal",
        group_ref: groupId,
        description: id,
        date: 1,
        total_amount: 20,
        paid_by_member_id: paidBy,
        involved_member_ids: involved,
        splits: involved.map((participant, index) => ({
          id: `${id}_split_${index}`,
          member_id: participant,
          amount: 20 / involved.length,
          is_settled: false
        })),
        is_settled: false,
        owner_email: "owner@test.com",
        owner_account_id: "owner_auth",
        owner_id: ownerId,
        participant_member_ids: involved,
        participant_emails: participantAccountIds.map(([, authId]) => `${authId}@test.com`),
        participants: involved.map((participant) => ({
          member_id: participant,
          name: participant
        })),
        created_at: 1,
        updated_at: 1
      });
      for (const [accountId, authId] of participantAccountIds) {
        await ctx.db.insert("user_expenses", {
          user_id: authId,
          expense_id: id,
          account_ref: accountId,
          expense_ref: expenseId,
          updated_at: 1
        });
      }
    };

    await insertExpense(
      "affected_expense",
      "owner_member",
      ["owner_member", "member_alias"],
      [
        [ownerId, "owner_auth"],
        [memberId, "member_auth"]
      ]
    );
    await insertExpense(
      "retained_expense",
      "owner_member",
      ["owner_member"],
      [[ownerId, "owner_auth"]]
    );
  });
}

describe("groups.removeMemberAndExpenses", () => {
  test("atomically removes an alias-equivalent member and affected expense visibility", async () => {
    const t = convexTest(schema, modules);
    await seedGroupFixture(t);

    const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
    await owner.mutation(api.groups.removeMemberAndExpenses, {
      id: "group_member_removal",
      memberId: "member_alias"
    });

    const result = await t.run(async (ctx) => {
      const group = await ctx.db
        .query("groups")
        .withIndex("by_client_id", (query) => query.eq("id", "group_member_removal"))
        .unique();
      const affectedExpense = await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (query) => query.eq("id", "affected_expense"))
        .unique();
      const retainedExpense = await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (query) => query.eq("id", "retained_expense"))
        .unique();
      const affectedVisibility = await ctx.db
        .query("user_expenses")
        .withIndex("by_expense_id", (query) => query.eq("expense_id", "affected_expense"))
        .collect();
      return { group, affectedExpense, retainedExpense, affectedVisibility };
    });

    expect(result.group?.members.map((member) => member.id)).toEqual([
      "owner_member",
      "remaining_member"
    ]);
    expect(result.affectedExpense).toBeNull();
    expect(result.affectedVisibility).toHaveLength(0);
    expect(result.retainedExpense).not.toBeNull();
  });

  test("rejects a non-owner without changing the group or expenses", async () => {
    const t = convexTest(schema, modules);
    await seedGroupFixture(t);

    const member = t.withIdentity(identity("member@test.com", "member_auth"));
    await expect(
      member.mutation(api.groups.removeMemberAndExpenses, {
        id: "group_member_removal",
        memberId: "owner_member"
      })
    ).rejects.toThrow("Not authorized");

    const result = await t.run(async (ctx) => {
      const group = await ctx.db
        .query("groups")
        .withIndex("by_client_id", (query) => query.eq("id", "group_member_removal"))
        .unique();
      const expenses = await ctx.db
        .query("expenses")
        .withIndex("by_group_id", (query) => query.eq("group_id", "group_member_removal"))
        .collect();
      return { group, expenses };
    });

    expect(result.group?.members).toHaveLength(3);
    expect(result.expenses).toHaveLength(2);
  });

  test("deletes the group and every expense when only the owner would remain", async () => {
    const t = convexTest(schema, modules);
    await seedGroupFixture(t, 2);

    const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
    await owner.mutation(api.groups.removeMemberAndExpenses, {
      id: "group_member_removal",
      memberId: "member_canonical"
    });

    const result = await t.run(async (ctx) => {
      const group = await ctx.db
        .query("groups")
        .withIndex("by_client_id", (query) => query.eq("id", "group_member_removal"))
        .unique();
      const expenses = await ctx.db
        .query("expenses")
        .withIndex("by_group_id", (query) => query.eq("group_id", "group_member_removal"))
        .collect();
      const visibility = await ctx.db.query("user_expenses").collect();
      return { group, expenses, visibility };
    });

    expect(result.group).toBeNull();
    expect(result.expenses).toHaveLength(0);
    expect(result.visibility).toHaveLength(0);
  });
});
