import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "./setup";

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

describe("Security Authorization", () => {
  test("groups.create denies overwriting an existing group by non-owner", async () => {
    const t = convexTest(schema, modules);

    await t.run(async (ctx) => {
      const ownerDoc = await ctx.db.insert("accounts", {
        id: "owner_id",
        email: "owner@test.com",
        display_name: "Owner",
        created_at: Date.now(),
        member_id: "owner_member"
      });
      await ctx.db.insert("accounts", {
        id: "attacker_id",
        email: "attacker@test.com",
        display_name: "Attacker",
        created_at: Date.now(),
        member_id: "attacker_member"
      });

      await ctx.db.insert("groups", {
        id: "group_shared_id",
        name: "Original Group Name",
        members: [
          { id: "owner_member", name: "Owner", is_current_user: true },
          { id: "attacker_member", name: "Attacker" }
        ],
        owner_email: "owner@test.com",
        owner_account_id: "owner_id",
        owner_id: ownerDoc,
        created_at: Date.now(),
        updated_at: Date.now(),
        is_direct: false
      });
    });

    const attackerCtx = t.withIdentity(identity("attacker@test.com", "attacker_id"));
    await expect(
      attackerCtx.mutation(api.groups.create, {
        id: "group_shared_id",
        name: "Hacked Group Name",
        members: [{ id: "attacker_member", name: "Attacker" }],
        is_direct: false
      })
    ).rejects.toThrow("Forbidden");

    const group = await t.run(async (ctx) =>
      ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", "group_shared_id"))
        .unique()
    );
    expect(group?.name).toBe("Original Group Name");
  });

  test("groups.deleteGroup cascades expense and user_expenses cleanup", async () => {
    const t = convexTest(schema, modules);

    await t.run(async (ctx) => {
      const ownerDoc = await ctx.db.insert("accounts", {
        id: "owner_id",
        email: "owner@test.com",
        display_name: "Owner",
        created_at: Date.now(),
        member_id: "owner_member"
      });
      const groupDoc = await ctx.db.insert("groups", {
        id: "group_delete_me",
        name: "Delete Me",
        members: [{ id: "owner_member", name: "Owner", is_current_user: true }],
        owner_email: "owner@test.com",
        owner_account_id: "owner_id",
        owner_id: ownerDoc,
        created_at: Date.now(),
        updated_at: Date.now(),
        is_direct: false
      });
      await ctx.db.insert("expenses", {
        id: "expense_delete_me",
        group_id: "group_delete_me",
        group_ref: groupDoc,
        description: "Should be deleted",
        date: Date.now(),
        total_amount: 20,
        paid_by_member_id: "owner_member",
        involved_member_ids: ["owner_member"],
        splits: [{ id: "s1", member_id: "owner_member", amount: 20, is_settled: false }],
        is_settled: false,
        owner_email: "owner@test.com",
        owner_account_id: "owner_id",
        owner_id: ownerDoc,
        participant_member_ids: ["owner_member"],
        participant_emails: ["owner@test.com"],
        participants: [{ member_id: "owner_member", name: "Owner" }],
        created_at: Date.now(),
        updated_at: Date.now()
      });
      await ctx.db.insert("user_expenses", {
        user_id: "owner_id",
        expense_id: "expense_delete_me",
        updated_at: Date.now()
      });
    });

    const ownerCtx = t.withIdentity(identity("owner@test.com", "owner_id"));
    await ownerCtx.mutation(api.groups.deleteGroup, { id: "group_delete_me" });

    const [group, expense, userExpenses] = await t.run(async (ctx) => {
      const g = await ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", "group_delete_me"))
        .unique();
      const e = await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", "expense_delete_me"))
        .unique();
      const ue = await ctx.db
        .query("user_expenses")
        .withIndex("by_expense_id", (q) => q.eq("expense_id", "expense_delete_me"))
        .collect();
      return [g, e, ue] as const;
    });

    expect(group).toBeNull();
    expect(expense).toBeNull();
    expect(userExpenses).toHaveLength(0);
  });

  test("users.updateLinkedMemberId blocks canonical member_id reassignment", async () => {
    const t = convexTest(schema, modules);

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "user_id",
        email: "user@test.com",
        display_name: "User",
        created_at: Date.now(),
        member_id: "member_original"
      });
    });

    const userCtx = t.withIdentity(identity("user@test.com", "user_id"));
    await expect(
      userCtx.mutation(api.users.updateLinkedMemberId, { member_id: "member_hijack" })
    ).rejects.toThrow("Forbidden");

    const account = await t.run(async (ctx) =>
      ctx.db
        .query("accounts")
        .withIndex("by_email", (q) => q.eq("email", "user@test.com"))
        .unique()
    );
    expect(account?.member_id).toBe("member_original");
  });

  test("users.resolveLinkedAccountsForMemberIds only returns caller-visible identities", async () => {
    const t = convexTest(schema, modules);

    await t.run(async (ctx) => {
      const callerDoc = await ctx.db.insert("accounts", {
        id: "caller_id",
        email: "caller@test.com",
        display_name: "Caller",
        created_at: Date.now(),
        member_id: "caller_member"
      });
      await ctx.db.insert("accounts", {
        id: "friend_id",
        email: "friend@test.com",
        display_name: "Friend",
        created_at: Date.now(),
        member_id: "friend_member"
      });
      await ctx.db.insert("accounts", {
        id: "stranger_id",
        email: "stranger@test.com",
        display_name: "Stranger",
        created_at: Date.now(),
        member_id: "stranger_member"
      });
      await ctx.db.insert("groups", {
        id: "caller_group",
        name: "Caller Group",
        members: [
          { id: "caller_member", name: "Caller", is_current_user: true },
          { id: "friend_member", name: "Friend" }
        ],
        owner_email: "caller@test.com",
        owner_account_id: "caller_id",
        owner_id: callerDoc,
        created_at: Date.now(),
        updated_at: Date.now(),
        is_direct: false
      });
    });

    const callerCtx = t.withIdentity(identity("caller@test.com", "caller_id"));
    const results = await callerCtx.query(api.users.resolveLinkedAccountsForMemberIds, {
      memberIds: ["friend_member", "stranger_member"]
    });

    expect(results).toHaveLength(1);
    expect(results[0]).toMatchObject({
      member_id: "friend_member",
      account_id: "friend_id",
      email: "friend@test.com"
    });
  });

  test("aliases.mergeMemberIds does not trust forged accountEmail", async () => {
    const t = convexTest(schema, modules);

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "attacker_id",
        email: "attacker@test.com",
        display_name: "Attacker",
        created_at: Date.now(),
        member_id: "attacker_member"
      });
      await ctx.db.insert("accounts", {
        id: "victim_id",
        email: "victim@test.com",
        display_name: "Victim",
        created_at: Date.now(),
        member_id: "victim_member"
      });
    });

    const attackerCtx = t.withIdentity(identity("attacker@test.com", "attacker_id"));

    await attackerCtx.mutation(api.aliases.mergeMemberIds, {
      sourceId: "source_member",
      targetCanonicalId: "target_member",
      accountEmail: "victim@test.com"
    });

    const aliases = await t.run(async (ctx) => ctx.db.query("member_aliases").collect());
    expect(aliases).toHaveLength(1);
    expect(aliases[0].account_email).toBe("attacker@test.com");
  });

  test("aliases.mergeUnlinkedFriends does not allow forged accountEmail", async () => {
    const t = convexTest(schema, modules);

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "attacker_id",
        email: "attacker@test.com",
        display_name: "Attacker",
        created_at: Date.now(),
        member_id: "attacker_member"
      });
      await ctx.db.insert("accounts", {
        id: "victim_id",
        email: "victim@test.com",
        display_name: "Victim",
        created_at: Date.now(),
        member_id: "victim_member"
      });
      await ctx.db.insert("account_friends", {
        account_email: "victim@test.com",
        member_id: "victim_friend_a",
        name: "Victim A",
        profile_avatar_color: "#000000",
        has_linked_account: false,
        updated_at: Date.now()
      });
      await ctx.db.insert("account_friends", {
        account_email: "victim@test.com",
        member_id: "victim_friend_b",
        name: "Victim B",
        profile_avatar_color: "#111111",
        has_linked_account: false,
        updated_at: Date.now()
      });
    });

    const attackerCtx = t.withIdentity(identity("attacker@test.com", "attacker_id"));

    await expect(
      attackerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
        friendId1: "victim_friend_a",
        friendId2: "victim_friend_b",
        accountEmail: "victim@test.com"
      })
    ).rejects.toThrow();
  });

  test("cleanup.deleteLinkedFriend does not allow forged accountEmail", async () => {
    const t = convexTest(schema, modules);

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "attacker_id",
        email: "attacker@test.com",
        display_name: "Attacker",
        created_at: Date.now(),
        member_id: "attacker_member"
      });
      await ctx.db.insert("accounts", {
        id: "victim_id",
        email: "victim@test.com",
        display_name: "Victim",
        created_at: Date.now(),
        member_id: "victim_member"
      });
      await ctx.db.insert("account_friends", {
        account_email: "victim@test.com",
        member_id: "victim_friend_linked",
        name: "Linked Friend",
        profile_avatar_color: "#123456",
        has_linked_account: true,
        linked_account_id: "linked_auth_id",
        linked_account_email: "linked@test.com",
        updated_at: Date.now()
      });
    });

    const attackerCtx = t.withIdentity(identity("attacker@test.com", "attacker_id"));
    const result = await attackerCtx.mutation(api.cleanup.deleteLinkedFriend, {
      friendMemberId: "victim_friend_linked",
      accountEmail: "victim@test.com"
    });

    expect(result.success).toBe(false);

    const victimFriend = await t.run(async (ctx) =>
      ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", "victim@test.com").eq("member_id", "victim_friend_linked")
        )
        .unique()
    );
    expect(victimFriend).not.toBeNull();
  });

  test("cleanup.deleteUnlinkedFriend does not allow forged accountEmail", async () => {
    const t = convexTest(schema, modules);

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "attacker_id",
        email: "attacker@test.com",
        display_name: "Attacker",
        created_at: Date.now(),
        member_id: "attacker_member"
      });
      await ctx.db.insert("accounts", {
        id: "victim_id",
        email: "victim@test.com",
        display_name: "Victim",
        created_at: Date.now(),
        member_id: "victim_member"
      });
      await ctx.db.insert("account_friends", {
        account_email: "victim@test.com",
        member_id: "victim_friend_unlinked",
        name: "Unlinked Friend",
        profile_avatar_color: "#654321",
        has_linked_account: false,
        updated_at: Date.now()
      });
    });

    const attackerCtx = t.withIdentity(identity("attacker@test.com", "attacker_id"));
    const result = await attackerCtx.mutation(api.cleanup.deleteUnlinkedFriend, {
      friendMemberId: "victim_friend_unlinked",
      accountEmail: "victim@test.com"
    });

    expect(result.success).toBe(false);

    const victimFriend = await t.run(async (ctx) =>
      ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", "victim@test.com").eq("member_id", "victim_friend_unlinked")
        )
        .unique()
    );
    expect(victimFriend).not.toBeNull();
  });

  test("expenses.listByGroup denies non-members", async () => {
    const t = convexTest(schema, modules);

    await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "owner_id",
        email: "owner@test.com",
        display_name: "Owner",
        created_at: Date.now(),
        member_id: "owner_member"
      });
      await ctx.db.insert("accounts", {
        id: "attacker_id",
        email: "attacker@test.com",
        display_name: "Attacker",
        created_at: Date.now(),
        member_id: "attacker_member"
      });
      const groupDoc = await ctx.db.insert("groups", {
        id: "group_private",
        name: "Private Group",
        members: [{ id: "owner_member", name: "Owner", is_current_user: true }],
        owner_email: "owner@test.com",
        owner_account_id: "owner_id",
        owner_id: ownerId,
        created_at: Date.now(),
        updated_at: Date.now()
      });
      await ctx.db.insert("expenses", {
        id: "expense_private",
        group_id: "group_private",
        group_ref: groupDoc,
        description: "Dinner",
        date: Date.now(),
        total_amount: 10,
        paid_by_member_id: "owner_member",
        involved_member_ids: ["owner_member"],
        splits: [{ id: "s1", member_id: "owner_member", amount: 10, is_settled: false }],
        is_settled: false,
        owner_email: "owner@test.com",
        owner_account_id: "owner_id",
        owner_id: ownerId,
        participant_member_ids: ["owner_member"],
        participant_emails: ["owner@test.com"],
        participants: [{ member_id: "owner_member", name: "Owner" }],
        created_at: Date.now(),
        updated_at: Date.now()
      });
    });

    const attackerCtx = t.withIdentity(identity("attacker@test.com", "attacker_id"));
    await expect(
      attackerCtx.query(api.expenses.listByGroup, { group_id: "group_private" })
    ).rejects.toThrow("Forbidden");
  });

  test("expenses.listByGroupPaginated denies non-members", async () => {
    const t = convexTest(schema, modules);
    let groupDocId: any;

    await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "owner_id",
        email: "owner@test.com",
        display_name: "Owner",
        created_at: Date.now(),
        member_id: "owner_member"
      });
      await ctx.db.insert("accounts", {
        id: "attacker_id",
        email: "attacker@test.com",
        display_name: "Attacker",
        created_at: Date.now(),
        member_id: "attacker_member"
      });

      groupDocId = await ctx.db.insert("groups", {
        id: "group_private_paginated",
        name: "Private Group",
        members: [{ id: "owner_member", name: "Owner", is_current_user: true }],
        owner_email: "owner@test.com",
        owner_account_id: "owner_id",
        owner_id: ownerId,
        created_at: Date.now(),
        updated_at: Date.now()
      });
    });

    const attackerCtx = t.withIdentity(identity("attacker@test.com", "attacker_id"));
    await expect(
      attackerCtx.query(api.expenses.listByGroupPaginated, { groupId: groupDocId, limit: 10 })
    ).rejects.toThrow("Forbidden");
  });

  test("expenses.create blocks non-owner structural updates and other-member settlement changes", async () => {
    const t = convexTest(schema, modules);

    await t.run(async (ctx) => {
      const ownerDocId = await ctx.db.insert("accounts", {
        id: "owner_auth",
        email: "owner@test.com",
        display_name: "Owner",
        created_at: Date.now(),
        member_id: "owner_member"
      });
      await ctx.db.insert("accounts", {
        id: "member_auth",
        email: "member@test.com",
        display_name: "Member",
        created_at: Date.now(),
        member_id: "member_member"
      });

      const groupDoc = await ctx.db.insert("groups", {
        id: "group_shared",
        name: "Shared Group",
        members: [
          { id: "owner_member", name: "Owner", is_current_user: true },
          { id: "member_member", name: "Member" }
        ],
        owner_email: "owner@test.com",
        owner_account_id: "owner_auth",
        owner_id: ownerDocId,
        created_at: Date.now(),
        updated_at: Date.now()
      });

      await ctx.db.insert("expenses", {
        id: "expense_shared",
        group_id: "group_shared",
        group_ref: groupDoc,
        description: "Original",
        date: 1_700_000_000_000,
        total_amount: 100,
        paid_by_member_id: "owner_member",
        involved_member_ids: ["owner_member", "member_member"],
        splits: [
          { id: "s_owner", member_id: "owner_member", amount: 50, is_settled: false },
          { id: "s_member", member_id: "member_member", amount: 50, is_settled: false }
        ],
        is_settled: false,
        owner_email: "owner@test.com",
        owner_account_id: "owner_auth",
        owner_id: ownerDocId,
        participant_member_ids: ["owner_member", "member_member"],
        participant_emails: ["owner@test.com", "member@test.com"],
        participants: [
          { member_id: "owner_member", name: "Owner" },
          { member_id: "member_member", name: "Member" }
        ],
        created_at: Date.now(),
        updated_at: Date.now()
      });
    });

    const memberCtx = t.withIdentity(identity("member@test.com", "member_auth"));

    // Non-owner cannot settle someone else's split.
    await expect(
      memberCtx.mutation(api.expenses.create, {
        id: "expense_shared",
        group_id: "group_shared",
        description: "Original",
        date: 1_700_000_000_000,
        total_amount: 100,
        paid_by_member_id: "owner_member",
        involved_member_ids: ["owner_member", "member_member"],
        splits: [
          { id: "s_owner", member_id: "owner_member", amount: 50, is_settled: true },
          { id: "s_member", member_id: "member_member", amount: 50, is_settled: false }
        ],
        is_settled: true,
        participant_member_ids: ["owner_member", "member_member"],
        participants: [
          { member_id: "owner_member", name: "Owner" },
          { member_id: "member_member", name: "Member" }
        ]
      })
    ).rejects.toThrow("Forbidden");

    // Non-owner cannot change structural fields.
    await expect(
      memberCtx.mutation(api.expenses.create, {
        id: "expense_shared",
        group_id: "group_shared",
        description: "Tampered Description",
        date: 1_700_000_000_000,
        total_amount: 100,
        paid_by_member_id: "owner_member",
        involved_member_ids: ["owner_member", "member_member"],
        splits: [
          { id: "s_owner", member_id: "owner_member", amount: 50, is_settled: false },
          { id: "s_member", member_id: "member_member", amount: 50, is_settled: true }
        ],
        is_settled: true,
        participant_member_ids: ["owner_member", "member_member"],
        participants: [
          { member_id: "owner_member", name: "Owner" },
          { member_id: "member_member", name: "Member" }
        ]
      })
    ).rejects.toThrow("Forbidden");
  });

  test("expenses.create allows participant to settle only own split and recomputes is_settled", async () => {
    const t = convexTest(schema, modules);

    await t.run(async (ctx) => {
      const ownerDocId = await ctx.db.insert("accounts", {
        id: "owner_auth",
        email: "owner@test.com",
        display_name: "Owner",
        created_at: Date.now(),
        member_id: "owner_member"
      });
      await ctx.db.insert("accounts", {
        id: "member_auth",
        email: "member@test.com",
        display_name: "Member",
        created_at: Date.now(),
        member_id: "member_member"
      });
      const groupDoc = await ctx.db.insert("groups", {
        id: "group_settle",
        name: "Settle Group",
        members: [
          { id: "owner_member", name: "Owner", is_current_user: true },
          { id: "member_member", name: "Member" }
        ],
        owner_email: "owner@test.com",
        owner_account_id: "owner_auth",
        owner_id: ownerDocId,
        created_at: Date.now(),
        updated_at: Date.now()
      });
      await ctx.db.insert("expenses", {
        id: "expense_settle",
        group_id: "group_settle",
        group_ref: groupDoc,
        description: "Dinner",
        date: 1_700_000_000_000,
        total_amount: 100,
        paid_by_member_id: "owner_member",
        involved_member_ids: ["owner_member", "member_member"],
        splits: [
          { id: "s_owner", member_id: "owner_member", amount: 50, is_settled: false },
          { id: "s_member", member_id: "member_member", amount: 50, is_settled: false }
        ],
        is_settled: false,
        owner_email: "owner@test.com",
        owner_account_id: "owner_auth",
        owner_id: ownerDocId,
        participant_member_ids: ["owner_member", "member_member"],
        participant_emails: ["owner@test.com", "member@test.com"],
        participants: [
          { member_id: "owner_member", name: "Owner" },
          { member_id: "member_member", name: "Member" }
        ],
        created_at: Date.now(),
        updated_at: Date.now()
      });
    });

    const memberCtx = t.withIdentity(identity("member@test.com", "member_auth"));
    await memberCtx.mutation(api.expenses.create, {
      id: "expense_settle",
      group_id: "group_settle",
      description: "Dinner",
      date: 1_700_000_000_000,
      total_amount: 100,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "member_member"],
      splits: [
        { id: "s_owner", member_id: "owner_member", amount: 50, is_settled: false },
        { id: "s_member", member_id: "member_member", amount: 50, is_settled: true }
      ],
      is_settled: true,
      participant_member_ids: ["owner_member", "member_member"],
      participants: [
        { member_id: "owner_member", name: "Owner" },
        { member_id: "member_member", name: "Member" }
      ]
    });

    const expenseAfter = await t.run(async (ctx) =>
      ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", "expense_settle"))
        .unique()
    );
    expect(expenseAfter).not.toBeNull();
    expect(expenseAfter?.splits.find((split) => split.id === "s_owner")?.is_settled).toBe(false);
    expect(expenseAfter?.splits.find((split) => split.id === "s_member")?.is_settled).toBe(true);
    expect(expenseAfter?.is_settled).toBe(false);
  });

  test("expenses.create does not persist injected participant emails", async () => {
    const t = convexTest(schema, modules);

    await t.run(async (ctx) => {
      const ownerDocId = await ctx.db.insert("accounts", {
        id: "owner_auth",
        email: "owner@test.com",
        display_name: "Owner",
        created_at: Date.now(),
        member_id: "owner_member"
      });
      await ctx.db.insert("groups", {
        id: "group_injection",
        name: "Injection Group",
        members: [
          { id: "owner_member", name: "Owner", is_current_user: true },
          { id: "friend_member", name: "Friend" }
        ],
        owner_email: "owner@test.com",
        owner_account_id: "owner_auth",
        owner_id: ownerDocId,
        created_at: Date.now(),
        updated_at: Date.now()
      });
    });

    const ownerCtx = t.withIdentity(identity("owner@test.com", "owner_auth"));
    await ownerCtx.mutation(api.expenses.create, {
      id: "expense_injection",
      group_id: "group_injection",
      description: "Test Injection",
      date: 1_700_000_000_000,
      total_amount: 40,
      paid_by_member_id: "owner_member",
      involved_member_ids: ["owner_member", "friend_member"],
      splits: [
        { id: "s1", member_id: "owner_member", amount: 20, is_settled: false },
        { id: "s2", member_id: "friend_member", amount: 20, is_settled: false }
      ],
      is_settled: true,
      participant_member_ids: ["owner_member", "friend_member"],
      participants: [
        {
          member_id: "owner_member",
          name: "Owner",
          linked_account_email: "injected-owner@evil.test"
        },
        {
          member_id: "friend_member",
          name: "Friend",
          linked_account_email: "injected-friend@evil.test"
        }
      ]
    });

    const storedExpense = await t.run(async (ctx) =>
      ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", "expense_injection"))
        .unique()
    );
    expect(storedExpense).not.toBeNull();
    expect(storedExpense?.participant_emails).toContain("owner@test.com");
    expect(storedExpense?.participant_emails).not.toContain("injected-owner@evil.test");
    expect(storedExpense?.participant_emails).not.toContain("injected-friend@evil.test");
    expect(storedExpense?.is_settled).toBe(false);
  });

  test("admin.hardDeleteUser requires admin authorization", async () => {
    const t = convexTest(schema, modules);

    process.env.ADMIN_EMAILS = "admin@test.com";

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "victim_id",
        email: "victim@test.com",
        display_name: "Victim",
        created_at: Date.now(),
        member_id: "victim_member"
      });
      await ctx.db.insert("accounts", {
        id: "attacker_id",
        email: "attacker@test.com",
        display_name: "Attacker",
        created_at: Date.now(),
        member_id: "attacker_member"
      });
    });

    const attackerCtx = t.withIdentity(identity("attacker@test.com", "attacker_id"));
    await expect(
      attackerCtx.mutation(api.admin.hardDeleteUser, { email: "victim@test.com" })
    ).rejects.toThrow();

    const victim = await t.run(async (ctx) =>
      ctx.db
        .query("accounts")
        .withIndex("by_email", (q) => q.eq("email", "victim@test.com"))
        .unique()
    );
    expect(victim).not.toBeNull();
  });

  test("friend_requests uses auth account id for linked_account_id", async () => {
    const t = convexTest(schema, modules);

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "sender_auth_id",
        email: "sender@test.com",
        display_name: "Sender",
        created_at: Date.now(),
        member_id: "sender_member"
      });
      await ctx.db.insert("accounts", {
        id: "recipient_auth_id",
        email: "recipient@test.com",
        display_name: "Recipient",
        created_at: Date.now(),
        member_id: "recipient_member"
      });
    });

    const senderCtx = t.withIdentity(identity("sender@test.com", "sender_auth_id"));
    await senderCtx.mutation(api.friend_requests.send, { email: "recipient@test.com" });

    const senderFriendRows = await t.run(async (ctx) =>
      ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (q) => q.eq("account_email", "sender@test.com"))
        .collect()
    );

    expect(senderFriendRows).toHaveLength(1);
    expect(senderFriendRows[0].linked_account_id).toBe("recipient_auth_id");
  });
});
