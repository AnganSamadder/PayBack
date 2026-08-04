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

test("cleanup.deleteLinkedFriend removes all matching direct groups", async () => {
  const t = convexTest(schema, modules);

  await t.run(async (ctx) => {
    const ownerDoc = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: Date.now(),
      member_id: "owner_member"
    });

    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "friend_member",
      name: "Friend",
      profile_avatar_color: "#123456",
      has_linked_account: true,
      linked_account_id: "friend_auth",
      linked_account_email: "friend@test.com",
      updated_at: Date.now()
    });

    const directGroupA = await ctx.db.insert("groups", {
      id: "direct_group_a",
      name: "Friend A",
      is_direct: true,
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "friend_member", name: "Friend" }
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerDoc,
      created_at: Date.now(),
      updated_at: Date.now()
    });

    const directGroupB = await ctx.db.insert("groups", {
      id: "direct_group_b",
      name: "Friend B",
      is_direct: true,
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "friend_member", name: "Friend" }
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerDoc,
      created_at: Date.now(),
      updated_at: Date.now()
    });

    await ctx.db.insert("expenses", {
      id: "expense_a",
      group_id: "direct_group_a",
      group_ref: directGroupA,
      description: "Expense A",
      date: Date.now(),
      total_amount: 10,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "friend_member"],
      splits: [
        { id: "s_a_1", member_id: "owner_member", amount: 5, is_settled: false },
        { id: "s_a_2", member_id: "friend_member", amount: 5, is_settled: false }
      ],
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerDoc,
      participant_member_ids: ["owner_member", "friend_member"],
      participant_emails: ["owner@test.com"],
      participants: [
        { member_id: "owner_member", name: "Owner" },
        { member_id: "friend_member", name: "Friend" }
      ],
      created_at: Date.now(),
      updated_at: Date.now()
    });

    await ctx.db.insert("expenses", {
      id: "expense_b",
      group_id: "direct_group_b",
      group_ref: directGroupB,
      description: "Expense B",
      date: Date.now(),
      total_amount: 12,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "friend_member"],
      splits: [
        { id: "s_b_1", member_id: "owner_member", amount: 6, is_settled: false },
        { id: "s_b_2", member_id: "friend_member", amount: 6, is_settled: false }
      ],
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerDoc,
      participant_member_ids: ["owner_member", "friend_member"],
      participant_emails: ["owner@test.com"],
      participants: [
        { member_id: "owner_member", name: "Owner" },
        { member_id: "friend_member", name: "Friend" }
      ],
      created_at: Date.now(),
      updated_at: Date.now()
    });
  });

  await expect(t.query(api.cleanup.selfDeletionStatus, {})).rejects.toThrow("Unauthenticated");
  const ownerCtx = t.withIdentity(identity("owner@test.com", "owner_auth"));
  const result = await ownerCtx.mutation(api.cleanup.deleteLinkedFriend, {
    friendMemberId: "friend_member"
  });

  expect(result.success).toBe(true);
  expect(result.expensesDeleted).toBe(2);

  const remainingGroups = await t.run(async (ctx) =>
    ctx.db
      .query("groups")
      .withIndex("by_owner_email", (q) => q.eq("owner_email", "owner@test.com"))
      .collect()
  );
  expect(remainingGroups.filter((group) => group.is_direct)).toHaveLength(0);
});

