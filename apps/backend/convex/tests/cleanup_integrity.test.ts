import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api, internal } from "../_generated/api";
import { reconcileExpenseVisibility } from "../helpers";
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

async function markIdentityReady(t: any) {
  await t.run(async (ctx) => {
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: Date.now()
    });
  });
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
  await markIdentityReady(t);
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

test("cleanup.deleteLinkedFriend normalizes equivalent Swift UUIDs before deleting direct history", async () => {
  const t = convexTest(schema, modules);
  const friendAlias = "11111111-1111-4111-8111-111111111111";
  const canonicalFriendId = "22222222-2222-4222-8222-222222222222";
  const storedCanonicalFriendId = `  ${canonicalFriendId.toUpperCase()}  `;

  await t.run(async (ctx) => {
    const ownerDoc = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: Date.now(),
      member_id: "owner_member"
    });
    await ctx.db.insert("accounts", {
      id: "friend_auth",
      email: "friend@test.com",
      display_name: "Friend",
      created_at: Date.now(),
      member_id: canonicalFriendId,
      alias_member_ids: [friendAlias]
    });

    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: friendAlias,
      name: "Friend",
      profile_avatar_color: "#123456",
      has_linked_account: true,
      linked_account_id: "friend_auth",
      linked_account_email: "friend@test.com",
      linked_member_id: canonicalFriendId,
      updated_at: Date.now()
    });
    await ctx.db.insert("member_aliases", {
      account_email: "owner@test.com",
      canonical_member_id: canonicalFriendId,
      alias_member_id: friendAlias,
      materialization_source: "account_alias",
      source_account_id: "friend_auth",
      created_at: Date.now()
    });

    const directGroup = await ctx.db.insert("groups", {
      id: "normalized_direct_group",
      name: "Friend",
      is_direct: true,
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: storedCanonicalFriendId, name: "Friend" }
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerDoc,
      created_at: Date.now(),
      updated_at: Date.now()
    });

    await ctx.db.insert("expenses", {
      id: "normalized_direct_expense",
      group_id: "normalized_direct_group",
      group_ref: directGroup,
      description: "Dinner",
      date: Date.now(),
      total_amount: 20,
      paid_by_member_id: storedCanonicalFriendId,
      involved_member_ids: ["owner_member", storedCanonicalFriendId],
      splits: [
        { id: "owner_split", member_id: "owner_member", amount: 10, is_settled: false },
        {
          id: "friend_split",
          member_id: storedCanonicalFriendId,
          amount: 10,
          is_settled: false
        }
      ],
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerDoc,
      participant_member_ids: ["owner_member", storedCanonicalFriendId],
      participant_emails: ["owner@test.com", "friend@test.com"],
      participants: [
        { member_id: "owner_member", name: "Owner" },
        { member_id: storedCanonicalFriendId, name: "Friend" }
      ],
      created_at: Date.now(),
      updated_at: Date.now()
    });
    await ctx.db.insert("user_expenses", {
      user_id: "owner_auth",
      expense_id: "normalized_direct_expense",
      updated_at: Date.now()
    });
    await ctx.db.insert("user_expenses", {
      user_id: "friend_auth",
      expense_id: "normalized_direct_expense",
      updated_at: Date.now()
    });
  });

  await markIdentityReady(t);
  const ownerCtx = t.withIdentity(identity("owner@test.com", "owner_auth"));
  const result = await ownerCtx.mutation(api.cleanup.deleteLinkedFriend, {
    friendMemberId: friendAlias
  });

  expect(result.success).toBe(true);
  expect(result.directGroupDeleted).toBe(true);
  expect(result.expensesDeleted).toBe(1);

  const remaining = await t.run(async (ctx) => ({
    groups: await ctx.db
      .query("groups")
      .withIndex("by_owner_email", (q) => q.eq("owner_email", "owner@test.com"))
      .collect(),
    expenses: await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "normalized_direct_expense"))
      .collect(),
    visibility: await ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) => q.eq("expense_id", "normalized_direct_expense"))
      .collect()
  }));
  expect(remaining.groups).toHaveLength(0);
  expect(remaining.expenses).toHaveLength(0);
  expect(remaining.visibility).toHaveLength(0);
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

  await markIdentityReady(t);
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

test("cleanup.deleteUnlinkedFriend normalizes equivalent Swift UUIDs across every expense identity surface", async () => {
  const t = convexTest(schema, modules);
  const friendAlias = "33333333-3333-4333-8333-333333333333";
  const canonicalFriendId = "44444444-4444-4444-8444-444444444444";
  const storedCanonicalFriendId = ` ${canonicalFriendId.toUpperCase()} `;

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
      member_id: canonicalFriendId,
      alias_member_ids: [friendAlias]
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: friendAlias,
      name: "Friend",
      profile_avatar_color: "#654321",
      has_linked_account: false,
      updated_at: Date.now()
    });
    await ctx.db.insert("member_aliases", {
      account_email: "owner@test.com",
      canonical_member_id: canonicalFriendId,
      alias_member_id: friendAlias,
      materialization_source: "account_alias",
      source_account_id: "removed_auth",
      created_at: Date.now()
    });

    const sharedGroup = await ctx.db.insert("groups", {
      id: "normalized_shared_group",
      name: "Shared",
      is_direct: false,
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: storedCanonicalFriendId, name: "Friend" },
        { id: "watcher_member", name: "Watcher" }
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerDoc,
      created_at: Date.now(),
      updated_at: Date.now()
    });

    const baseExpense = {
      group_id: "normalized_shared_group",
      group_ref: sharedGroup,
      date: Date.now(),
      total_amount: 60,
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerDoc,
      participant_emails: ["owner@test.com", "watcher@test.com", "removed@test.com"],
      created_at: Date.now(),
      updated_at: Date.now()
    };

    await ctx.db.insert("expenses", {
      ...baseExpense,
      id: "split_participant_only_expense",
      description: "Legacy split and participant",
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "watcher_member"],
      splits: [
        { id: "s1", member_id: "owner_member", amount: 20, is_settled: false },
        { id: "s2", member_id: storedCanonicalFriendId, amount: 20, is_settled: false },
        { id: "s3", member_id: "watcher_member", amount: 20, is_settled: false }
      ],
      participant_member_ids: ["owner_member", "watcher_member"],
      participants: [
        { member_id: "owner_member", name: "Owner" },
        {
          member_id: storedCanonicalFriendId,
          name: "Friend",
          linked_account_email: "removed@test.com"
        },
        { member_id: "watcher_member", name: "Watcher", linked_account_email: "watcher@test.com" }
      ]
    });

    await ctx.db.insert("expenses", {
      ...baseExpense,
      id: "participant_ids_only_expense",
      description: "Legacy participant IDs",
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "watcher_member"],
      splits: [
        { id: "s4", member_id: "owner_member", amount: 30, is_settled: false },
        { id: "s5", member_id: "watcher_member", amount: 30, is_settled: false }
      ],
      participant_member_ids: ["owner_member", storedCanonicalFriendId, "watcher_member"],
      participants: [
        { member_id: "owner_member", name: "Owner" },
        { member_id: "watcher_member", name: "Watcher", linked_account_email: "watcher@test.com" }
      ]
    });

    await ctx.db.insert("expenses", {
      ...baseExpense,
      id: "removed_payer_expense",
      description: "Removed payer",
      paid_by_member_id: storedCanonicalFriendId,
      involved_member_ids: ["owner_member", "watcher_member"],
      splits: [
        { id: "s6", member_id: "owner_member", amount: 30, is_settled: false },
        { id: "s7", member_id: "watcher_member", amount: 30, is_settled: false }
      ],
      participant_member_ids: ["owner_member", "watcher_member"],
      participants: [
        { member_id: "owner_member", name: "Owner" },
        { member_id: "watcher_member", name: "Watcher", linked_account_email: "watcher@test.com" }
      ]
    });

    for (const expenseId of [
      "split_participant_only_expense",
      "participant_ids_only_expense",
      "removed_payer_expense"
    ]) {
      for (const userId of ["owner_auth", "watcher_auth", "removed_auth"]) {
        await ctx.db.insert("user_expenses", {
          user_id: userId,
          expense_id: expenseId,
          updated_at: Date.now()
        });
      }
    }
  });

  await markIdentityReady(t);
  const ownerCtx = t.withIdentity(identity("owner@test.com", "owner_auth"));
  const result = await ownerCtx.mutation(api.cleanup.deleteUnlinkedFriend, {
    friendMemberId: friendAlias
  });

  expect(result.success).toBe(true);
  expect(result.groupsModified).toBe(1);
  expect(result.expensesModified).toBe(2);
  expect(result.expensesDeleted).toBe(1);

  const removedCtx = t.withIdentity(identity("removed@test.com", "removed_auth"));
  await expect(
    removedCtx.mutation(api.expenses.setSettlementState, {
      expenseId: "split_participant_only_expense",
      memberIds: [storedCanonicalFriendId],
      settled: true
    })
  ).rejects.toThrow("Forbidden");

  const retainedBeforeUpdate = await t.run(async (ctx) =>
    ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "split_participant_only_expense"))
      .unique()
  );
  if (!retainedBeforeUpdate) throw new Error("Expected retained historical expense");
  await ownerCtx.mutation(api.expenses.create, {
    id: retainedBeforeUpdate.id,
    context_kind: "group",
    group_id: retainedBeforeUpdate.group_id,
    description: "Updated historical expense",
    date: retainedBeforeUpdate.date,
    total_amount: retainedBeforeUpdate.total_amount,
    paid_by_member_id: retainedBeforeUpdate.paid_by_member_id,
    involved_member_ids: retainedBeforeUpdate.involved_member_ids,
    splits: retainedBeforeUpdate.splits,
    is_settled: retainedBeforeUpdate.is_settled,
    participant_member_ids: retainedBeforeUpdate.participant_member_ids,
    participants: retainedBeforeUpdate.participants
  });

  await t.run(async (ctx) => {
    const expense = await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "split_participant_only_expense"))
      .unique();
    if (!expense) throw new Error("Expected retained historical expense");
    await reconcileExpenseVisibility(ctx, expense);
  });
  await t.mutation(internal.migrations.repairExpenseSettlementAndVisibility, {});
  await t.mutation(internal.migrations.backfillParticipantEmails, {});

  const normalizedRemovedIds = new Set([friendAlias, canonicalFriendId]);
  const normalized = (memberId: string) => memberId.trim().toLowerCase();
  const remaining = await t.run(async (ctx) => {
    const group = await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "normalized_shared_group"))
      .unique();
    const expenses = await ctx.db
      .query("expenses")
      .withIndex("by_group_id", (q) => q.eq("group_id", "normalized_shared_group"))
      .collect();
    const visibility = await ctx.db.query("user_expenses").collect();
    return { group, expenses, visibility };
  });

  expect(
    remaining.group?.members.some((member) => normalizedRemovedIds.has(normalized(member.id)))
  ).toBe(false);
  expect(remaining.expenses.map((expense) => expense.id).sort()).toEqual([
    "participant_ids_only_expense",
    "split_participant_only_expense"
  ]);
  const splitHistory = remaining.expenses.find(
    (expense) => expense.id === "split_participant_only_expense"
  );
  expect(splitHistory?.description).toBe("Updated historical expense");
  expect(splitHistory?.total_amount).toBe(60);
  expect(splitHistory?.splits.reduce((total, split) => total + split.amount, 0)).toBe(60);
  expect(splitHistory?.splits.every((split) => split.is_settled === false)).toBe(true);
  expect(new Set(splitHistory?.inactive_participant_member_ids)).toEqual(
    new Set([friendAlias, canonicalFriendId])
  );
  expect(
    splitHistory?.splits.some((split) => normalizedRemovedIds.has(normalized(split.member_id)))
  ).toBe(true);
  expect(
    splitHistory?.participants.some((participant) =>
      normalizedRemovedIds.has(normalized(participant.member_id))
    )
  ).toBe(true);

  const participantHistory = remaining.expenses.find(
    (expense) => expense.id === "participant_ids_only_expense"
  );
  expect(
    participantHistory?.participant_member_ids.some((memberId) =>
      normalizedRemovedIds.has(normalized(memberId))
    )
  ).toBe(false);

  for (const expense of remaining.expenses) {
    expect(normalizedRemovedIds.has(normalized(expense.paid_by_member_id))).toBe(false);
    expect(
      expense.involved_member_ids.some((memberId) => normalizedRemovedIds.has(normalized(memberId)))
    ).toBe(false);
    expect(
      expense.participant_member_ids.some((memberId) =>
        normalizedRemovedIds.has(normalized(memberId))
      )
    ).toBe(false);
    expect(expense.participant_emails).not.toContain("removed@test.com");
  }
  expect(remaining.visibility.some((row) => row.expense_id === "removed_payer_expense")).toBe(
    false
  );
  expect(
    remaining.visibility.some(
      (row) =>
        row.user_id === "removed_auth" &&
        ["split_participant_only_expense", "participant_ids_only_expense"].includes(row.expense_id)
    )
  ).toBe(false);
});

