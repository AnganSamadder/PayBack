import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api, internal } from "../_generated/api";
import type { Doc, Id } from "../_generated/dataModel";
import { rewriteClaimedFriendReferences } from "../aliases";
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

function expenseValue(
  id: string,
  owner: Doc<"accounts">,
  participantMemberId: string,
  participantEmail?: string
): Omit<Doc<"expenses">, "_id" | "_creationTime"> {
  return {
    id,
    group_id: "",
    context_kind: "grouped_individual",
    description: id,
    date: 1,
    total_amount: 10,
    paid_by_member_id: owner.member_id!,
    involved_member_ids: [owner.member_id!, participantMemberId],
    splits: [
      { id: `${id}_owner`, member_id: owner.member_id!, amount: 5, is_settled: false },
      { id: `${id}_participant`, member_id: participantMemberId, amount: 5, is_settled: false }
    ],
    is_settled: false,
    owner_email: owner.email,
    owner_account_id: owner.id,
    owner_id: owner._id,
    participant_member_ids: [owner.member_id!, participantMemberId],
    participant_emails: [owner.email, ...(participantEmail ? [participantEmail] : [])],
    participants: [
      { member_id: owner.member_id!, name: "Owner" },
      {
        member_id: participantMemberId,
        name: "Participant",
        ...(participantEmail ? { linked_account_email: participantEmail } : {})
      }
    ],
    created_at: 1,
    updated_at: 1
  };
}

