import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

function identity(email: string, subject: string) {
  return {
    subject,
    email,
    name: email.split("@")[0],
    pictureUrl: "http://placeholder.com",
    tokenIdentifier: subject,
    issuer: "http://placeholder.com",
    emailVerified: true,
    updatedAt: "2023-01-01"
  };
}

test("expense debug cleanup removes caller-owned generated data with stale member IDs only", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "owner_subject",
      email: "owner@example.com",
      normalized_email: "owner@example.com",
      display_name: "Owner",
      member_id: "current_owner_member",
      created_at: now
    });
    const foreignId = await ctx.db.insert("accounts", {
      id: "foreign_subject",
      email: "foreign@example.com",
      normalized_email: "foreign@example.com",
      display_name: "Foreign",
      member_id: "foreign_member",
      created_at: now
    });

    const insertExpense = async (args: {
      id: string;
      ownerId: typeof ownerId;
      ownerSubject: string;
      ownerEmail: string;
      payerId: string;
      isDebug: boolean;
    }) => {
      await ctx.db.insert("expenses", {
        id: args.id,
        group_id: `${args.id}_group`,
        context_kind: "group",
        description: args.id,
        date: now,
        total_amount: 20,
        paid_by_member_id: args.payerId,
        involved_member_ids: [args.payerId, "friend_member"],
        splits: [
          { id: `${args.id}_payer_split`, member_id: args.payerId, amount: 10, is_settled: false },
          {
            id: `${args.id}_friend_split`,
            member_id: "friend_member",
            amount: 10,
            is_settled: false
          }
        ],
        is_settled: false,
        owner_email: args.ownerEmail,
        owner_account_id: args.ownerSubject,
        owner_id: args.ownerId,
        participant_member_ids: [args.payerId, "friend_member"],
        participant_emails: [args.ownerEmail],
        participants: [
          { member_id: args.payerId, name: "Owner" },
          { member_id: "friend_member", name: "Friend" }
        ],
        created_at: now,
        updated_at: now,
        is_payback_generated_mock_data: args.isDebug
      });
    };

    await insertExpense({
      id: "owner_generated_stale_identity",
      ownerId,
      ownerSubject: "owner_subject",
      ownerEmail: "owner@example.com",
      payerId: "stale_generated_owner_member",
      isDebug: true
    });
    await insertExpense({
      id: "owner_real_expense",
      ownerId,
      ownerSubject: "owner_subject",
      ownerEmail: "owner@example.com",
      payerId: "current_owner_member",
      isDebug: false
    });
    await insertExpense({
      id: "foreign_generated_expense",
      ownerId: foreignId,
      ownerSubject: "foreign_subject",
      ownerEmail: "foreign@example.com",
      payerId: "foreign_member",
      isDebug: true
    });
  });

  const owner = t.withIdentity(identity("owner@example.com", "owner_subject"));
  await owner.mutation(api.expenses.clearDebugDataForUser, {});

  const remaining = await t.run(async (ctx) =>
    (await ctx.db.query("expenses").collect()).map((expense) => expense.id).sort()
  );
  expect(remaining).toEqual(["foreign_generated_expense", "owner_real_expense"]);
});

test("group debug cleanup removes caller-owned generated data with stale member IDs only", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "owner_subject",
      email: "owner@example.com",
      normalized_email: "owner@example.com",
      display_name: "Owner",
      member_id: "current_owner_member",
      created_at: now
    });
    const foreignId = await ctx.db.insert("accounts", {
      id: "foreign_subject",
      email: "foreign@example.com",
      normalized_email: "foreign@example.com",
      display_name: "Foreign",
      member_id: "foreign_member",
      created_at: now
    });

    const insertGroup = async (args: {
      id: string;
      ownerId: typeof ownerId;
      ownerSubject: string;
      ownerEmail: string;
      memberId: string;
      isDebug: boolean;
    }) => {
      const groupId = await ctx.db.insert("groups", {
        id: args.id,
        name: args.id,
        members: [
          { id: args.memberId, name: "Owner", is_current_user: true },
          { id: "friend_member", name: "Friend" }
        ],
        owner_email: args.ownerEmail,
        owner_account_id: args.ownerSubject,
        owner_id: args.ownerId,
        created_at: now,
        updated_at: now,
        is_payback_generated_mock_data: args.isDebug
      });
      await ctx.db.insert("group_visibility", {
        account_id: args.ownerId,
        group_id: groupId,
        group_updated_at: now,
        created_at: now,
        updated_at: now
      });
    };

    await insertGroup({
      id: "owner_generated_stale_identity",
      ownerId,
      ownerSubject: "owner_subject",
      ownerEmail: "owner@example.com",
      memberId: "stale_generated_owner_member",
      isDebug: true
    });
    await insertGroup({
      id: "owner_real_group",
      ownerId,
      ownerSubject: "owner_subject",
      ownerEmail: "owner@example.com",
      memberId: "current_owner_member",
      isDebug: false
    });
    await insertGroup({
      id: "foreign_generated_group",
      ownerId: foreignId,
      ownerSubject: "foreign_subject",
      ownerEmail: "foreign@example.com",
      memberId: "foreign_member",
      isDebug: true
    });
  });

  const owner = t.withIdentity(identity("owner@example.com", "owner_subject"));
  await owner.mutation(api.groups.clearDebugDataForUser, {});

  const remaining = await t.run(async (ctx) =>
    (await ctx.db.query("groups").collect()).map((group) => group.id).sort()
  );
  expect(remaining).toEqual(["foreign_generated_group", "owner_real_group"]);
});