test("expense visibility preserves owners and separate active surfaces for partly inactive accounts", async () => {
  const t = convexTest(schema, modules);

  await t.run(async (ctx) => {
    const ownerDoc = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: Date.now(),
      member_id: "owner_member",
      alias_member_ids: ["owner_inactive_alias"]
    });
    await ctx.db.insert("accounts", {
      id: "participant_auth",
      email: "participant@test.com",
      display_name: "Participant",
      created_at: Date.now(),
      member_id: "participant_member",
      alias_member_ids: ["participant_inactive_alias", "participant_active_alias"]
    });
    for (const [accountEmail, canonicalMemberId, aliasMemberId, sourceAccountId] of [
      ["owner@test.com", "owner_member", "owner_inactive_alias", "owner_auth"],
      [
        "participant@test.com",
        "participant_member",
        "participant_inactive_alias",
        "participant_auth"
      ],
      ["participant@test.com", "participant_member", "participant_active_alias", "participant_auth"]
    ]) {
      await ctx.db.insert("member_aliases", {
        account_email: accountEmail,
        canonical_member_id: canonicalMemberId,
        alias_member_id: aliasMemberId,
        materialization_source: "account_alias",
        source_account_id: sourceAccountId,
        created_at: Date.now()
      });
    }

    const groupRef = await ctx.db.insert("groups", {
      id: "historical_group",
      name: "Historical Group",
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "participant_active_alias", name: "Participant" }
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerDoc,
      created_at: Date.now(),
      updated_at: Date.now()
    });

    const expenseId = await ctx.db.insert("expenses", {
      id: "partly_inactive_expense",
      group_id: "historical_group",
      group_ref: groupRef,
      description: "Historical expense",
      date: Date.now(),
      total_amount: 60,
      paid_by_member_id: "participant_active_alias",
      involved_member_ids: ["participant_active_alias"],
      splits: [
        {
          id: "historical_split",
          member_id: "participant_inactive_alias",
          amount: 30,
          is_settled: false
        },
        {
          id: "active_split",
          member_id: "participant_active_alias",
          amount: 30,
          is_settled: false
        }
      ],
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerDoc,
      participant_member_ids: ["participant_active_alias"],
      inactive_participant_member_ids: ["owner_inactive_alias", "participant_inactive_alias"],
      participant_emails: ["owner@test.com", "participant@test.com"],
      participants: [
        {
          member_id: "participant_inactive_alias",
          name: "Historical Participant",
          linked_account_id: "participant_auth",
          linked_account_email: "participant@test.com"
        },
        { member_id: "participant_active_alias", name: "Active Participant" }
      ],
      created_at: Date.now(),
      updated_at: Date.now()
    });
    const expense = await ctx.db.get(expenseId);
    if (!expense) throw new Error("Expected expense fixture");
    await reconcileExpenseVisibility(ctx, expense);
  });

  const viewers = await t.run(async (ctx) =>
    (
      await ctx.db
        .query("user_expenses")
        .withIndex("by_expense_id", (q) => q.eq("expense_id", "partly_inactive_expense"))
        .collect()
    )
      .map((row) => row.user_id)
      .sort()
  );
  expect(viewers).toEqual(["owner_auth", "participant_auth"]);

  const participantCtx = t.withIdentity(identity("participant@test.com", "participant_auth"));
  await expect(
    participantCtx.mutation(api.expenses.setSettlementState, {
      expenseId: "partly_inactive_expense",
      memberIds: ["participant_inactive_alias"],
      settled: true
    })
  ).rejects.toThrow("Forbidden");

  const settledExpense = await participantCtx.mutation(api.expenses.setSettlementState, {
    expenseId: "partly_inactive_expense",
    settled: true
  });
  expect(
    settledExpense.splits.find(
      (split: { member_id: string }) => split.member_id === "participant_inactive_alias"
    )?.is_settled
  ).toBe(false);
  expect(
    settledExpense.splits.find(
      (split: { member_id: string }) => split.member_id === "participant_active_alias"
    )?.is_settled
  ).toBe(true);

  const explicitlySettledExpense = await participantCtx.mutation(api.expenses.setSettlementState, {
    expenseId: "partly_inactive_expense",
    memberIds: ["participant_active_alias"],
    settled: true
  });
  expect(
    explicitlySettledExpense.splits.find(
      (split: { member_id: string }) => split.member_id === "participant_inactive_alias"
    )?.is_settled
  ).toBe(false);
  expect(
    explicitlySettledExpense.splits.find(
      (split: { member_id: string }) => split.member_id === "participant_active_alias"
    )?.is_settled
  ).toBe(true);

  await expect(
    participantCtx.mutation(api.expenses.create, {
      id: "partly_inactive_expense",
      context_kind: "group",
      group_id: "historical_group",
      description: "Historical expense",
      date: explicitlySettledExpense.date,
      total_amount: 60,
      paid_by_member_id: "participant_active_alias",
      involved_member_ids: ["participant_active_alias"],
      splits: [
        {
          id: "historical_split",
          member_id: "participant_inactive_alias",
          amount: 30,
          is_settled: true
        },
        {
          id: "active_split",
          member_id: "participant_active_alias",
          amount: 30,
          is_settled: true
        }
      ],
      is_settled: true,
      participant_member_ids: ["participant_active_alias"],
      participants: [
        { member_id: "participant_inactive_alias", name: "Historical Participant" },
        { member_id: "participant_active_alias", name: "Active Participant" }
      ]
    })
  ).rejects.toThrow("Forbidden");
});

test("expense visibility excludes orphaned inactive linked identities", async () => {
  const t = convexTest(schema, modules);

  await t.run(async (ctx) => {
    const ownerDoc = await ctx.db.insert("accounts", {
      id: "orphan_owner_auth",
      email: "orphan-owner@test.com",
      display_name: "Owner",
      created_at: Date.now(),
      member_id: "orphan_owner_member"
    });
    await ctx.db.insert("accounts", {
      id: "orphan_removed_auth",
      email: "orphan-removed@test.com",
      display_name: "Removed",
      created_at: Date.now(),
      member_id: "orphan_removed_canonical"
    });
    const expenseId = await ctx.db.insert("expenses", {
      id: "orphan_inactive_expense",
      group_id: "orphan_group",
      description: "Historical expense",
      date: Date.now(),
      total_amount: 10,
      paid_by_member_id: "orphan_owner_member",
      involved_member_ids: ["orphan_owner_member"],
      splits: [
        {
          id: "orphan_inactive_split",
          member_id: "orphan_inactive_alias",
          amount: 10,
          is_settled: false
        }
      ],
      is_settled: false,
      owner_email: "orphan-owner@test.com",
      owner_account_id: "orphan_owner_auth",
      owner_id: ownerDoc,
      participant_member_ids: ["orphan_owner_member"],
      inactive_participant_member_ids: ["orphan_inactive_alias"],
      participant_emails: ["orphan-owner@test.com", "orphan-removed@test.com"],
      participants: [
        {
          member_id: "orphan_inactive_alias",
          name: "Historical Participant",
          linked_account_id: "orphan_removed_auth",
          linked_account_email: "orphan-removed@test.com"
        }
      ],
      created_at: Date.now(),
      updated_at: Date.now()
    });
    const expense = await ctx.db.get(expenseId);
    if (!expense) throw new Error("Expected orphaned inactive expense");
    await reconcileExpenseVisibility(ctx, expense);
  });

  const viewers = await t.run(async (ctx) =>
    (
      await ctx.db
        .query("user_expenses")
        .withIndex("by_expense_id", (q) => q.eq("expense_id", "orphan_inactive_expense"))
        .collect()
    )
      .map((row) => row.user_id)
      .sort()
  );
  expect(viewers).toEqual(["orphan_owner_auth"]);
});