describe("legacy expense runtime routing", () => {
  test("bulk import creates canonical visibility refs and bumps one revision for the batch", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "import_owner_auth",
        email: "import-owner@test.com",
        display_name: "Import Owner",
        member_id: "import_owner_member",
        created_at: 1
      });
      await ctx.db.insert("identity_materialization_state", {
        key: "member_identity_v3",
        status: "ready",
        phase: "complete",
        updated_at: 1
      });
      const groupId = await ctx.db.insert("groups", {
        id: "import_group",
        name: "Import Group",
        members: [{ id: "import_owner_member", name: "Import Owner" }],
        owner_email: "import-owner@test.com",
        owner_account_id: "import_owner_auth",
        owner_id: ownerId,
        created_at: 1,
        updated_at: 1
      });
      return { ownerId, groupId };
    });

    const importExpense = (id: string) => ({
      id,
      group_id: "import_group",
      description: id,
      date: 1,
      total_amount: 1,
      paid_by_member_id: "import_owner_member",
      involved_member_ids: ["import_owner_member"],
      splits: [
        { id: `${id}_split`, member_id: "import_owner_member", amount: 1, is_settled: false }
      ],
      is_settled: false,
      participant_member_ids: ["import_owner_member"],
      participants: [{ member_id: "import_owner_member", name: "Import Owner" }]
    });
    await t
      .withIdentity(identity("import-owner@test.com", "import_owner_auth"))
      .mutation(api.bulkImport.bulkImport, {
        friends: [],
        groups: [],
        expenses: [importExpense("import_expense_1"), importExpense("import_expense_2")]
      });

    const result = await t.run(async (ctx) => ({
      expenses: await ctx.db.query("expenses").collect(),
      visibility: await ctx.db.query("user_expenses").collect(),
      revisions: await ctx.db.query("account_sync_state").collect()
    }));
    expect(result.expenses).toHaveLength(2);
    expect(result.expenses.every((expense) => expense.group_ref === fixture.groupId)).toBe(true);
    expect(result.visibility).toHaveLength(2);
    expect(result.visibility.every((row) => row.account_ref === fixture.ownerId)).toBe(true);
    expect(
      result.visibility.every((row) =>
        result.expenses.some(
          (expense) => row.expense_ref === expense._id && row.expense_id === expense.id
        )
      )
    ).toBe(true);
    expect(result.revisions).toEqual([
      expect.objectContaining({ account_id: fixture.ownerId, expenses_revision: 1 })
    ]);
  });

  test("claimed-friend rewrites batch expense revisions and canonical visibility refs", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "rewrite_owner_auth",
        email: "rewrite-owner@test.com",
        display_name: "Rewrite Owner",
        member_id: "rewrite_owner_member",
        created_at: 1
      });
      const claimantId = await ctx.db.insert("accounts", {
        id: "rewrite_claimant_auth",
        email: "rewrite-claimant@test.com",
        display_name: "Rewrite Claimant",
        member_id: "rewrite_claimant_member",
        created_at: 1
      });
      const owner = (await ctx.db.get(ownerId))!;
      const expenseIds: Id<"expenses">[] = [];
      for (let index = 0; index < 2; index += 1) {
        const expenseId = await ctx.db.insert(
          "expenses",
          expenseValue(
            `rewrite_expense_${index}`,
            owner,
            "rewrite_source_member",
            "rewrite-claimant@test.com"
          )
        );
        expenseIds.push(expenseId);
        await ctx.db.insert("user_expenses", {
          user_id: owner.id,
          expense_id: `rewrite_expense_${index}`,
          updated_at: 1
        });
      }
      await rewriteClaimedFriendReferences(ctx, owner, "rewrite_source_member", {
        id: "rewrite_claimant_auth",
        email: "rewrite-claimant@test.com",
        display_name: "Rewrite Claimant",
        member_id: "rewrite_claimant_member"
      });
      return { ownerId, claimantId, expenseIds };
    });

    const result = await t.run(async (ctx) => ({
      expenses: await ctx.db.query("expenses").collect(),
      visibility: await ctx.db.query("user_expenses").collect(),
      revisions: await ctx.db.query("account_sync_state").collect()
    }));
    expect(
      result.expenses.every((expense) =>
        expense.participant_member_ids.includes("rewrite_claimant_member")
      )
    ).toBe(true);
    expect(result.visibility).toHaveLength(4);
    expect(result.visibility.every((row) => row.account_ref && row.expense_ref)).toBe(true);
    expect(
      Object.fromEntries(result.revisions.map((row) => [row.account_id, row.expenses_revision]))
    ).toEqual({ [fixture.ownerId]: 1, [fixture.claimantId]: 1 });
  });

  test("claimed-friend rewrites remove deleting accounts from expense visibility", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "active_owner_auth",
        email: "active-owner@test.com",
        display_name: "Active Owner",
        member_id: "active_owner_member",
        created_at: 1
      });
      const claimantId = await ctx.db.insert("accounts", {
        id: "deleting_claimant_auth",
        email: "deleting-claimant@test.com",
        display_name: "Deleting Claimant",
        member_id: "deleting_claimant_member",
        status: "deleting",
        created_at: 1
      });
      const owner = (await ctx.db.get(ownerId))!;
      const expenseId = await ctx.db.insert(
        "expenses",
        expenseValue(
          "deleting_rewrite_expense",
          owner,
          "deleting_source_member",
          "deleting-claimant@test.com"
        )
      );
      for (const userId of ["active_owner_auth", "deleting_claimant_auth"]) {
        await ctx.db.insert("user_expenses", {
          user_id: userId,
          expense_id: "deleting_rewrite_expense",
          updated_at: 1
        });
      }
      await rewriteClaimedFriendReferences(ctx, owner, "deleting_source_member", {
        id: "deleting_claimant_auth",
        email: "deleting-claimant@test.com",
        display_name: "Deleting Claimant",
        member_id: "deleting_claimant_member"
      });
      return { ownerId, claimantId, expenseId };
    });

    const result = await t.run(async (ctx) => ({
      visibility: await ctx.db.query("user_expenses").collect(),
      revisions: await ctx.db.query("account_sync_state").collect()
    }));
    expect(result.visibility).toEqual([
      expect.objectContaining({
        user_id: "active_owner_auth",
        account_ref: fixture.ownerId,
        expense_ref: fixture.expenseId
      })
    ]);
    expect(result.revisions).toEqual([
      expect.objectContaining({ account_id: fixture.ownerId, expenses_revision: 1 })
    ]);
    expect(result.revisions.some((row) => row.account_id === fixture.claimantId)).toBe(false);
  });

  test("claimed-friend rewrites fail closed and roll back groups for duplicate expense IDs", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "duplicate_owner_auth",
        email: "duplicate-owner@test.com",
        display_name: "Duplicate Owner",
        member_id: "duplicate_owner_member",
        created_at: 1
      });
      await ctx.db.insert("accounts", {
        id: "duplicate_claimant_auth",
        email: "duplicate-claimant@test.com",
        display_name: "Duplicate Claimant",
        member_id: "duplicate_claimant_member",
        created_at: 1
      });
      const owner = (await ctx.db.get(ownerId))!;
      const groupId = await ctx.db.insert("groups", {
        id: "duplicate_group",
        name: "Duplicate Group",
        members: [
          { id: "duplicate_owner_member", name: "Owner" },
          { id: "duplicate_source_member", name: "Source" }
        ],
        owner_email: owner.email,
        owner_account_id: owner.id,
        owner_id: owner._id,
        created_at: 1,
        updated_at: 1
      });
      for (let index = 0; index < 2; index += 1) {
        await ctx.db.insert(
          "expenses",
          expenseValue(
            "duplicate_expense",
            owner,
            "duplicate_source_member",
            "duplicate-claimant@test.com"
          )
        );
      }
      return { owner, groupId };
    });

    await expect(
      t.run((ctx) =>
        rewriteClaimedFriendReferences(ctx, fixture.owner, "duplicate_source_member", {
          id: "duplicate_claimant_auth",
          email: "duplicate-claimant@test.com",
          display_name: "Duplicate Claimant",
          member_id: "duplicate_claimant_member"
        })
      )
    ).rejects.toThrow("appears more than once in a batch");

    const result = await t.run(async (ctx) => ({
      group: await ctx.db.get(fixture.groupId),
      expenses: await ctx.db.query("expenses").collect(),
      revisions: await ctx.db.query("account_sync_state").collect()
    }));
    expect(result.group?.members.map((member) => member.id)).toContain("duplicate_source_member");
    expect(
      result.expenses.every((expense) =>
        expense.participant_member_ids.includes("duplicate_source_member")
      )
    ).toBe(true);
    expect(result.revisions).toEqual([]);
  });

  test("alias repair routes name-only patches through canonical visibility and revisions", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "repair_owner_auth",
        email: "user@example.com",
        display_name: "Repair Owner",
        member_id: "repair_owner_member",
        created_at: 1
      });
      const owner = (await ctx.db.get(ownerId))!;
      await ctx.db.insert("account_friends", {
        account_email: owner.email,
        member_id: "repair_friend_member",
        name: "Example User",
        profile_avatar_color: "#123456",
        has_linked_account: false,
        updated_at: 1
      });
      const expenseId = await ctx.db.insert(
        "expenses",
        expenseValue("repair_expense", owner, "repair_friend_member", "deleted:user@example.com")
      );
      await ctx.db.insert("user_expenses", {
        user_id: owner.id,
        expense_id: "repair_expense",
        updated_at: 1
      });
      return { ownerId, expenseId };
    });

    await t.mutation(internal.fix_alias.repairAlias, {});

    const result = await t.run(async (ctx) => ({
      expense: await ctx.db.get(fixture.expenseId),
      visibility: await ctx.db.query("user_expenses").collect(),
      revisions: await ctx.db.query("account_sync_state").collect()
    }));
    expect(
      result.expense?.participants.find(
        (participant) => participant.member_id === "repair_friend_member"
      )?.name
    ).toBe("Example User");
    expect(result.visibility).toEqual([
      expect.objectContaining({
        user_id: "repair_owner_auth",
        account_ref: fixture.ownerId,
        expense_ref: fixture.expenseId
      })
    ]);
    expect(result.revisions).toEqual([
      expect.objectContaining({ account_id: fixture.ownerId, expenses_revision: 1 })
    ]);
  });
});
