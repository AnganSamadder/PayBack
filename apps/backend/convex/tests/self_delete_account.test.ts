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

test("self deletion rejects conflicting group owner fields before destructive writes", async () => {
  const t = convexTest(schema, modules);

  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: Date.now()
    });
    const otherId = await ctx.db.insert("accounts", {
      id: "other_auth",
      email: "other@test.com",
      display_name: "Other",
      member_id: "other_member",
      created_at: Date.now()
    });
    await ctx.db.insert("groups", {
      id: "conflicting_owner_group",
      name: "Conflicting owner",
      members: [
        { id: "owner_member", name: "Owner" },
        { id: "other_member", name: "Other" }
      ],
      owner_id: otherId,
      owner_account_id: "owner_auth",
      owner_email: "owner@test.com",
      created_at: Date.now(),
      updated_at: Date.now()
    });
    await ctx.db.insert("account_friends", {
      account_email: "other@test.com",
      member_id: "owner_member",
      name: "Owner",
      profile_avatar_color: "#123456",
      has_linked_account: true,
      linked_account_id: "owner_auth",
      linked_account_email: "owner@test.com",
      linked_member_id: "owner_member",
      updated_at: Date.now()
    });

    expect(ownerId).toBeDefined();
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  let conflict: unknown;
  for (let attempt = 0; attempt < 8 && conflict === undefined; attempt += 1) {
    try {
      const result = await owner.mutation(api.cleanup.selfDeleteAccount, {});
      expect(result).toMatchObject({ success: false, inProgress: true, state: "deleting" });
    } catch (error) {
      conflict = error;
    }
  }
  expect(String(conflict)).toContain("conflicting owner identity");

  const state = await t.run(async (ctx) => ({
    account: await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", "owner_auth"))
      .unique(),
    group: await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "conflicting_owner_group"))
      .unique(),
    linkedFriend: await ctx.db
      .query("account_friends")
      .withIndex("by_linked_account_id", (q) => q.eq("linked_account_id", "owner_auth"))
      .unique(),
    receipt: await ctx.db
      .query("account_deletion_receipts")
      .withIndex("by_auth_subject", (q) => q.eq("auth_subject", "owner_auth"))
      .unique()
  }));
  expect(state.account).toMatchObject({ email: "owner@test.com" });
  expect(state.account?.status).toBeUndefined();
  expect(state.group).not.toBeNull();
  expect(state.linkedFriend).toMatchObject({ has_linked_account: true });
  expect(state.receipt).toBeNull();
});

test("self deletion advances one bounded batch and withholds its receipt until completion", async () => {
  const t = convexTest(schema, modules);

  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: Date.now()
    });
    for (let index = 0; index < 40; index += 1) {
      await ctx.db.insert("account_friends", {
        account_email: `friend-${index}@test.com`,
        member_id: `owner_member_${index}`,
        name: "Owner",
        profile_avatar_color: "#123456",
        has_linked_account: true,
        linked_account_id: "owner_auth",
        linked_account_email: "owner@test.com",
        linked_member_id: "owner_member",
        updated_at: Date.now()
      });
    }
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  const first = await owner.mutation(api.cleanup.selfDeleteAccount, {});
  expect(first).toMatchObject({
    success: false,
    inProgress: true,
    state: "deleting",
    expensesPreserved: false
  });
  expect(first.processedCount).toBeGreaterThan(0);
  expect(first.progressToken).toEqual(expect.any(String));

  await expect(owner.query(api.cleanup.selfDeletionStatus, {})).resolves.toMatchObject({
    completed: false,
    inProgress: true,
    phase: first.phase,
    progressToken: first.progressToken
  });

  const afterFirstBatch = await t.run(async (ctx) => ({
    account: await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", "owner_auth"))
      .unique(),
    receipt: await ctx.db
      .query("account_deletion_receipts")
      .withIndex("by_auth_subject", (q) => q.eq("auth_subject", "owner_auth"))
      .unique()
  }));
  expect(afterFirstBatch.account).toMatchObject({ email: "owner@test.com" });
  expect(afterFirstBatch.account?.status).toBeUndefined();
  expect(afterFirstBatch.receipt).toBeNull();

  let result = first;
  const progressTokens = new Set([first.progressToken]);
  for (let attempt = 0; !result.success && attempt < 100; attempt += 1) {
    result = await owner.mutation(api.cleanup.selfDeleteAccount, {});
    if (!result.success) {
      expect(progressTokens.has(result.progressToken)).toBe(false);
      progressTokens.add(result.progressToken);
    }
  }
  expect(result).toMatchObject({
    success: true,
    inProgress: false,
    state: "deleted",
    expensesPreserved: true,
    friendshipsUnlinked: 40,
    phase: "complete"
  });

  const retry = await owner.mutation(api.cleanup.selfDeleteAccount, {});
  expect(retry).toMatchObject({
    success: true,
    inProgress: false,
    state: "already_deleted",
    requestId: result.requestId,
    deletedAt: result.deletedAt,
    friendshipsUnlinked: 40,
    expensesPreserved: true
  });
});