test("advanced expense visibility backfill removes inactive participant surfaces", async () => {
  const t = convexTest(schema, modules);

  await t.run(async (ctx) => {
    const ownerDoc = await ctx.db.insert("accounts", {
      id: "maintenance_owner_auth",
      email: "maintenance-owner@test.com",
      display_name: "Owner",
      created_at: Date.now(),
      member_id: "maintenance_owner_member"
    });
    await ctx.db.insert("accounts", {
      id: "maintenance_removed_auth",
      email: "maintenance-removed@test.com",
      display_name: "Removed",
      created_at: Date.now(),
      member_id: "maintenance_inactive_member"
    });
    await ctx.db.insert("accounts", {
      id: "maintenance_active_auth",
      email: "maintenance-active@test.com",
      display_name: "Active",
      created_at: Date.now(),
      member_id: "maintenance_active_member"
    });
    await ctx.db.insert("expenses", {
      id: "maintenance_inactive_expense",
      group_id: "maintenance_group",
      description: "Historical expense",
      date: Date.now(),
      total_amount: 10,
      paid_by_member_id: "maintenance_owner_member",
      involved_member_ids: [
        "maintenance_owner_member",
        "maintenance_inactive_member",
        "maintenance_active_member"
      ],
      splits: [
        {
          id: "maintenance_inactive_split",
          member_id: "maintenance_inactive_member",
          amount: 10,
          is_settled: false
        }
      ],
      is_settled: false,
      owner_email: "maintenance-owner@test.com",
      owner_account_id: "maintenance_owner_auth",
      owner_id: ownerDoc,
      participant_member_ids: ["maintenance_owner_member"],
      inactive_participant_member_ids: ["maintenance_inactive_member"],
      participant_emails: [
        "maintenance-owner@test.com",
        "maintenance-active@test.com",
        "maintenance-removed@test.com"
      ],
      participants: [
        {
          member_id: "maintenance_inactive_member",
          name: "Historical Participant",
          linked_account_id: "maintenance_removed_auth",
          linked_account_email: "maintenance-removed@test.com"
        },
        {
          member_id: "maintenance_active_member",
          name: "Active",
          linked_account_id: "maintenance_active_auth",
          linked_account_email: "maintenance-active@test.com"
        }
      ],
      created_at: Date.now(),
      updated_at: Date.now()
    });
    await ctx.db.insert("user_expenses", {
      user_id: "maintenance_owner_auth",
      expense_id: "maintenance_inactive_expense",
      updated_at: Date.now()
    });
    await ctx.db.insert("user_expenses", {
      user_id: "maintenance_active_auth",
      expense_id: "maintenance_inactive_expense",
      updated_at: Date.now()
    });
    await ctx.db.insert("user_expenses", {
      user_id: "maintenance_removed_auth",
      expense_id: "maintenance_inactive_expense",
      updated_at: Date.now()
    });
  });

  await t.mutation(internal.migrations.backfillParticipantEmailsAdvanced, {});

  const result = await t.run(async (ctx) => {
    const expense = await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "maintenance_inactive_expense"))
      .unique();
    const visibility = await ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) => q.eq("expense_id", "maintenance_inactive_expense"))
      .collect();
    return { expense, visibility };
  });
  expect(result.expense?.participant_emails).toEqual([
    "maintenance-owner@test.com",
    "maintenance-active@test.com"
  ]);
  expect(
    result.expense?.participants.find(
      (participant) => participant.member_id === "maintenance_inactive_member"
    )?.name
  ).toBe("Historical Participant");
  expect(result.visibility.map((row) => row.user_id).sort()).toEqual([
    "maintenance_active_auth",
    "maintenance_owner_auth"
  ]);

  await t.run(async (ctx) => {
    if (!result.expense) throw new Error("Expected maintenance expense");
    await ctx.db.patch(result.expense._id, {
      participant_emails: ["maintenance-owner@test.com", "maintenance-removed@test.com"]
    });
  });
  await t.mutation(internal.migrations.backfillUserExpenses, {});

  const visibilityAfterStaleEmail = await t.run(async (ctx) =>
    ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) => q.eq("expense_id", "maintenance_inactive_expense"))
      .collect()
  );
  expect(visibilityAfterStaleEmail.map((row) => row.user_id).sort()).toEqual([
    "maintenance_active_auth",
    "maintenance_owner_auth"
  ]);
});

test("cleanup.deleteUnlinkedFriend preserves standalone aliases while pruning account materialization", async () => {
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
      materialization_source: "account_alias",
      source_account_id: "owner_auth",
      created_at: Date.now()
    });
    await ctx.db.insert("member_aliases", {
      account_email: "importer@test.com",
      canonical_member_id: "owner_member",
      alias_member_id: "friend_member",
      created_at: Date.now()
    });
  });

  await markIdentityReady(t);
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
  expect(remainingAliases[0].account_email).toBe("importer@test.com");
  expect(remainingAliases[0].source_account_id).toBeUndefined();

  const ownerAccount = await t.run(async (ctx) =>
    ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", "owner@test.com"))
      .unique()
  );
  expect(ownerAccount?.alias_member_ids ?? []).not.toContain("friend_member");
});

test("cleanup.deleteUnlinkedFriend preflights alias materialization bounds before destructive writes", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "alias_bound_owner_auth",
      email: "alias-bound-owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "alias_bound_owner",
      alias_member_ids: ["alias_bound_friend"]
    });
    await ctx.db.insert("account_friends", {
      account_email: "alias-bound-owner@test.com",
      member_id: "alias_bound_friend",
      name: "Friend",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      updated_at: now
    });
    await ctx.db.insert("groups", {
      id: "alias_bound_group",
      name: "Alias bound group",
      members: [
        { id: "alias_bound_owner", name: "Owner" },
        { id: "alias_bound_friend", name: "Friend" },
        { id: "alias_bound_survivor", name: "Survivor" }
      ],
      owner_email: "alias-bound-owner@test.com",
      owner_account_id: "alias_bound_owner_auth",
      owner_id: ownerId,
      created_at: now,
      updated_at: now
    });
    for (let index = 0; index < 9; index += 1) {
      await ctx.db.insert("member_aliases", {
        account_email: `alias-source-${index}@test.com`,
        canonical_member_id: "alias_bound_owner",
        alias_member_id: "alias_bound_friend",
        materialization_source: "account_alias",
        source_account_id: "alias_bound_owner_auth",
        created_at: now
      });
    }
  });
  await markIdentityReady(t);

  await expect(
    t
      .withIdentity(identity("alias-bound-owner@test.com", "alias_bound_owner_auth"))
      .mutation(api.cleanup.deleteUnlinkedFriend, { friendMemberId: "alias_bound_friend" })
  ).rejects.toThrow("Friend cleanup is too large to complete safely");

  const state = await t.run(async (ctx) => ({
    friend: await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "alias-bound-owner@test.com").eq("member_id", "alias_bound_friend")
      )
      .unique(),
    group: await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "alias_bound_group"))
      .unique(),
    aliasRows: await ctx.db
      .query("member_aliases")
      .withIndex("by_source_account_and_alias", (q) =>
        q
          .eq("source_account_id", "alias_bound_owner_auth")
          .eq("alias_member_id", "alias_bound_friend")
      )
      .collect()
  }));
  expect(state.friend).not.toBeNull();
  expect(state.group?.members.map((member) => member.id)).toContain("alias_bound_friend");
  expect(state.aliasRows).toHaveLength(9);
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