test("cleanup.deleteUnlinkedFriend reconciles user_expenses after patching shared expenses", async () => {
  const t = convexTest(schema, modules);

  await t.run(async (ctx) => {
    const ownerDoc = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: Date.now(),
      member_id: "owner_member"
    });
    await ctx.db.insert("accounts", {
      id: "watcher_auth",
      email: "watcher@test.com",
      display_name: "Watcher",
      created_at: Date.now(),
      member_id: "watcher_member"
    });
    await ctx.db.insert("accounts", {
      id: "removed_auth",
      email: "removed@test.com",
      display_name: "Removed",
      created_at: Date.now(),
      member_id: "friend_member"
    });

    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "friend_member",
      name: "Friend",
      profile_avatar_color: "#654321",
      has_linked_account: false,
      updated_at: Date.now()
    });

    const sharedGroup = await ctx.db.insert("groups", {
      id: "shared_group",
      name: "Shared",
      is_direct: false,
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "friend_member", name: "Friend" },
        { id: "watcher_member", name: "Watcher" }
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerDoc,
      created_at: Date.now(),
      updated_at: Date.now()
    });

    await ctx.db.insert("expenses", {
      id: "shared_expense",
      group_id: "shared_group",
      group_ref: sharedGroup,
      description: "Trip",
      date: Date.now(),
      total_amount: 90,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "friend_member", "watcher_member"],
      splits: [
        { id: "s1", member_id: "owner_member", amount: 30, is_settled: false },
        { id: "s2", member_id: "friend_member", amount: 30, is_settled: false },
        { id: "s3", member_id: "watcher_member", amount: 30, is_settled: false }
      ],
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerDoc,
      participant_member_ids: ["owner_member", "friend_member", "watcher_member"],
      participant_emails: ["owner@test.com", "watcher@test.com", "removed@test.com"],
      participants: [
        { member_id: "owner_member", name: "Owner" },
        { member_id: "friend_member", name: "Friend" },
        { member_id: "watcher_member", name: "Watcher", linked_account_email: "watcher@test.com" }
      ],
      created_at: Date.now(),
      updated_at: Date.now()
    });

    await ctx.db.insert("user_expenses", {
      user_id: "owner_auth",
      expense_id: "shared_expense",
      updated_at: Date.now()
    });
    await ctx.db.insert("user_expenses", {
      user_id: "watcher_auth",
      expense_id: "shared_expense",
      updated_at: Date.now()
    });
    await ctx.db.insert("user_expenses", {
      user_id: "removed_auth",
      expense_id: "shared_expense",
      updated_at: Date.now()
    });
  });

  const ownerCtx = t.withIdentity(identity("owner@test.com", "owner_auth"));
  const result = await ownerCtx.mutation(api.cleanup.deleteUnlinkedFriend, {
    friendMemberId: "friend_member"
  });
  expect(result.success).toBe(true);

  const expenseAfter = await t.run(async (ctx) =>
    ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "shared_expense"))
      .unique()
  );
  expect(expenseAfter).not.toBeNull();
  expect(expenseAfter?.participant_member_ids).toEqual(["owner_member", "watcher_member"]);
  expect(expenseAfter?.participant_emails).toContain("owner@test.com");
  expect(expenseAfter?.participant_emails).toContain("watcher@test.com");
  expect(expenseAfter?.participant_emails).not.toContain("removed@test.com");

  const visibilityRows = await t.run(async (ctx) =>
    ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) => q.eq("expense_id", "shared_expense"))
      .collect()
  );
  const visibilityUserIds = visibilityRows.map((row) => row.user_id).sort();
  expect(visibilityUserIds).toEqual(["owner_auth", "watcher_auth"]);
});