test("self deletion cascades every expense before deleting an owner-only group", async () => {
  const t = convexTest(schema, modules);

  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: Date.now()
    });
    const otherId = await ctx.db.insert("accounts", {
      id: "other_auth",
      email: "other@test.com",
      display_name: "Other",
      member_id: "other_member",
      created_at: Date.now()
    });
    const groupId = await ctx.db.insert("groups", {
      id: "owner_only_group",
      name: "Owner only",
      members: [{ id: "owner_member", name: "Owner" }],
      owner_id: ownerId,
      owner_account_id: "owner_auth",
      owner_email: "owner@test.com",
      created_at: Date.now(),
      updated_at: Date.now()
    });
    await ctx.db.insert("expenses", {
      id: "attached_foreign_owned_expense",
      group_id: "owner_only_group",
      group_ref: groupId,
      description: "Attached",
      date: Date.now(),
      total_amount: 10,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member"],
      splits: [{ id: "split", member_id: "owner_member", amount: 10, is_settled: false }],
      is_settled: false,
      owner_id: otherId,
      owner_account_id: "other_auth",
      owner_email: "other@test.com",
      participant_member_ids: ["owner_member"],
      participant_emails: ["owner@test.com"],
      participants: [{ member_id: "owner_member", name: "Owner" }],
      created_at: Date.now(),
      updated_at: Date.now()
    });
    await ctx.db.insert("user_expenses", {
      user_id: "other_auth",
      expense_id: "attached_foreign_owned_expense",
      updated_at: Date.now()
    });
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  let result = await owner.mutation(api.cleanup.selfDeleteAccount, {});
  for (let attempt = 0; !result.success && attempt < 100; attempt += 1) {
    result = await owner.mutation(api.cleanup.selfDeleteAccount, {});
  }
  expect(result.success).toBe(true);

  const remaining = await t.run(async (ctx) => ({
    group: await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "owner_only_group"))
      .unique(),
    expense: await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "attached_foreign_owned_expense"))
      .unique(),
    visibility: await ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) => q.eq("expense_id", "attached_foreign_owned_expense"))
      .collect()
  }));
  expect(remaining).toEqual({ group: null, expense: null, visibility: [] });
});

test("self deletion preflights the aggregate identity workload for four 64-member expenses", async () => {
  const t = convexTest(schema, modules);

  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: Date.now()
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: Date.now()
    });
    await ctx.db.insert("account_friends", {
      account_email: "friend@test.com",
      member_id: "owner_member",
      name: "Owner",
      profile_avatar_color: "#123456",
      has_linked_account: true,
      linked_account_id: "owner_auth",
      linked_account_email: "owner@test.com",
      linked_member_id: "owner_member",
      updated_at: Date.now()
    });

    for (let expenseIndex = 0; expenseIndex < 4; expenseIndex += 1) {
      const memberIds = Array.from(
        { length: 64 },
        (_, memberIndex) => `member_${expenseIndex}_${memberIndex}`
      );
      await ctx.db.insert("expenses", {
        id: `large_identity_expense_${expenseIndex}`,
        group_id: "standalone",
        description: "Large identity workload",
        date: Date.now(),
        total_amount: 64,
        paid_by_member_id: memberIds[0],
        involved_member_ids: memberIds,
        splits: memberIds.map((memberId, index) => ({
          id: `split_${expenseIndex}_${index}`,
          member_id: memberId,
          amount: 1,
          is_settled: false
        })),
        is_settled: false,
        owner_email: "owner@test.com",
        owner_account_id: "owner_auth",
        owner_id: ownerId,
        participant_member_ids: memberIds,
        participant_emails: [],
        participants: memberIds.map((memberId) => ({ member_id: memberId, name: memberId })),
        created_at: Date.now(),
        updated_at: Date.now()
      });
    }
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  let failure: unknown;
  for (let attempt = 0; attempt < 20 && failure === undefined; attempt += 1) {
    try {
      await owner.mutation(api.cleanup.selfDeleteAccount, {});
    } catch (error) {
      failure = error;
    }
  }
  expect(String(failure)).toContain("too large to complete safely");

  const untouched = await t.run(async (ctx) => ({
    expenses: await ctx.db
      .query("expenses")
      .withIndex("by_owner_account_id", (q) => q.eq("owner_account_id", "owner_auth"))
      .collect(),
    linkedFriend: await ctx.db
      .query("account_friends")
      .withIndex("by_linked_account_id", (q) => q.eq("linked_account_id", "owner_auth"))
      .unique(),
    receipt: await ctx.db
      .query("account_deletion_receipts")
      .withIndex("by_auth_subject", (q) => q.eq("auth_subject", "owner_auth"))
      .unique()
  }));
  expect(untouched.expenses).toHaveLength(4);
  expect(untouched.linkedFriend).toMatchObject({ has_linked_account: true });
  expect(untouched.receipt).toBeNull();
});