test("cleanup.deleteUnlinkedFriend revokes group-less grouped-individual history", async () => {
  const t = convexTest(schema, modules);
  await markIdentityReady(t);

  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "grouped_cleanup_owner_auth",
      email: "grouped-cleanup-owner@test.com",
      display_name: "Owner",
      created_at: Date.now(),
      member_id: "grouped_cleanup_owner"
    });
    await ctx.db.insert("accounts", {
      id: "grouped_cleanup_active_auth",
      email: "grouped-cleanup-active@test.com",
      display_name: "Active participant",
      created_at: Date.now(),
      member_id: "grouped_cleanup_active"
    });
    await ctx.db.insert("account_friends", {
      account_email: "grouped-cleanup-owner@test.com",
      member_id: "grouped_cleanup_removed",
      name: "Removed participant",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      updated_at: Date.now()
    });

    for (const fixture of [
      {
        id: "grouped_cleanup_history",
        payer: "grouped_cleanup_owner",
        amount: 30
      },
      {
        id: "grouped_cleanup_removed_payer",
        payer: "grouped_cleanup_removed",
        amount: 20
      }
    ]) {
      await ctx.db.insert("expenses", {
        id: fixture.id,
        group_id: crypto.randomUUID(),
        context_kind: "grouped_individual",
        description: fixture.id,
        date: Date.now(),
        total_amount: fixture.amount,
        paid_by_member_id: fixture.payer,
        involved_member_ids: [
          "grouped_cleanup_owner",
          "grouped_cleanup_removed",
          "grouped_cleanup_active"
        ],
        splits: [
          {
            id: `${fixture.id}_owner_split`,
            member_id: "grouped_cleanup_owner",
            amount: fixture.amount / 3,
            is_settled: false
          },
          {
            id: `${fixture.id}_removed_split`,
            member_id: "grouped_cleanup_removed",
            amount: fixture.amount / 3,
            is_settled: false
          },
          {
            id: `${fixture.id}_active_split`,
            member_id: "grouped_cleanup_active",
            amount: fixture.amount / 3,
            is_settled: false
          }
        ],
        is_settled: false,
        owner_email: "grouped-cleanup-owner@test.com",
        owner_account_id: "grouped_cleanup_owner_auth",
        owner_id: ownerId,
        participant_member_ids: [
          "grouped_cleanup_owner",
          "grouped_cleanup_removed",
          "grouped_cleanup_active"
        ],
        participant_emails: [
          "grouped-cleanup-owner@test.com",
          "grouped-cleanup-active@test.com",
          "removed-stale@test.com"
        ],
        participants: [
          { member_id: "grouped_cleanup_owner", name: "Owner" },
          { member_id: "grouped_cleanup_removed", name: "Removed participant" },
          {
            member_id: "grouped_cleanup_active",
            name: "Active participant",
            linked_account_id: "grouped_cleanup_active_auth",
            linked_account_email: "grouped-cleanup-active@test.com"
          }
        ],
        created_at: Date.now(),
        updated_at: Date.now()
      });
      for (const userId of [
        "grouped_cleanup_owner_auth",
        "grouped_cleanup_active_auth",
        "grouped_cleanup_removed_stale_auth"
      ]) {
        await ctx.db.insert("user_expenses", {
          user_id: userId,
          expense_id: fixture.id,
          updated_at: Date.now()
        });
      }
    }
  });

  const owner = t.withIdentity(
    identity("grouped-cleanup-owner@test.com", "grouped_cleanup_owner_auth")
  );
  const cleanupResult = await owner.mutation(api.cleanup.deleteUnlinkedFriend, {
    friendMemberId: "grouped_cleanup_removed"
  });

  expect(cleanupResult).toMatchObject({
    groupsModified: 0,
    expensesDeleted: 1,
    expensesModified: 1
  });
  const result = await t.run(async (ctx) => {
    const retained = await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "grouped_cleanup_history"))
      .unique();
    const removedPayer = await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "grouped_cleanup_removed_payer"))
      .unique();
    const retainedVisibility = await ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) => q.eq("expense_id", "grouped_cleanup_history"))
      .collect();
    const deletedVisibility = await ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) => q.eq("expense_id", "grouped_cleanup_removed_payer"))
      .collect();
    return { retained, removedPayer, retainedVisibility, deletedVisibility };
  });

  expect(result.removedPayer).toBeNull();
  expect(result.deletedVisibility).toEqual([]);
  expect(result.retained?.total_amount).toBe(30);
  expect(result.retained?.splits).toHaveLength(3);
  expect(result.retained?.participants).toHaveLength(3);
  expect(result.retained?.participant_member_ids).toEqual([
    "grouped_cleanup_owner",
    "grouped_cleanup_active"
  ]);
  expect(result.retained?.involved_member_ids).toEqual([
    "grouped_cleanup_owner",
    "grouped_cleanup_active"
  ]);
  expect(result.retained?.inactive_participant_member_ids).toEqual(["grouped_cleanup_removed"]);
  expect(result.retained?.participant_emails.sort()).toEqual([
    "grouped-cleanup-active@test.com",
    "grouped-cleanup-owner@test.com"
  ]);
  expect(result.retainedVisibility.map((row) => row.user_id).sort()).toEqual([
    "grouped_cleanup_active_auth",
    "grouped_cleanup_owner_auth"
  ]);
});

test("cleanup.deleteUnlinkedFriend preserves group-less survivors across drifted identity surfaces", async () => {
  const t = convexTest(schema, modules);
  await markIdentityReady(t);

  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "drift_cleanup_owner_auth",
      email: "drift-cleanup-owner@test.com",
      display_name: "Owner",
      created_at: Date.now(),
      member_id: "drift_cleanup_owner"
    });
    for (const surface of ["involved", "split", "participant"] as const) {
      await ctx.db.insert("accounts", {
        id: `drift_cleanup_${surface}_auth`,
        email: `drift-cleanup-${surface}@test.com`,
        display_name: `${surface} survivor`,
        created_at: Date.now(),
        member_id: `drift_cleanup_${surface}`
      });
    }
    await ctx.db.insert("account_friends", {
      account_email: "drift-cleanup-owner@test.com",
      member_id: "drift_cleanup_removed",
      name: "Removed",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      updated_at: Date.now()
    });
    await ctx.db.insert("expenses", {
      id: "drift_cleanup_expense",
      group_id: crypto.randomUUID(),
      context_kind: "grouped_individual",
      description: "Drifted identity surfaces",
      date: Date.now(),
      total_amount: 30,
      paid_by_member_id: "drift_cleanup_owner",
      involved_member_ids: [
        "drift_cleanup_owner",
        "drift_cleanup_removed",
        "drift_cleanup_involved"
      ],
      splits: [
        {
          id: "drift_cleanup_owner_split",
          member_id: "drift_cleanup_owner",
          amount: 10,
          is_settled: false
        },
        {
          id: "drift_cleanup_removed_split",
          member_id: "drift_cleanup_removed",
          amount: 10,
          is_settled: false
        },
        {
          id: "drift_cleanup_survivor_split",
          member_id: "drift_cleanup_split",
          amount: 10,
          is_settled: false
        }
      ],
      is_settled: false,
      owner_email: "drift-cleanup-owner@test.com",
      owner_account_id: "drift_cleanup_owner_auth",
      owner_id: ownerId,
      participant_member_ids: ["drift_cleanup_owner", "drift_cleanup_removed"],
      participant_emails: ["drift-cleanup-owner@test.com", "removed-stale@test.com"],
      participants: [
        { member_id: "drift_cleanup_owner", name: "Owner" },
        { member_id: "drift_cleanup_removed", name: "Removed" },
        {
          member_id: "drift_cleanup_participant",
          name: "Participant survivor",
          linked_account_id: "drift_cleanup_participant_auth",
          linked_account_email: "drift-cleanup-participant@test.com"
        }
      ],
      created_at: Date.now(),
      updated_at: Date.now()
    });
    for (const userId of [
      "drift_cleanup_owner_auth",
      "drift_cleanup_involved_auth",
      "drift_cleanup_split_auth",
      "drift_cleanup_participant_auth",
      "drift_cleanup_removed_stale_auth"
    ]) {
      await ctx.db.insert("user_expenses", {
        user_id: userId,
        expense_id: "drift_cleanup_expense",
        updated_at: Date.now()
      });
    }
  });

  const owner = t.withIdentity(
    identity("drift-cleanup-owner@test.com", "drift_cleanup_owner_auth")
  );
  const cleanupResult = await owner.mutation(api.cleanup.deleteUnlinkedFriend, {
    friendMemberId: "drift_cleanup_removed"
  });
  expect(cleanupResult).toMatchObject({ expensesDeleted: 0, expensesModified: 1 });

  const result = await t.run(async (ctx) => {
    const expense = await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "drift_cleanup_expense"))
      .unique();
    const visibility = await ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) => q.eq("expense_id", "drift_cleanup_expense"))
      .collect();
    return { expense, visibility };
  });
  expect(result.expense?.total_amount).toBe(30);
  expect(result.expense?.splits).toHaveLength(3);
  expect(new Set(result.expense?.participant_member_ids)).toEqual(
    new Set([
      "drift_cleanup_owner",
      "drift_cleanup_involved",
      "drift_cleanup_split",
      "drift_cleanup_participant"
    ])
  );
  expect(new Set(result.expense?.involved_member_ids)).toEqual(
    new Set([
      "drift_cleanup_owner",
      "drift_cleanup_involved",
      "drift_cleanup_split",
      "drift_cleanup_participant"
    ])
  );
  expect(result.expense?.inactive_participant_member_ids).toEqual(["drift_cleanup_removed"]);
  expect(new Set(result.expense?.participant_emails)).toEqual(
    new Set([
      "drift-cleanup-owner@test.com",
      "drift-cleanup-involved@test.com",
      "drift-cleanup-split@test.com",
      "drift-cleanup-participant@test.com"
    ])
  );
  expect(new Set(result.visibility.map((row) => row.user_id))).toEqual(
    new Set([
      "drift_cleanup_owner_auth",
      "drift_cleanup_involved_auth",
      "drift_cleanup_split_auth",
      "drift_cleanup_participant_auth"
    ])
  );
});

test("cleanup.deleteUnlinkedFriend preserves a distinct participant with conflicting link metadata", async () => {
  const t = convexTest(schema, modules);
  await markIdentityReady(t);

  await t.run(async (ctx) => {
    const now = Date.now();
    const ownerId = await ctx.db.insert("accounts", {
      id: "conflicting_link_owner_auth",
      email: "conflicting-link-owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "conflicting_link_owner"
    });
    await ctx.db.insert("accounts", {
      id: "conflicting_link_other_auth",
      email: "conflicting-link-other@test.com",
      display_name: "Other account",
      created_at: now,
      member_id: "conflicting_link_other"
    });
    await ctx.db.insert("account_friends", {
      account_email: "conflicting-link-owner@test.com",
      member_id: "conflicting_link_removed",
      name: "Removed friend",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      updated_at: now
    });
    await ctx.db.insert("expenses", {
      id: "conflicting_link_cleanup_expense",
      group_id: "missing_group",
      context_kind: "grouped_individual",
      description: "Preserve distinct survivor",
      date: now,
      total_amount: 30,
      paid_by_member_id: "conflicting_link_owner",
      involved_member_ids: [
        "conflicting_link_owner",
        "conflicting_link_removed",
        "conflicting_link_survivor"
      ],
      splits: [
        {
          id: "conflicting_link_owner_split",
          member_id: "conflicting_link_owner",
          amount: 10,
          is_settled: false
        },
        {
          id: "conflicting_link_removed_split",
          member_id: "conflicting_link_removed",
          amount: 10,
          is_settled: false
        },
        {
          id: "conflicting_link_survivor_split",
          member_id: "conflicting_link_survivor",
          amount: 10,
          is_settled: false
        }
      ],
      is_settled: false,
      owner_email: "conflicting-link-owner@test.com",
      owner_account_id: "conflicting_link_owner_auth",
      owner_id: ownerId,
      participant_member_ids: [
        "conflicting_link_owner",
        "conflicting_link_removed",
        "conflicting_link_survivor"
      ],
      participant_emails: ["conflicting-link-owner@test.com", "conflicting-link-other@test.com"],
      participants: [
        { member_id: "conflicting_link_owner", name: "Owner" },
        { member_id: "conflicting_link_removed", name: "Removed friend" },
        {
          member_id: "conflicting_link_survivor",
          name: "Distinct survivor",
          linked_account_id: "conflicting_link_owner_auth",
          linked_account_email: "conflicting-link-other@test.com"
        }
      ],
      created_at: now,
      updated_at: now
    });
    await ctx.db.insert("user_expenses", {
      user_id: "conflicting_link_owner_auth",
      expense_id: "conflicting_link_cleanup_expense",
      updated_at: now
    });
  });

  const owner = t.withIdentity(
    identity("conflicting-link-owner@test.com", "conflicting_link_owner_auth")
  );
  await expect(
    owner.mutation(api.cleanup.deleteUnlinkedFriend, {
      friendMemberId: "conflicting_link_removed"
    })
  ).resolves.toMatchObject({ expensesDeleted: 0, expensesModified: 1 });

  const state = await t.run(async (ctx) => ({
    expense: await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "conflicting_link_cleanup_expense"))
      .unique(),
    visibility: await ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) => q.eq("expense_id", "conflicting_link_cleanup_expense"))
      .collect()
  }));
  expect(state.expense?.participant_member_ids).toEqual([
    "conflicting_link_owner",
    "conflicting_link_survivor"
  ]);
  expect(state.expense?.participant_emails).toEqual(["conflicting-link-owner@test.com"]);
  expect(state.visibility.map((row) => row.user_id)).toEqual(["conflicting_link_owner_auth"]);
});

