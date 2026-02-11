import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";

function identityFor(email: string, subject: string) {
  return {
    subject,
    email,
    name: subject,
    pictureUrl: "http://placeholder.com",
    tokenIdentifier: subject,
    issuer: "http://placeholder.com",
    emailVerified: true,
    updatedAt: "2023-01-01",
  };
}

function buildDirectExpenseArgs(args: {
  expenseId: string;
  groupId: string;
  ownerMemberId: string;
  otherMemberId: string;
}) {
  return {
    id: args.expenseId,
    group_id: args.groupId,
    description: "Direct test expense",
    date: Date.now(),
    total_amount: 20,
    paid_by_member_id: args.ownerMemberId,
    involved_member_ids: [args.ownerMemberId, args.otherMemberId],
    splits: [
      {
        id: `${args.expenseId}_split_owner`,
        member_id: args.ownerMemberId,
        amount: 10,
        is_settled: false,
      },
      {
        id: `${args.expenseId}_split_other`,
        member_id: args.otherMemberId,
        amount: 10,
        is_settled: false,
      },
    ],
    is_settled: false,
    participant_member_ids: [args.ownerMemberId, args.otherMemberId],
    participants: [
      { member_id: args.ownerMemberId, name: "Owner" },
      { member_id: args.otherMemberId, name: "Friend" },
    ],
  };
}

test("expenses:create allows direct expense when involved member is an alias of a linked friend", async () => {
  const t = convexTest(schema);
  const now = Date.now();

  const ownerDocId = await t.run(async (ctx) => {
    return await ctx.db.insert("accounts", {
      id: "owner_auth_id",
      email: "owner@example.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: now,
    });
  });

  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "friend_auth_id",
      email: "friend@example.com",
      display_name: "Friend",
      member_id: "friend_canonical",
      created_at: now,
    });
    await ctx.db.insert("member_aliases", {
      canonical_member_id: "friend_canonical",
      alias_member_id: "friend_alias",
      account_email: "owner@example.com",
      created_at: now,
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "friend_canonical",
      name: "Friend",
      profile_avatar_color: "#000000",
      has_linked_account: true,
      linked_account_id: "friend_auth_id",
      linked_account_email: "friend@example.com",
      status: "accepted",
      updated_at: now,
    });
    await ctx.db.insert("groups", {
      id: "direct_group_alias",
      name: "Owner + Friend",
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "friend_alias", name: "Friend" },
      ],
      owner_email: "owner@example.com",
      owner_account_id: "owner_auth_id",
      owner_id: ownerDocId,
      is_direct: true,
      created_at: now,
      updated_at: now,
    });
  });

  const ownerCtx = t.withIdentity(identityFor("owner@example.com", "owner_auth_id"));

  const result = await ownerCtx.mutation(
    api.expenses.create,
    buildDirectExpenseArgs({
      expenseId: "direct_expense_alias",
      groupId: "direct_group_alias",
      ownerMemberId: "owner_member",
      otherMemberId: "friend_alias",
    })
  );

  expect(result).toBeDefined();
  const expenses = await t.run(async (ctx) => await ctx.db.query("expenses").collect());
  expect(expenses.length).toBe(1);
});

test("expenses:create allows direct expense for legacy friend rows without explicit status", async () => {
  const t = convexTest(schema);
  const now = Date.now();

  const ownerDocId = await t.run(async (ctx) => {
    return await ctx.db.insert("accounts", {
      id: "owner_auth_id",
      email: "owner@example.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: now,
    });
  });

  await t.run(async (ctx) => {
    await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "legacy_friend_member",
      name: "Legacy Friend",
      profile_avatar_color: "#111111",
      has_linked_account: false,
      updated_at: now,
    });
    await ctx.db.insert("groups", {
      id: "direct_group_legacy",
      name: "Owner + Legacy",
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "legacy_friend_member", name: "Legacy Friend" },
      ],
      owner_email: "owner@example.com",
      owner_account_id: "owner_auth_id",
      owner_id: ownerDocId,
      is_direct: true,
      created_at: now,
      updated_at: now,
    });
  });

  const ownerCtx = t.withIdentity(identityFor("owner@example.com", "owner_auth_id"));

  const result = await ownerCtx.mutation(
    api.expenses.create,
    buildDirectExpenseArgs({
      expenseId: "direct_expense_legacy",
      groupId: "direct_group_legacy",
      ownerMemberId: "owner_member",
      otherMemberId: "legacy_friend_member",
    })
  );

  expect(result).toBeDefined();
  const expenses = await t.run(async (ctx) => await ctx.db.query("expenses").collect());
  expect(expenses.length).toBe(1);
});