test("cleanup.deleteUnlinkedFriend only deletes aliases for the caller account", async () => {
  const t = convexTest(schema, modules);

  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: Date.now(),
      member_id: "owner_member",
      alias_member_ids: ["friend_member"]
    });
    await ctx.db.insert("accounts", {
      id: "other_auth",
      email: "other@test.com",
      display_name: "Other",
      created_at: Date.now(),
      member_id: "other_member",
      alias_member_ids: ["friend_member"]
    });

    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "friend_member",
      name: "Friend",
      profile_avatar_color: "#222222",
      has_linked_account: false,
      updated_at: Date.now()
    });

    await ctx.db.insert("member_aliases", {
      account_email: "owner@test.com",
      canonical_member_id: "owner_member",
      alias_member_id: "friend_member",
      created_at: Date.now()
    });
    await ctx.db.insert("member_aliases", {
      account_email: "other@test.com",
      canonical_member_id: "other_member",
      alias_member_id: "friend_member",
      created_at: Date.now()
    });
  });

  const ownerCtx = t.withIdentity(identity("owner@test.com", "owner_auth"));
  const result = await ownerCtx.mutation(api.cleanup.deleteUnlinkedFriend, {
    friendMemberId: "friend_member"
  });
  expect(result.success).toBe(true);

  const remainingAliases = await t.run(async (ctx) =>
    ctx.db
      .query("member_aliases")
      .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", "friend_member"))
      .collect()
  );
  expect(remainingAliases).toHaveLength(1);
  expect(remainingAliases[0].account_email).toBe("other@test.com");

  const ownerAccount = await t.run(async (ctx) =>
    ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", "owner@test.com"))
      .unique()
  );
  expect(ownerAccount?.alias_member_ids ?? []).not.toContain("friend_member");
});

test("cleanup.deleteUnlinkedFriend throws for a group-derived non-friend and leaves data unchanged", async () => {
  const t = convexTest(schema, modules);

  await t.run(async (ctx) => {
    const ownerDoc = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: Date.now(),
      member_id: "owner_member"
    });

    const groupDoc = await ctx.db.insert("groups", {
      id: "shared_group",
      name: "Shared Group",
      is_direct: false,
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "group_only_member", name: "Group Only" }
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerDoc,
      created_at: Date.now(),
      updated_at: Date.now()
    });

    await ctx.db.insert("expenses", {
      id: "shared_expense",
      group_id: "shared_group",
      group_ref: groupDoc,
      description: "Trip",
      date: Date.now(),
      total_amount: 20,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "group_only_member"],
      splits: [
        { id: "s1", member_id: "owner_member", amount: 10, is_settled: false },
        { id: "s2", member_id: "group_only_member", amount: 10, is_settled: false }
      ],
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerDoc,
      participant_member_ids: ["owner_member", "group_only_member"],
      participant_emails: ["owner@test.com"],
      participants: [
        { member_id: "owner_member", name: "Owner" },
        { member_id: "group_only_member", name: "Group Only" }
      ],
      created_at: Date.now(),
      updated_at: Date.now()
    });
  });

  const ownerCtx = t.withIdentity(identity("owner@test.com", "owner_auth"));
  await expect(
    ownerCtx.mutation(api.cleanup.deleteUnlinkedFriend, {
      friendMemberId: "group_only_member"
    })
  ).rejects.toThrow("Friend not found");

  const [groupsAfter, expensesAfter, friendsAfter] = await t.run(async (ctx) => {
    const groups = await ctx.db
      .query("groups")
      .withIndex("by_owner_email", (q) => q.eq("owner_email", "owner@test.com"))
      .collect();
    const expenses = await ctx.db
      .query("expenses")
      .withIndex("by_owner_email", (q) => q.eq("owner_email", "owner@test.com"))
      .collect();
    const friends = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email", (q) => q.eq("account_email", "owner@test.com"))
      .collect();
    return [groups, expenses, friends] as const;
  });

  expect(groupsAfter).toHaveLength(1);
  expect(groupsAfter[0].members.map((member) => member.id)).toContain("group_only_member");
  expect(expensesAfter).toHaveLength(1);
  expect(expensesAfter[0].participant_member_ids).toContain("group_only_member");
  expect(friendsAfter).toHaveLength(0);
});