test("cleanup.deleteUnlinkedFriend counts an authoritative owner with only inactive history", async () => {
  const t = convexTest(schema, modules);
  await markIdentityReady(t);

  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "inactive_owner_cleanup_auth",
      email: "inactive-owner-cleanup@test.com",
      display_name: "Owner",
      created_at: Date.now(),
      member_id: "inactive_owner_cleanup_canonical",
      alias_member_ids: ["inactive_owner_cleanup_alias"]
    });
    await ctx.db.insert("accounts", {
      id: "inactive_owner_survivor_auth",
      email: "inactive-owner-survivor@test.com",
      display_name: "Survivor",
      created_at: Date.now(),
      member_id: "inactive_owner_survivor"
    });
    await ctx.db.insert("account_friends", {
      account_email: "inactive-owner-cleanup@test.com",
      member_id: "inactive_owner_removed",
      name: "Removed",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      updated_at: Date.now()
    });
    await ctx.db.insert("expenses", {
      id: "inactive_owner_cleanup_expense",
      group_id: crypto.randomUUID(),
      context_kind: "grouped_individual",
      description: "Owner represented only by inactive alias",
      date: Date.now(),
      total_amount: 30,
      paid_by_member_id: "inactive_owner_cleanup_alias",
      involved_member_ids: [
        "inactive_owner_cleanup_alias",
        "inactive_owner_removed",
        "inactive_owner_survivor"
      ],
      splits: [
        {
          id: "inactive_owner_historical_split",
          member_id: "inactive_owner_cleanup_alias",
          amount: 10,
          is_settled: false
        },
        {
          id: "inactive_owner_removed_split",
          member_id: "inactive_owner_removed",
          amount: 10,
          is_settled: false
        },
        {
          id: "inactive_owner_survivor_split",
          member_id: "inactive_owner_survivor",
          amount: 10,
          is_settled: false
        }
      ],
      is_settled: false,
      owner_email: "inactive-owner-cleanup@test.com",
      owner_account_id: "inactive_owner_cleanup_auth",
      owner_id: ownerId,
      participant_member_ids: [
        "inactive_owner_cleanup_alias",
        "inactive_owner_removed",
        "inactive_owner_survivor"
      ],
      inactive_participant_member_ids: ["inactive_owner_cleanup_alias"],
      participant_emails: [
        "inactive-owner-cleanup@test.com",
        "inactive-owner-survivor@test.com",
        "removed-stale@test.com"
      ],
      participants: [
        { member_id: "inactive_owner_cleanup_alias", name: "Historical owner" },
        { member_id: "inactive_owner_removed", name: "Removed" },
        {
          member_id: "inactive_owner_survivor",
          name: "Survivor",
          linked_account_id: "inactive_owner_survivor_auth",
          linked_account_email: "inactive-owner-survivor@test.com"
        }
      ],
      created_at: Date.now(),
      updated_at: Date.now()
    });
    for (const userId of [
      "inactive_owner_cleanup_auth",
      "inactive_owner_survivor_auth",
      "inactive_owner_removed_stale_auth"
    ]) {
      await ctx.db.insert("user_expenses", {
        user_id: userId,
        expense_id: "inactive_owner_cleanup_expense",
        updated_at: Date.now()
      });
    }
  });

  const owner = t.withIdentity(
    identity("inactive-owner-cleanup@test.com", "inactive_owner_cleanup_auth")
  );
  const cleanupResult = await owner.mutation(api.cleanup.deleteUnlinkedFriend, {
    friendMemberId: "inactive_owner_removed"
  });
  expect(cleanupResult).toMatchObject({ expensesDeleted: 0, expensesModified: 1 });

  const result = await t.run(async (ctx) => {
    const expense = await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "inactive_owner_cleanup_expense"))
      .unique();
    const visibility = await ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) => q.eq("expense_id", "inactive_owner_cleanup_expense"))
      .collect();
    return { expense, visibility };
  });
  expect(result.expense?.total_amount).toBe(30);
  expect(result.expense?.splits).toHaveLength(3);
  expect(result.expense?.participant_member_ids).toEqual(["inactive_owner_survivor"]);
  expect(new Set(result.expense?.inactive_participant_member_ids)).toEqual(
    new Set(["inactive_owner_cleanup_alias", "inactive_owner_removed"])
  );
  expect(new Set(result.expense?.participant_emails)).toEqual(
    new Set(["inactive-owner-cleanup@test.com", "inactive-owner-survivor@test.com"])
  );
  expect(new Set(result.visibility.map((row) => row.user_id))).toEqual(
    new Set(["inactive_owner_cleanup_auth", "inactive_owner_survivor_auth"])
  );
});

test("cleanup.deleteUnlinkedFriend rejects conflicting legacy expense ownership", async () => {
  const t = convexTest(schema, modules);
  await markIdentityReady(t);

  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "legacy_cleanup_owner_auth",
      email: "legacy-cleanup-owner@test.com",
      display_name: "Owner",
      created_at: Date.now(),
      member_id: "legacy_cleanup_owner"
    });
    const conflictingOwnerId = await ctx.db.insert("accounts", {
      id: "legacy_cleanup_conflict_auth",
      email: "legacy-cleanup-conflict@test.com",
      display_name: "Conflict",
      created_at: Date.now(),
      member_id: "legacy_cleanup_conflict"
    });
    await ctx.db.insert("account_friends", {
      account_email: "legacy-cleanup-owner@test.com",
      member_id: "legacy_cleanup_removed",
      name: "Removed",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      updated_at: Date.now()
    });
    await ctx.db.insert("expenses", {
      id: "legacy_cleanup_conflicting_expense",
      group_id: crypto.randomUUID(),
      context_kind: "grouped_individual",
      description: "Conflicting owner tuple",
      date: Date.now(),
      total_amount: 10,
      paid_by_member_id: "legacy_cleanup_owner",
      involved_member_ids: ["legacy_cleanup_owner", "legacy_cleanup_removed"],
      splits: [
        {
          id: "legacy_cleanup_owner_split",
          member_id: "legacy_cleanup_owner",
          amount: 5,
          is_settled: false
        },
        {
          id: "legacy_cleanup_removed_split",
          member_id: "legacy_cleanup_removed",
          amount: 5,
          is_settled: false
        }
      ],
      is_settled: false,
      owner_email: "legacy-cleanup-owner@test.com",
      owner_account_id: "legacy_cleanup_owner_auth",
      owner_id: conflictingOwnerId,
      participant_member_ids: ["legacy_cleanup_owner", "legacy_cleanup_removed"],
      participant_emails: ["legacy-cleanup-owner@test.com"],
      participants: [
        { member_id: "legacy_cleanup_owner", name: "Owner" },
        { member_id: "legacy_cleanup_removed", name: "Removed" }
      ],
      created_at: Date.now(),
      updated_at: Date.now()
    });
  });

  const owner = t.withIdentity(
    identity("legacy-cleanup-owner@test.com", "legacy_cleanup_owner_auth")
  );
  await expect(
    owner.mutation(api.cleanup.deleteUnlinkedFriend, {
      friendMemberId: "legacy_cleanup_removed"
    })
  ).rejects.toThrow("Expense owner identity is inconsistent");

  const result = await t.run(async (ctx) => {
    const expense = await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "legacy_cleanup_conflicting_expense"))
      .unique();
    const friend = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q
          .eq("account_email", "legacy-cleanup-owner@test.com")
          .eq("member_id", "legacy_cleanup_removed")
      )
      .unique();
    return { expense, friend };
  });
  expect(result.expense).not.toBeNull();
  expect(result.friend).not.toBeNull();
});

test("cleanup.deleteUnlinkedFriend rejects a caller-owned group with a conflicting owner email", async () => {
  const t = convexTest(schema, modules);
  await markIdentityReady(t);

  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "group_tuple_owner_auth",
      email: "group-tuple-owner@test.com",
      display_name: "Owner",
      created_at: Date.now(),
      member_id: "group_tuple_owner"
    });
    await ctx.db.insert("account_friends", {
      account_email: "group-tuple-owner@test.com",
      member_id: "group_tuple_removed",
      name: "Removed",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      updated_at: Date.now()
    });
    await ctx.db.insert("groups", {
      id: "conflicting_owner_email_group",
      name: "Conflicting owner email",
      members: [
        { id: "group_tuple_owner", name: "Owner" },
        { id: "group_tuple_removed", name: "Removed" },
        { id: "group_tuple_survivor", name: "Survivor" }
      ],
      owner_email: "foreign-owner@test.com",
      owner_account_id: "group_tuple_owner_auth",
      owner_id: ownerId,
      created_at: Date.now(),
      updated_at: Date.now()
    });
  });

  await expect(
    t
      .withIdentity(identity("group-tuple-owner@test.com", "group_tuple_owner_auth"))
      .mutation(api.cleanup.deleteUnlinkedFriend, {
        friendMemberId: "group_tuple_removed"
      })
  ).rejects.toThrow("Cannot clean records with a conflicting owner identity");

  const state = await t.run(async (ctx) => ({
    friend: await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "group-tuple-owner@test.com").eq("member_id", "group_tuple_removed")
      )
      .unique(),
    group: await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "conflicting_owner_email_group"))
      .unique()
  }));
  expect(state.friend).not.toBeNull();
  expect(state.group?.members.map((member) => member.id)).toContain("group_tuple_removed");
});