test("debug cleanup ignores unrelated generated-data cardinality", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  const fixture = await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "bounded_owner_subject",
      email: "bounded-owner@example.com",
      normalized_email: "bounded-owner@example.com",
      display_name: "Owner",
      member_id: "bounded_owner_member",
      created_at: now
    });
    const foreignId = await ctx.db.insert("accounts", {
      id: "bounded_foreign_subject",
      email: "bounded-foreign@example.com",
      normalized_email: "bounded-foreign@example.com",
      display_name: "Foreign",
      member_id: "bounded_foreign_member",
      created_at: now
    });
    return { ownerId, foreignId };
  });

  for (let start = 0; start < 513; start += 50) {
    await t.run(async (ctx) => {
      for (let index = start; index < Math.min(start + 50, 513); index += 1) {
        await ctx.db.insert("groups", {
          id: `foreign_generated_group_${index}`,
          name: "Foreign generated group",
          members: [{ id: "bounded_foreign_member", name: "Foreign" }],
          owner_email: "bounded-foreign@example.com",
          owner_account_id: "bounded_foreign_subject",
          owner_id: fixture.foreignId,
          created_at: now + index,
          updated_at: now + index,
          is_payback_generated_mock_data: true
        });
        await ctx.db.insert("expenses", {
          id: `foreign_generated_expense_${index}`,
          group_id: `foreign_group_${index}`,
          context_kind: "group",
          description: "Foreign generated expense",
          date: now,
          total_amount: 1,
          paid_by_member_id: "bounded_foreign_member",
          involved_member_ids: ["bounded_foreign_member"],
          splits: [
            {
              id: `foreign_split_${index}`,
              member_id: "bounded_foreign_member",
              amount: 1,
              is_settled: false
            }
          ],
          is_settled: false,
          owner_email: "bounded-foreign@example.com",
          owner_account_id: "bounded_foreign_subject",
          owner_id: fixture.foreignId,
          participant_member_ids: ["bounded_foreign_member"],
          participant_emails: ["bounded-foreign@example.com"],
          participants: [{ member_id: "bounded_foreign_member", name: "Foreign" }],
          created_at: now + index,
          updated_at: now + index,
          is_payback_generated_mock_data: true
        });
      }
    });
  }

  await t.run(async (ctx) => {
    const groupId = await ctx.db.insert("groups", {
      id: "bounded_owner_generated_group",
      name: "Owner generated group",
      members: [{ id: "stale_owner_member", name: "Owner" }],
      owner_email: "bounded-owner@example.com",
      owner_account_id: "bounded_owner_subject",
      owner_id: fixture.ownerId,
      created_at: now + 1_000,
      updated_at: now + 1_000,
      is_payback_generated_mock_data: true
    });
    await ctx.db.insert("group_visibility", {
      account_id: fixture.ownerId,
      group_id: groupId,
      group_updated_at: now,
      created_at: now,
      updated_at: now
    });
    await ctx.db.insert("expenses", {
      id: "bounded_owner_generated_expense",
      group_id: "owner_orphan_group",
      context_kind: "group",
      description: "Owner generated expense",
      date: now,
      total_amount: 1,
      paid_by_member_id: "stale_owner_member",
      involved_member_ids: ["stale_owner_member"],
      splits: [
        {
          id: "bounded_owner_split",
          member_id: "stale_owner_member",
          amount: 1,
          is_settled: false
        }
      ],
      is_settled: false,
      owner_email: "bounded-owner@example.com",
      owner_account_id: "bounded_owner_subject",
      owner_id: fixture.ownerId,
      participant_member_ids: ["stale_owner_member"],
      participant_emails: ["bounded-owner@example.com"],
      participants: [{ member_id: "stale_owner_member", name: "Owner" }],
      created_at: now + 1_000,
      updated_at: now + 1_000,
      is_payback_generated_mock_data: true
    });
  });

  const owner = t.withIdentity(identity("bounded-owner@example.com", "bounded_owner_subject"));
  await expect(owner.mutation(api.expenses.clearDebugDataForUser, {})).resolves.toBeNull();
  await expect(owner.mutation(api.groups.clearDebugDataForUser, {})).resolves.toBeNull();

  const ownerArtifacts = await t.run(async (ctx) => ({
    group: await ctx.db
      .query("groups")
      .withIndex("by_client_id", (query) => query.eq("id", "bounded_owner_generated_group"))
      .unique(),
    expense: await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (query) => query.eq("id", "bounded_owner_generated_expense"))
      .unique()
  }));
  expect(ownerArtifacts).toEqual({ group: null, expense: null });
});