test("cleanup.selfDeleteAccount removes account PII, preserves shared history, and is idempotent", async () => {
  const t = convexTest(schema, modules);

  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "friend_auth",
      email: "friend@test.com",
      display_name: "Friend",
      created_at: Date.now(),
      member_id: "friend_member"
    });

    const ownerDoc = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: Date.now(),
      member_id: "owner_member",
      alias_member_ids: ["owner_alias"]
    });

    const ownedGroup = await ctx.db.insert("groups", {
      id: "owned_group",
      name: "Owned",
      is_direct: false,
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "friend_member", name: "Friend" }
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerDoc,
      created_at: Date.now(),
      updated_at: Date.now()
    });

    await ctx.db.insert("expenses", {
      id: "owned_expense",
      group_id: "owned_group",
      group_ref: ownedGroup,
      description: "Owned Expense",
      date: Date.now(),
      total_amount: 42,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "friend_member"],
      splits: [
        { id: "s1", member_id: "owner_member", amount: 21, is_settled: false },
        { id: "s2", member_id: "friend_member", amount: 21, is_settled: false }
      ],
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerDoc,
      participant_member_ids: ["owner_member", "friend_member"],
      participant_emails: ["owner@test.com", "friend@test.com"],
      participants: [
        {
          member_id: "owner_member",
          name: "Owner",
          linked_account_id: "owner_auth",
          linked_account_email: "owner@test.com"
        },
        {
          member_id: "friend_member",
          name: "Friend",
          linked_account_id: "friend_auth",
          linked_account_email: "friend@test.com"
        }
      ],
      created_at: Date.now(),
      updated_at: Date.now()
    });

    const privateGroup = await ctx.db.insert("groups", {
      id: "private_group",
      name: "Private",
      is_direct: false,
      members: [{ id: "owner_member", name: "Owner", is_current_user: true }],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerDoc,
      created_at: Date.now(),
      updated_at: Date.now()
    });
    await ctx.db.insert("expenses", {
      id: "private_expense",
      group_id: "private_group",
      group_ref: privateGroup,
      description: "Private Expense",
      date: Date.now(),
      total_amount: 10,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member"],
      splits: [{ id: "private_split", member_id: "owner_member", amount: 10, is_settled: false }],
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerDoc,
      participant_member_ids: ["owner_member"],
      participant_emails: ["owner@test.com"],
      participants: [{ member_id: "owner_member", name: "Owner" }],
      created_at: Date.now(),
      updated_at: Date.now()
    });

    await ctx.db.insert("invite_tokens", {
      id: "owner_invite",
      creator_id: "owner_auth",
      creator_email: "owner@test.com",
      target_member_id: "friend_member",
      target_member_name: "Friend",
      created_at: Date.now(),
      expires_at: Date.now() + 60_000
    });
    await ctx.db.insert("link_requests", {
      id: "owner_request",
      requester_id: "owner_auth",
      requester_email: "owner@test.com",
      requester_name: "Owner",
      recipient_email: "friend@test.com",
      target_member_id: "friend_member",
      target_member_name: "Friend",
      created_at: Date.now(),
      status: "pending",
      expires_at: Date.now() + 60_000
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
      status: "accepted",
      updated_at: Date.now()
    });
  });

  const ownerCtx = t.withIdentity(identity("owner@test.com", "owner_auth"));
  await expect(ownerCtx.query(api.cleanup.selfDeletionStatus, {})).resolves.toEqual({
    completed: false
  });
  const result = await ownerCtx.mutation(api.cleanup.selfDeleteAccount, {});
  expect(result.success).toBe(true);
  expect(result.state).toBe("deleted");
  expect(result.expensesPreserved).toBe(true);
  await expect(ownerCtx.query(api.cleanup.selfDeletionStatus, {})).resolves.toEqual({
    completed: true
  });

  const ownerAfter = await t.run(async (ctx) =>
    ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", "owner@test.com"))
      .unique()
  );
  expect(ownerAfter).toBeNull();

  const ownerTombstone = await t.run(async (ctx) =>
    ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", "owner_auth"))
      .unique()
  );
  expect(ownerTombstone).toMatchObject({
    id: "owner_auth",
    status: "deleted",
    display_name: "Deleted User"
  });
  expect(ownerTombstone?.email).toMatch(/^deleted\+.*@payback\.invalid$/);
  expect(ownerTombstone?.deleted_at).toEqual(expect.any(Number));

  const deletionReceipt = await t.run(async (ctx) =>
    ctx.db
      .query("account_deletion_receipts")
      .withIndex("by_auth_subject", (q) => q.eq("auth_subject", "owner_auth"))
      .unique()
  );
  expect(deletionReceipt).toMatchObject({
    auth_subject: "owner_auth",
    request_id: "owner_auth",
    expenses_preserved: true
  });

  const groupsWithOriginalOwnerEmail = await t.run(async (ctx) =>
    ctx.db
      .query("groups")
      .withIndex("by_owner_email", (q) => q.eq("owner_email", "owner@test.com"))
      .collect()
  );
  expect(groupsWithOriginalOwnerEmail).toHaveLength(0);

  const expensesWithOriginalOwnerEmail = await t.run(async (ctx) =>
    ctx.db
      .query("expenses")
      .withIndex("by_owner_email", (q) => q.eq("owner_email", "owner@test.com"))
      .collect()
  );
  expect(expensesWithOriginalOwnerEmail).toHaveLength(0);

  const transferredGroup = await t.run(async (ctx) =>
    ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "owned_group"))
      .unique()
  );
  expect(transferredGroup).toMatchObject({
    owner_account_id: "friend_auth",
    owner_email: "friend@test.com"
  });
  expect(transferredGroup?.members.find((member) => member.id === "owner_member")?.name).toBe(
    "Deleted User"
  );

  const sharedExpense = await t.run(async (ctx) =>
    ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "owned_expense"))
      .unique()
  );
  expect(sharedExpense).toMatchObject({
    owner_account_id: "friend_auth",
    owner_email: "friend@test.com",
    participant_emails: ["friend@test.com"]
  });
  const deletedParticipant = sharedExpense?.participants.find(
    (participant) => participant.member_id === "owner_member"
  );
  expect(deletedParticipant?.name).toBe("Deleted User");
  expect(deletedParticipant).not.toHaveProperty("linked_account_id");
  expect(deletedParticipant).not.toHaveProperty("linked_account_email");

  const privateGroup = await t.run(async (ctx) =>
    ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "private_group"))
      .unique()
  );
  const privateExpense = await t.run(async (ctx) =>
    ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "private_expense"))
      .unique()
  );
  expect(privateGroup).toBeNull();
  expect(privateExpense).toBeNull();

  const friendVisibility = await t.run(async (ctx) =>
    ctx.db
      .query("user_expenses")
      .withIndex("by_user_id", (q) => q.eq("user_id", "friend_auth"))
      .collect()
  );
  expect(friendVisibility.map((row) => row.expense_id)).toContain("owned_expense");

  const ephemeralRows = await t.run(async (ctx) => ({
    invites: await ctx.db.query("invite_tokens").collect(),
    requests: await ctx.db.query("link_requests").collect()
  }));
  expect(ephemeralRows.invites).toHaveLength(0);
  expect(ephemeralRows.requests).toHaveLength(0);

  const friendGhosts = await t
    .withIdentity(identity("friend@test.com", "friend_auth"))
    .query(api.friends.list, {});
  expect(friendGhosts).toHaveLength(1);
  expect(friendGhosts[0]).toMatchObject({
    member_id: "owner_member",
    name: "Owner",
    has_linked_account: false,
    link_state: "ghost"
  });
  expect(friendGhosts[0].linked_account_id).toBeUndefined();
  expect(friendGhosts[0].linked_account_email).toBeUndefined();

  const retry = await ownerCtx.mutation(api.cleanup.selfDeleteAccount, {});
  expect(retry).toMatchObject({
    success: true,
    state: "already_deleted",
    requestId: "owner_auth",
    expensesPreserved: true
  });
});