test("cleanup.deleteLinkedFriend removes history referenced only by an owner-local alias", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "friend_member",
      local_alias_member_ids: ["historical_friend_member"],
      name: "Friend",
      profile_avatar_color: "#123456",
      has_linked_account: true,
      linked_account_id: "friend_auth",
      linked_account_email: "friend@test.com",
      updated_at: now
    });
    const groupRef = await ctx.db.insert("groups", {
      id: "historical_direct_group",
      name: "Historical direct group",
      is_direct: true,
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "historical_friend_member", name: "Friend" }
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      created_at: now,
      updated_at: now
    });
    const expenseBase = {
      description: "Historical linked expense",
      date: now,
      total_amount: 2,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "historical_friend_member"],
      splits: [
        { id: "owner_split", member_id: "owner_member", amount: 1, is_settled: false },
        {
          id: "friend_split",
          member_id: "historical_friend_member",
          amount: 1,
          is_settled: false
        }
      ],
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      participant_member_ids: ["owner_member", "historical_friend_member"],
      participant_emails: ["owner@test.com"],
      participants: [
        { member_id: "owner_member", name: "Owner" },
        { member_id: "historical_friend_member", name: "Friend" }
      ],
      created_at: now,
      updated_at: now
    };
    await ctx.db.insert("expenses", {
      ...expenseBase,
      id: "historical_group_ref_expense",
      group_id: "stale_group_id",
      group_ref: groupRef
    });
    await ctx.db.insert("expenses", {
      ...expenseBase,
      id: "historical_missing_group_expense",
      group_id: "missing_group"
    });
  });

  await markIdentityReady(t);
  const result = await t
    .withIdentity(identity("owner@test.com", "owner_auth"))
    .mutation(api.cleanup.deleteLinkedFriend, { friendMemberId: "friend_member" });

  expect(result.directGroupDeleted).toBe(true);
  expect(result.expensesDeleted).toBe(2);
  expect(
    await t.run(async (ctx) =>
      ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", "historical_direct_group"))
        .unique()
    )
  ).toBeNull();
  expect(await t.run(async (ctx) => ctx.db.query("expenses").collect())).toHaveLength(0);
});

test("cleanup.deleteUnlinkedFriend removes history referenced only by an owner-local alias", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "friend_member",
      local_alias_member_ids: ["historical_friend_member"],
      name: "Friend",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      updated_at: now
    });
    const groupId = await ctx.db.insert("groups", {
      id: "historical_shared_group",
      name: "Historical shared group",
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "historical_friend_member", name: "Friend" }
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      created_at: now,
      updated_at: now
    });
    await ctx.db.insert("expenses", {
      id: "historical_shared_expense",
      group_id: "historical_shared_group",
      group_ref: groupId,
      description: "Historical expense",
      date: now,
      total_amount: 20,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "historical_friend_member"],
      splits: [
        { id: "owner_split", member_id: "owner_member", amount: 10, is_settled: false },
        {
          id: "friend_split",
          member_id: "historical_friend_member",
          amount: 10,
          is_settled: false
        }
      ],
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      participant_member_ids: ["owner_member", "historical_friend_member"],
      participant_emails: ["owner@test.com"],
      participants: [
        { member_id: "owner_member", name: "Owner" },
        { member_id: "historical_friend_member", name: "Friend" }
      ],
      created_at: now,
      updated_at: now
    });
  });

  await markIdentityReady(t);
  const result = await t
    .withIdentity(identity("owner@test.com", "owner_auth"))
    .mutation(api.cleanup.deleteUnlinkedFriend, { friendMemberId: "friend_member" });

  expect(result.groupsModified).toBe(1);
  expect(result.expensesDeleted).toBe(1);
  const state = await t.run(async (ctx) => ({
    group: await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "historical_shared_group"))
      .unique(),
    expense: await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "historical_shared_expense"))
      .unique()
  }));
  expect(state.group).toBeNull();
  expect(state.expense).toBeNull();
});

test("cleanup.deleteUnlinkedFriend cleans owner-scoped group-ref and missing-group alias expenses", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "friend_member",
      local_alias_member_ids: ["historical_alias"],
      name: "Friend",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      updated_at: now
    });
    const groupRef = await ctx.db.insert("groups", {
      id: "legacy_group",
      name: "Legacy group",
      members: [
        { id: "owner_member", name: "Owner", is_current_user: true },
        { id: "historical_alias", name: "Friend" },
        { id: "other_member", name: "Other" }
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      created_at: now,
      updated_at: now
    });
    const expenseBase = {
      description: "Legacy expense",
      date: now,
      total_amount: 3,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "historical_alias", "other_member"],
      splits: [
        { id: "owner_split", member_id: "owner_member", amount: 1, is_settled: false },
        { id: "friend_split", member_id: "historical_alias", amount: 1, is_settled: false },
        { id: "other_split", member_id: "other_member", amount: 1, is_settled: false }
      ],
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      participant_member_ids: ["owner_member", "historical_alias", "other_member"],
      participant_emails: ["owner@test.com"],
      participants: [
        { member_id: "owner_member", name: "Owner" },
        { member_id: "historical_alias", name: "Friend" },
        { member_id: "other_member", name: "Other" }
      ],
      created_at: now,
      updated_at: now
    };
    await ctx.db.insert("expenses", {
      ...expenseBase,
      id: "group_ref_only_expense",
      group_id: "stale_group_id",
      group_ref: groupRef
    });
    await ctx.db.insert("expenses", {
      ...expenseBase,
      id: "missing_group_expense",
      group_id: "missing_group"
    });
    for (const expenseId of ["group_ref_only_expense", "missing_group_expense"]) {
      await ctx.db.insert("user_expenses", {
        user_id: "owner_auth",
        expense_id: expenseId,
        updated_at: now
      });
    }
  });

  await markIdentityReady(t);
  const result = await t
    .withIdentity(identity("owner@test.com", "owner_auth"))
    .mutation(api.cleanup.deleteUnlinkedFriend, { friendMemberId: "friend_member" });

  expect(result.groupsModified).toBe(1);
  expect(result.expensesModified).toBe(2);
  const state = await t.run(async (ctx) => ({
    group: await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "legacy_group"))
      .unique(),
    expenses: await ctx.db.query("expenses").collect()
  }));
  expect(state.group?.members.map((member) => member.id)).not.toContain("historical_alias");
  expect(state.expenses).toHaveLength(2);
  for (const expense of state.expenses) {
    expect(expense.participant_member_ids).not.toContain("historical_alias");
    expect(expense.involved_member_ids).not.toContain("historical_alias");
    expect(expense.splits.map((split) => split.member_id)).toContain("historical_alias");
    expect(expense.participants.map((participant) => participant.member_id)).toContain(
      "historical_alias"
    );
  }
});

test("cleanup.deleteUnlinkedFriend fails closed on a foreign group-ref expense", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    const foreignId = await ctx.db.insert("accounts", {
      id: "foreign_auth",
      email: "foreign@test.com",
      display_name: "Foreign",
      created_at: now,
      member_id: "foreign_member"
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "friend_member",
      name: "Friend",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      updated_at: now
    });
    const groupRef = await ctx.db.insert("groups", {
      id: "shared_group",
      name: "Shared",
      members: [
        { id: "owner_member", name: "Owner" },
        { id: "friend_member", name: "Friend" },
        { id: "foreign_member", name: "Foreign" }
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      created_at: now,
      updated_at: now
    });
    await ctx.db.insert("expenses", {
      id: "foreign_group_ref_expense",
      group_id: "stale_group_id",
      group_ref: groupRef,
      description: "Foreign expense",
      date: now,
      total_amount: 2,
      paid_by_member_id: "foreign_member",
      involved_member_ids: ["foreign_member", "friend_member"],
      splits: [{ id: "split", member_id: "friend_member", amount: 2, is_settled: false }],
      is_settled: false,
      owner_email: "foreign@test.com",
      owner_account_id: "foreign_auth",
      owner_id: foreignId,
      participant_member_ids: ["foreign_member", "friend_member"],
      participant_emails: ["foreign@test.com"],
      participants: [
        { member_id: "foreign_member", name: "Foreign" },
        { member_id: "friend_member", name: "Friend" }
      ],
      created_at: now,
      updated_at: now
    });
  });

  await markIdentityReady(t);
  await expect(
    t
      .withIdentity(identity("owner@test.com", "owner_auth"))
      .mutation(api.cleanup.deleteUnlinkedFriend, { friendMemberId: "friend_member" })
  ).rejects.toThrow("foreign-owned expenses");

  const state = await t.run(async (ctx) => ({
    friend: await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "owner@test.com").eq("member_id", "friend_member")
      )
      .unique(),
    group: await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "shared_group"))
      .unique()
  }));
  expect(state.friend).not.toBeNull();
  expect(state.group?.members.map((member) => member.id)).toContain("friend_member");
});