test("expenses:create allows direct expense when friend is linked via linked_member_id fallback", async () => {
  const t = convexTest(schema);
  const now = Date.now();

  const ownerDocId = await t.run(async (ctx) => {
    return await ctx.db.insert("accounts", {
      id: "owner_auth_id",
      email: "owner@example.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: now,
    });
  });

  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "friend_auth_id",
      email: "friend@example.com",
      display_name: "Friend",
      member_id: "friend_canonical",
      created_at: now,
    });
    // Legacy friend row still keyed by old member_id, but linked_member_id points to canonical identity.
    await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "friend_legacy_member",
      linked_member_id: "friend_canonical",
      name: "Friend",
      profile_avatar_color: "#123456",
      has_linked_account: true,
      linked_account_id: "friend_auth_id",
      linked_account_email: "friend@example.com",
      status: "accepted",
      updated_at: now,
    });
    await ctx.db.insert("groups", {
      id: "direct_group_linked_member",
      name: "Owner + Friend",
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "friend_canonical", name: "Friend" },
      ],
      owner_email: "owner@example.com",
      owner_account_id: "owner_auth_id",
      owner_id: ownerDocId,
      is_direct: true,
      created_at: now,
      updated_at: now,
    });
  });

  const ownerCtx = t.withIdentity(identityFor("owner@example.com", "owner_auth_id"));

  const result = await ownerCtx.mutation(
    api.expenses.create,
    buildDirectExpenseArgs({
      expenseId: "direct_expense_linked_member",
      groupId: "direct_group_linked_member",
      ownerMemberId: "owner_member",
      otherMemberId: "friend_canonical",
    })
  );

  expect(result).toBeDefined();
  const expenses = await t.run(async (ctx) => await ctx.db.query("expenses").collect());
  expect(expenses.length).toBe(1);
});

test("expenses:create allows direct expense when linked account carries legacy alias_member_ids", async () => {
  const t = convexTest(schema);
  const now = Date.now();

  const ownerDocId = await t.run(async (ctx) => {
    return await ctx.db.insert("accounts", {
      id: "owner_auth_id",
      email: "owner@example.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: now,
    });
  });

  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "friend_auth_id",
      email: "friend@example.com",
      display_name: "Friend",
      member_id: "friend_canonical",
      alias_member_ids: ["friend_legacy_member"],
      created_at: now,
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "friend_canonical",
      name: "Friend",
      profile_avatar_color: "#123456",
      has_linked_account: true,
      linked_account_id: "friend_auth_id",
      linked_account_email: "friend@example.com",
      status: "accepted",
      updated_at: now,
    });
    await ctx.db.insert("groups", {
      id: "direct_group_linked_aliases",
      name: "Owner + Friend",
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "friend_legacy_member", name: "Friend" },
      ],
      owner_email: "owner@example.com",
      owner_account_id: "owner_auth_id",
      owner_id: ownerDocId,
      is_direct: true,
      created_at: now,
      updated_at: now,
    });
  });

  const ownerCtx = t.withIdentity(identityFor("owner@example.com", "owner_auth_id"));

  const result = await ownerCtx.mutation(
    api.expenses.create,
    buildDirectExpenseArgs({
      expenseId: "direct_expense_linked_aliases",
      groupId: "direct_group_linked_aliases",
      ownerMemberId: "owner_member",
      otherMemberId: "friend_legacy_member",
    })
  );

  expect(result).toBeDefined();
  const expenses = await t.run(async (ctx) => await ctx.db.query("expenses").collect());
  expect(expenses.length).toBe(1);
});

test("expenses:create rejects direct expense when involved member is not a friend", async () => {
  const t = convexTest(schema);
  const now = Date.now();

  const ownerDocId = await t.run(async (ctx) => {
    return await ctx.db.insert("accounts", {
      id: "owner_auth_id",
      email: "owner@example.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: now,
    });
  });

  await t.run(async (ctx) => {
    await ctx.db.insert("groups", {
      id: "direct_group_unrelated",
      name: "Owner + Stranger",
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "stranger_member", name: "Stranger" },
      ],
      owner_email: "owner@example.com",
      owner_account_id: "owner_auth_id",
      owner_id: ownerDocId,
      is_direct: true,
      created_at: now,
      updated_at: now,
    });
  });

  const ownerCtx = t.withIdentity(identityFor("owner@example.com", "owner_auth_id"));

  await expect(
    ownerCtx.mutation(
      api.expenses.create,
      buildDirectExpenseArgs({
        expenseId: "direct_expense_unrelated",
        groupId: "direct_group_unrelated",
        ownerMemberId: "owner_member",
        otherMemberId: "stranger_member",
      })
    )
  ).rejects.toThrow("not a confirmed friend");
});