test("self deletion rejects oversized expense visibility before unlinking friends", async () => {
  const t = convexTest(schema, modules);

  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: Date.now()
    });
    const otherId = await ctx.db.insert("accounts", {
      id: "other_auth",
      email: "other@test.com",
      display_name: "Other",
      member_id: "other_member",
      created_at: Date.now()
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: Date.now()
    });
    await ctx.db.insert("account_friends", {
      account_email: "other@test.com",
      member_id: "owner_member",
      name: "Owner",
      profile_avatar_color: "#123456",
      has_linked_account: true,
      linked_account_id: "owner_auth",
      linked_account_email: "owner@test.com",
      linked_member_id: "owner_member",
      updated_at: Date.now()
    });
    await ctx.db.insert("expenses", {
      id: "oversized_visibility_expense",
      group_id: "standalone",
      description: "Oversized visibility",
      date: Date.now(),
      total_amount: 10,
      paid_by_member_id: "other_member",
      involved_member_ids: ["other_member", "owner_member"],
      splits: [
        { id: "other_split", member_id: "other_member", amount: 5, is_settled: false },
        { id: "owner_split", member_id: "owner_member", amount: 5, is_settled: false }
      ],
      is_settled: false,
      owner_email: "other@test.com",
      owner_account_id: "other_auth",
      owner_id: otherId,
      participant_member_ids: ["other_member", "owner_member"],
      participant_emails: ["other@test.com", "owner@test.com"],
      participants: [
        { member_id: "other_member", name: "Other" },
        { member_id: "owner_member", name: "Owner" }
      ],
      created_at: Date.now(),
      updated_at: Date.now()
    });
    for (let index = 0; index < 129; index += 1) {
      await ctx.db.insert("user_expenses", {
        user_id: index === 0 ? "owner_auth" : `viewer_${index}`,
        expense_id: "oversized_visibility_expense",
        updated_at: Date.now()
      });
    }

    expect(ownerId).toBeDefined();
  });

  const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
  let failure: unknown;
  for (let attempt = 0; attempt < 20 && failure === undefined; attempt += 1) {
    try {
      await owner.mutation(api.cleanup.selfDeleteAccount, {});
    } catch (error) {
      failure = error;
    }
  }
  expect(String(failure)).toContain("too large to complete safely");

  const untouched = await t.run(async (ctx) => ({
    expense: await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "oversized_visibility_expense"))
      .unique(),
    visibility: await ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) => q.eq("expense_id", "oversized_visibility_expense"))
      .collect(),
    linkedFriend: await ctx.db
      .query("account_friends")
      .withIndex("by_linked_account_id", (q) => q.eq("linked_account_id", "owner_auth"))
      .unique(),
    receipt: await ctx.db
      .query("account_deletion_receipts")
      .withIndex("by_auth_subject", (q) => q.eq("auth_subject", "owner_auth"))
      .unique()
  }));
  expect(untouched.expense).not.toBeNull();
  expect(untouched.visibility).toHaveLength(129);
  expect(untouched.linkedFriend).toMatchObject({ has_linked_account: true });
  expect(untouched.receipt).toBeNull();
});