test("cleanup.deleteUnlinkedFriend caps aggregate attached expenses before writes", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  let ownerId: any;
  await t.run(async (ctx) => {
    ownerId = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    const foreignId = await ctx.db.insert("accounts", {
      id: "foreign_auth",
      email: "foreign@test.com",
      display_name: "Foreign",
      created_at: now,
      member_id: "foreign_member"
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "friend_member",
      name: "Friend",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      updated_at: now
    });

    for (let groupIndex = 0; groupIndex < 2; groupIndex += 1) {
      const groupId = `aggregate_group_${groupIndex}`;
      const groupRef = await ctx.db.insert("groups", {
        id: groupId,
        name: `Aggregate ${groupIndex}`,
        members: [
          { id: "owner_member", name: "Owner" },
          { id: "friend_member", name: "Friend" },
          { id: `other_member_${groupIndex}`, name: "Other" }
        ],
        owner_email: "owner@test.com",
        owner_account_id: "owner_auth",
        owner_id: ownerId,
        created_at: now,
        updated_at: now
      });
      for (let expenseIndex = 0; expenseIndex < 300; expenseIndex += 1) {
        await ctx.db.insert("expenses", {
          id: `aggregate_expense_${groupIndex}_${expenseIndex}`,
          group_id: groupId,
          group_ref: groupRef,
          description: "Foreign history",
          date: now,
          total_amount: 1,
          paid_by_member_id: "foreign_member",
          involved_member_ids: ["foreign_member"],
          splits: [
            {
              id: `split_${groupIndex}_${expenseIndex}`,
              member_id: "foreign_member",
              amount: 1,
              is_settled: false
            }
          ],
          is_settled: false,
          owner_email: "foreign@test.com",
          owner_account_id: "foreign_auth",
          owner_id: foreignId,
          participant_member_ids: ["foreign_member"],
          participant_emails: ["foreign@test.com"],
          participants: [{ member_id: "foreign_member", name: "Foreign" }],
          created_at: now,
          updated_at: now
        });
      }
    }
  });

  await markIdentityReady(t);
  await expect(
    t
      .withIdentity(identity("owner@test.com", "owner_auth"))
      .mutation(api.cleanup.deleteUnlinkedFriend, { friendMemberId: "friend_member" })
  ).rejects.toThrow("Friend cleanup is too large to complete safely");

  const state = await t.run(async (ctx) => ({
    friend: await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "owner@test.com").eq("member_id", "friend_member")
      )
      .unique(),
    groups: await ctx.db
      .query("groups")
      .withIndex("by_owner_id", (q) => q.eq("owner_id", ownerId))
      .collect()
  }));
  expect(state.friend).not.toBeNull();
  expect(state.groups).toHaveLength(2);
  expect(
    state.groups.every((group) => group.members.some((member) => member.id === "friend_member"))
  ).toBe(true);
}, 30_000);

test("cleanup.deleteUnlinkedFriend bounds owned-group bytes before writes", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  const largeText = "x".repeat(400 * 1024);
  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "friend_member",
      name: "Friend",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      updated_at: now
    });
    for (let index = 0; index < 22; index += 1) {
      await ctx.db.insert("groups", {
        id: `large_group_${index}`,
        name: `Large ${index}`,
        members: [{ id: `unrelated_${index}`, name: largeText }],
        owner_email: "owner@test.com",
        owner_account_id: "owner_auth",
        owner_id: ownerId,
        created_at: now,
        updated_at: now
      });
    }
  });
  await markIdentityReady(t);

  await expect(
    t
      .withIdentity(identity("owner@test.com", "owner_auth"))
      .mutation(api.cleanup.deleteUnlinkedFriend, { friendMemberId: "friend_member" })
  ).rejects.toThrow("Friend cleanup is too large to complete safely");
  expect(await t.run(async (ctx) => ctx.db.query("account_friends").collect())).toHaveLength(1);
});

test("cleanup.deleteUnlinkedFriend bounds owned-expense bytes before writes", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  const largeText = "x".repeat(400 * 1024);
  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "friend_member",
      name: "Friend",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      updated_at: now
    });
    for (let index = 0; index < 22; index += 1) {
      await ctx.db.insert("expenses", {
        id: `large_expense_${index}`,
        group_id: `missing_group_${index}`,
        description: largeText,
        date: now,
        total_amount: 1,
        paid_by_member_id: "owner_member",
        involved_member_ids: ["owner_member"],
        splits: [{ id: `split_${index}`, member_id: "owner_member", amount: 1, is_settled: false }],
        is_settled: false,
        owner_email: "owner@test.com",
        owner_account_id: "owner_auth",
        owner_id: ownerId,
        participant_member_ids: ["owner_member"],
        participant_emails: ["owner@test.com"],
        participants: [{ member_id: "owner_member", name: "Owner" }],
        created_at: now,
        updated_at: now
      });
    }
  });
  await markIdentityReady(t);

  await expect(
    t
      .withIdentity(identity("owner@test.com", "owner_auth"))
      .mutation(api.cleanup.deleteUnlinkedFriend, { friendMemberId: "friend_member" })
  ).rejects.toThrow("Friend cleanup is too large to complete safely");
  expect(await t.run(async (ctx) => ctx.db.query("account_friends").collect())).toHaveLength(1);
});

test("cleanup.deleteUnlinkedFriend bounds attached-expense bytes before writes", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  const largeText = "x".repeat(400 * 1024);
  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    const foreignId = await ctx.db.insert("accounts", {
      id: "foreign_auth",
      email: "foreign@test.com",
      display_name: "Foreign",
      created_at: now,
      member_id: "foreign_member"
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "friend_member",
      name: "Friend",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      updated_at: now
    });
    const groupRef = await ctx.db.insert("groups", {
      id: "attached_group",
      name: "Attached",
      members: [
        { id: "owner_member", name: "Owner" },
        { id: "friend_member", name: "Friend" },
        { id: "other_member", name: "Other" }
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      created_at: now,
      updated_at: now
    });
    for (let index = 0; index < 22; index += 1) {
      await ctx.db.insert("expenses", {
        id: `large_attached_expense_${index}`,
        group_id: "attached_group",
        group_ref: groupRef,
        description: largeText,
        date: now,
        total_amount: 1,
        paid_by_member_id: "foreign_member",
        involved_member_ids: ["foreign_member"],
        splits: [
          { id: `split_${index}`, member_id: "foreign_member", amount: 1, is_settled: false }
        ],
        is_settled: false,
        owner_email: "foreign@test.com",
        owner_account_id: "foreign_auth",
        owner_id: foreignId,
        participant_member_ids: ["foreign_member"],
        participant_emails: ["foreign@test.com"],
        participants: [{ member_id: "foreign_member", name: "Foreign" }],
        created_at: now,
        updated_at: now
      });
    }
  });
  await markIdentityReady(t);

  await expect(
    t
      .withIdentity(identity("owner@test.com", "owner_auth"))
      .mutation(api.cleanup.deleteUnlinkedFriend, { friendMemberId: "friend_member" })
  ).rejects.toThrow("Friend cleanup is too large to complete safely");
  expect(await t.run(async (ctx) => ctx.db.query("account_friends").collect())).toHaveLength(1);
});

test("cleanup.deleteUnlinkedFriend bounds visibility rows before writes", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  const excessiveVisibilityRows = 513;
  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "friend_member",
      name: "Friend",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      updated_at: now
    });
    const groupRef = await ctx.db.insert("groups", {
      id: "visibility_heavy_group",
      name: "Visibility Heavy",
      members: [
        { id: "owner_member", name: "Owner" },
        { id: "friend_member", name: "Friend" }
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      created_at: now,
      updated_at: now
    });
    await ctx.db.insert("expenses", {
      id: "visibility_heavy_expense",
      group_id: "visibility_heavy_group",
      group_ref: groupRef,
      description: "Visibility Heavy",
      date: now,
      total_amount: 2,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "friend_member"],
      splits: [
        { id: "owner_split", member_id: "owner_member", amount: 1, is_settled: false },
        { id: "friend_split", member_id: "friend_member", amount: 1, is_settled: false }
      ],
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      participant_member_ids: ["owner_member", "friend_member"],
      participant_emails: ["owner@test.com"],
      participants: [
        { member_id: "owner_member", name: "Owner" },
        { member_id: "friend_member", name: "Friend" }
      ],
      created_at: now,
      updated_at: now
    });
    for (let index = 0; index < excessiveVisibilityRows; index += 1) {
      await ctx.db.insert("user_expenses", {
        user_id: `viewer_${index}`,
        expense_id: "visibility_heavy_expense",
        updated_at: now
      });
    }
  });
  await markIdentityReady(t);

  await expect(
    t
      .withIdentity(identity("owner@test.com", "owner_auth"))
      .mutation(api.cleanup.deleteUnlinkedFriend, { friendMemberId: "friend_member" })
  ).rejects.toThrow("Friend cleanup is too large to complete safely");

  const state = await t.run(async (ctx) => ({
    friend: await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "owner@test.com").eq("member_id", "friend_member")
      )
      .unique(),
    group: await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "visibility_heavy_group"))
      .unique(),
    expense: await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "visibility_heavy_expense"))
      .unique(),
    visibility: await ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) => q.eq("expense_id", "visibility_heavy_expense"))
      .collect()
  }));
  expect(state.friend).not.toBeNull();
  expect(state.group).not.toBeNull();
  expect(state.expense).not.toBeNull();
  expect(state.visibility).toHaveLength(excessiveVisibilityRows);
}, 30_000);

test("cleanup.deleteUnlinkedFriend bounds participant identity work before writes", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  const unrelatedMemberIds = Array.from({ length: 140 }, (_, index) => `ghost_${index}`);
  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "friend_member",
      name: "Friend",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      updated_at: now
    });
    const groupRef = await ctx.db.insert("groups", {
      id: "identity_heavy_group",
      name: "Identity Heavy",
      members: [
        { id: "owner_member", name: "Owner" },
        { id: "friend_member", name: "Friend" },
        ...unrelatedMemberIds.map((memberId) => ({ id: memberId, name: memberId }))
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      created_at: now,
      updated_at: now
    });
    const participantMemberIds = ["owner_member", "friend_member", ...unrelatedMemberIds];
    await ctx.db.insert("expenses", {
      id: "identity_heavy_expense",
      group_id: "identity_heavy_group",
      group_ref: groupRef,
      description: "Identity Heavy",
      date: now,
      total_amount: participantMemberIds.length,
      paid_by_member_id: "owner_member",
      involved_member_ids: participantMemberIds,
      splits: participantMemberIds.map((memberId, index) => ({
        id: `split_${index}`,
        member_id: memberId,
        amount: 1,
        is_settled: false
      })),
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      participant_member_ids: participantMemberIds,
      participant_emails: ["owner@test.com"],
      participants: participantMemberIds.map((memberId) => ({
        member_id: memberId,
        name: memberId
      })),
      created_at: now,
      updated_at: now
    });
    await ctx.db.insert("user_expenses", {
      user_id: "owner_auth",
      expense_id: "identity_heavy_expense",
      updated_at: now
    });
  });
  await markIdentityReady(t);

  await expect(
    t
      .withIdentity(identity("owner@test.com", "owner_auth"))
      .mutation(api.cleanup.deleteUnlinkedFriend, { friendMemberId: "friend_member" })
  ).rejects.toThrow("Friend cleanup is too large to complete safely");

  const state = await t.run(async (ctx) => ({
    friend: await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "owner@test.com").eq("member_id", "friend_member")
      )
      .unique(),
    group: await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "identity_heavy_group"))
      .unique(),
    expense: await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "identity_heavy_expense"))
      .unique()
  }));
  expect(state.friend).not.toBeNull();
  expect(state.group?.members.some((member) => member.id === "friend_member")).toBe(true);
  expect(state.expense?.participant_member_ids).toContain("friend_member");
});

async function createTransitiveAliasCleanupScenario(chainCount: number) {
  const t = convexTest(schema, modules);
  const now = Date.now();
  const chainedParticipantIds = Array.from(
    { length: chainCount },
    (_, index) => `chain_${index}_0`
  );

  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "Owner",
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "friend_member",
      name: "Friend",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      updated_at: now
    });

    for (
      let participantIndex = 0;
      participantIndex < chainedParticipantIds.length;
      participantIndex += 1
    ) {
      for (let depth = 0; depth < 19; depth += 1) {
        await ctx.db.insert("member_aliases", {
          alias_member_id: `chain_${participantIndex}_${depth}`,
          canonical_member_id: `chain_${participantIndex}_${depth + 1}`,
          account_email: "owner@test.com",
          materialization_source: "account_alias",
          source_account_id: `chain_account_${participantIndex}`,
          created_at: now
        });
      }
    }

    const participantMemberIds = ["owner_member", "friend_member", ...chainedParticipantIds];
    const groupRef = await ctx.db.insert("groups", {
      id: "transitive_identity_group",
      name: "Transitive Identity",
      members: participantMemberIds.map((memberId) => ({ id: memberId, name: memberId })),
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      created_at: now,
      updated_at: now
    });
    await ctx.db.insert("expenses", {
      id: "transitive_identity_expense",
      group_id: "transitive_identity_group",
      group_ref: groupRef,
      description: "Transitive Identity",
      date: now,
      total_amount: participantMemberIds.length,
      paid_by_member_id: "owner_member",
      involved_member_ids: participantMemberIds,
      splits: participantMemberIds.map((memberId, index) => ({
        id: `split_${index}`,
        member_id: memberId,
        amount: 1,
        is_settled: false
      })),
      is_settled: false,
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      participant_member_ids: participantMemberIds,
      participant_emails: ["owner@test.com"],
      participants: participantMemberIds.map((memberId) => ({
        member_id: memberId,
        name: memberId
      })),
      created_at: now,
      updated_at: now
    });
  });
  await markIdentityReady(t);
  return t;
}

test("cleanup.deleteUnlinkedFriend avoids repeated readiness reads across alias hops", async () => {
  const t = await createTransitiveAliasCleanupScenario(10);

  await expect(
    t
      .withIdentity(identity("owner@test.com", "owner_auth"))
      .mutation(api.cleanup.deleteUnlinkedFriend, { friendMemberId: "friend_member" })
  ).resolves.toMatchObject({ success: true, expensesModified: 1 });
});

test("cleanup.deleteUnlinkedFriend bounds aggregate transitive alias resolution before writes", async () => {
  const t = await createTransitiveAliasCleanupScenario(14);

  await expect(
    t
      .withIdentity(identity("owner@test.com", "owner_auth"))
      .mutation(api.cleanup.deleteUnlinkedFriend, { friendMemberId: "friend_member" })
  ).rejects.toThrow("Friend cleanup is too large to complete safely");

  const state = await t.run(async (ctx) => ({
    friend: await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "owner@test.com").eq("member_id", "friend_member")
      )
      .unique(),
    group: await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "transitive_identity_group"))
      .unique(),
    expense: await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", "transitive_identity_expense"))
      .unique()
  }));
  expect(state.friend).not.toBeNull();
  expect(state.group?.members.some((member) => member.id === "friend_member")).toBe(true);
  expect(state.expense?.participant_member_ids).toContain("friend_member");
});

test("cleanup.deleteUnlinkedFriend accounts repeated owner-document rows before writes", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();
  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@test.com",
      display_name: "O".repeat(300_000),
      created_at: now,
      member_id: "owner_member"
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@test.com",
      member_id: "friend_member",
      name: "Friend",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      updated_at: now
    });
    const groupRef = await ctx.db.insert("groups", {
      id: "owner_document_heavy_group",
      name: "Owner Document Heavy",
      members: [
        { id: "owner_member", name: "Owner" },
        { id: "friend_member", name: "Friend" },
        { id: "ghost_member", name: "Ghost" }
      ],
      owner_email: "owner@test.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      created_at: now,
      updated_at: now
    });
    for (let index = 0; index < 28; index += 1) {
      await ctx.db.insert("expenses", {
        id: `owner_document_heavy_expense_${index}`,
        group_id: "owner_document_heavy_group",
        group_ref: groupRef,
        description: `Owner Document Heavy ${index}`,
        date: now,
        total_amount: 3,
        paid_by_member_id: "owner_member",
        involved_member_ids: ["owner_member", "friend_member", "ghost_member"],
        splits: [
          { id: `owner_split_${index}`, member_id: "owner_member", amount: 1, is_settled: false },
          {
            id: `friend_split_${index}`,
            member_id: "friend_member",
            amount: 1,
            is_settled: false
          },
          { id: `ghost_split_${index}`, member_id: "ghost_member", amount: 1, is_settled: false }
        ],
        is_settled: false,
        owner_email: "owner@test.com",
        owner_account_id: "owner_auth",
        owner_id: ownerId,
        participant_member_ids: ["owner_member", "friend_member", "ghost_member"],
        participant_emails: ["owner@test.com"],
        participants: [
          { member_id: "owner_member", name: "Owner" },
          { member_id: "friend_member", name: "Friend" },
          { member_id: "ghost_member", name: "Ghost" }
        ],
        created_at: now,
        updated_at: now
      });
    }
  });
  await markIdentityReady(t);

  await expect(
    t
      .withIdentity(identity("owner@test.com", "owner_auth"))
      .mutation(api.cleanup.deleteUnlinkedFriend, { friendMemberId: "friend_member" })
  ).rejects.toThrow("Friend cleanup is too large to complete safely");

  const state = await t.run(async (ctx) => ({
    friend: await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "owner@test.com").eq("member_id", "friend_member")
      )
      .unique(),
    group: await ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "owner_document_heavy_group"))
      .unique(),
    expenses: await ctx.db
      .query("expenses")
      .withIndex("by_group_id", (q) => q.eq("group_id", "owner_document_heavy_group"))
      .collect()
  }));
  expect(state.friend).not.toBeNull();
  expect(state.group?.members.some((member) => member.id === "friend_member")).toBe(true);
  expect(state.expenses).toHaveLength(28);
  expect(
    state.expenses.every((expense) => expense.participant_member_ids.includes("friend_member"))
  ).toBe(true);
}, 30_000);

test("cleanup.selfDeleteAccount removes account PII, preserves shared history, and is idempotent", async () => {
  const t = convexTest(schema, modules);

  await t.run(async (ctx) => {
    const friendDoc = await ctx.db.insert("accounts", {
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
    await ctx.db.insert("sync_materialization_state", {
      key: "group_visibility_v1",
      status: "ready",
      processed: 0,
      updated_at: Date.now()
    });
    await ctx.db.insert("cleanup_email_materialization_state", {
      key: "cleanup_email_canonicalization_v1",
      status: "ready",
      phase: "complete",
      processed: 0,
      retry_count: 0,
      updated_at: Date.now()
    });

    const foreignOwnedGroup = await ctx.db.insert("groups", {
      id: "foreign_owned_shared_group",
      name: "Foreign owned shared group",
      is_direct: false,
      members: [
        {
          id: "owner_alias",
          name: "Owner Private Name",
          profile_image_url: "https://example.com/private-owner.png",
          profile_avatar_color: "#ABCDEF",
          is_current_user: true
        },
        { id: "friend_member", name: "Friend" }
      ],
      owner_email: "friend@test.com",
      owner_account_id: "friend_auth",
      owner_id: friendDoc,
      created_at: Date.now(),
      updated_at: Date.now()
    });
    await ctx.db.insert("group_visibility", {
      account_id: ownerDoc,
      group_id: foreignOwnedGroup,
      group_updated_at: Date.now(),
      created_at: Date.now(),
      updated_at: Date.now()
    });
    await ctx.db.insert("group_visibility", {
      account_id: friendDoc,
      group_id: foreignOwnedGroup,
      group_updated_at: Date.now(),
      created_at: Date.now(),
      updated_at: Date.now()
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
  await expect(ownerCtx.query(api.cleanup.selfDeletionStatus, {})).resolves.toMatchObject({
    completed: false,
    inProgress: false
  });
  let result = await ownerCtx.mutation(api.cleanup.selfDeleteAccount, {
    clientCapability: "bounded_progress_v1"
  });
  const progressTokens = new Set<string>();
  for (let attempt = 0; !result.success && attempt < 100; attempt += 1) {
    expect(result.inProgress).toBe(true);
    expect(progressTokens.has(result.progressToken)).toBe(false);
    progressTokens.add(result.progressToken);
    result = await ownerCtx.mutation(api.cleanup.selfDeleteAccount, {
      clientCapability: "bounded_progress_v1"
    });
  }
  expect(result.success).toBe(true);
  expect(result.state).toBe("deleted");
  expect(result.expensesPreserved).toBe(true);
  await expect(ownerCtx.query(api.cleanup.selfDeletionStatus, {})).resolves.toMatchObject({
    completed: true,
    inProgress: false
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

  const foreignOwnedGroup = await t.run(async (ctx) =>
    ctx.db
      .query("groups")
      .withIndex("by_client_id", (q) => q.eq("id", "foreign_owned_shared_group"))
      .unique()
  );
  const deletedForeignMember = foreignOwnedGroup?.members.find(
    (member) => member.id === "owner_alias"
  );
  expect(deletedForeignMember).toEqual({ id: "owner_alias", name: "Deleted User" });

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

  const retry = await ownerCtx.mutation(api.cleanup.selfDeleteAccount, {
    clientCapability: "bounded_progress_v1"
  });
  expect(retry).toMatchObject({
    success: true,
    state: "already_deleted",
    requestId: "owner_auth",
    expensesPreserved: true
  });
});
