import { convexTest } from "convex-test";
import { expect, test, describe } from "vitest";
import { api, internal } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

function adminIdentity() {
  return {
    subject: "admin_user",
    email: "admin@test.com",
    name: "Admin",
    pictureUrl: "http://placeholder.com",
    tokenIdentifier: "admin_user",
    issuer: "http://placeholder.com",
    emailVerified: true,
    updatedAt: "2023-01-01"
  };
}

describe("Hard Delete Cleanup", () => {
  test("internal hard delete awaits centralized expense cleanup and bumps surviving viewers once", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const survivorId = await ctx.db.insert("accounts", {
        id: "survivor_auth",
        email: "survivor@test.com",
        display_name: "Survivor",
        created_at: 1,
        member_id: "survivor_member"
      });
      const deletedId = await ctx.db.insert("accounts", {
        id: "deleted_auth",
        email: "deleted@test.com",
        display_name: "Deleted",
        created_at: 1,
        member_id: "deleted_member"
      });
      const expenseId = await ctx.db.insert("expenses", {
        id: "hard_delete_expense",
        group_id: "hard_delete_group",
        description: "Dinner",
        date: 1,
        total_amount: 20,
        paid_by_member_id: "deleted_member",
        involved_member_ids: ["deleted_member", "survivor_member"],
        splits: [
          { id: "deleted_split", member_id: "deleted_member", amount: 10, is_settled: false },
          { id: "survivor_split", member_id: "survivor_member", amount: 10, is_settled: false }
        ],
        is_settled: false,
        owner_email: "deleted@test.com",
        owner_account_id: "deleted_auth",
        owner_id: deletedId,
        participant_member_ids: ["deleted_member", "survivor_member"],
        participant_emails: ["deleted@test.com", "survivor@test.com"],
        participants: [
          { member_id: "deleted_member", name: "Deleted" },
          { member_id: "survivor_member", name: "Survivor" }
        ],
        created_at: 1,
        updated_at: 1
      });
      for (const account of [
        { id: deletedId, auth: "deleted_auth" },
        { id: survivorId, auth: "survivor_auth" }
      ]) {
        await ctx.db.insert("user_expenses", {
          user_id: account.auth,
          expense_id: "hard_delete_expense",
          account_ref: account.id,
          expense_ref: expenseId,
          updated_at: 1
        });
      }
      return { survivorId, deletedId };
    });

    await t.mutation(internal.cleanup.hardDeleteAccount, { accountId: fixture.deletedId });

    const state = await t.run(async (ctx) => ({
      expenses: await ctx.db.query("expenses").collect(),
      visibility: await ctx.db.query("user_expenses").collect(),
      survivorRevision: await ctx.db
        .query("account_sync_state")
        .withIndex("by_account_id", (query) => query.eq("account_id", fixture.survivorId))
        .unique(),
      deletedRevision: await ctx.db
        .query("account_sync_state")
        .withIndex("by_account_id", (query) => query.eq("account_id", fixture.deletedId))
        .unique()
    }));
    expect(state.expenses).toEqual([]);
    expect(state.visibility).toEqual([]);
    expect(state.survivorRevision?.expenses_revision).toBe(1);
    expect(state.deletedRevision).toBeNull();
  });

  test("admin orphan cleanup routes expense deletion through surviving viewer revisions", async () => {
    const t = convexTest(schema, modules);
    const fixture = await t.run(async (ctx) => {
      const survivorId = await ctx.db.insert("accounts", {
        id: "janitor_survivor_auth",
        email: "janitor-survivor@test.com",
        display_name: "Survivor",
        created_at: 1,
        member_id: "janitor_survivor_member"
      });
      const deletedId = await ctx.db.insert("accounts", {
        id: "janitor_deleted_auth",
        email: "janitor-deleted@test.com",
        display_name: "Deleted",
        created_at: 1,
        member_id: "janitor_deleted_member"
      });
      const expenseId = await ctx.db.insert("expenses", {
        id: "janitor_delete_expense",
        group_id: "janitor_delete_group",
        description: "Dinner",
        date: 1,
        total_amount: 20,
        paid_by_member_id: "janitor_deleted_member",
        involved_member_ids: ["janitor_deleted_member", "janitor_survivor_member"],
        splits: [
          {
            id: "janitor_deleted_split",
            member_id: "janitor_deleted_member",
            amount: 10,
            is_settled: false
          },
          {
            id: "janitor_survivor_split",
            member_id: "janitor_survivor_member",
            amount: 10,
            is_settled: false
          }
        ],
        is_settled: false,
        owner_email: "janitor-deleted@test.com",
        owner_account_id: "janitor_deleted_auth",
        owner_id: deletedId,
        participant_member_ids: ["janitor_deleted_member", "janitor_survivor_member"],
        participant_emails: ["janitor-deleted@test.com", "janitor-survivor@test.com"],
        participants: [
          { member_id: "janitor_deleted_member", name: "Deleted" },
          { member_id: "janitor_survivor_member", name: "Survivor" }
        ],
        created_at: 1,
        updated_at: 1
      });
      await ctx.db.insert("user_expenses", {
        user_id: "janitor_survivor_auth",
        expense_id: "janitor_delete_expense",
        account_ref: survivorId,
        expense_ref: expenseId,
        updated_at: 1
      });
      return { survivorId };
    });

    process.env.ADMIN_EMAILS = "admin@test.com";
    await t
      .withIdentity(adminIdentity())
      .mutation(api.admin.hardDeleteUser, { email: "janitor-deleted@test.com" });

    const state = await t.run(async (ctx) => ({
      expenses: await ctx.db.query("expenses").collect(),
      visibility: await ctx.db.query("user_expenses").collect(),
      survivorRevision: await ctx.db
        .query("account_sync_state")
        .withIndex("by_account_id", (query) => query.eq("account_id", fixture.survivorId))
        .unique()
    }));
    expect(state.expenses).toEqual([]);
    expect(state.visibility).toEqual([]);
    expect(state.survivorRevision?.expenses_revision).toBe(1);
  });

  test("friends.list returns unlinked state when linked account is manually deleted", async () => {
    const t = convexTest(schema, modules);

    const userAId = await t.run(async (ctx) => {
      return await ctx.db.insert("accounts", {
        id: "user_a",
        email: "user_a@test.com",
        display_name: "User A",
        created_at: Date.now(),
        member_id: "member_a"
      });
    });

    const userBId = await t.run(async (ctx) => {
      return await ctx.db.insert("accounts", {
        id: "user_b",
        email: "user_b@test.com",
        display_name: "User B",
        created_at: Date.now(),
        member_id: "member_b"
      });
    });

    await t.run(async (ctx) => {
      await ctx.db.insert("account_friends", {
        account_email: "user_a@test.com",
        member_id: "friend_member_b",
        name: "User B",
        profile_avatar_color: "#FF0000",
        has_linked_account: true,
        linked_account_id: "user_b",
        linked_account_email: "user_b@test.com",
        linked_member_id: "member_b",
        link_state: "linked",
        updated_at: Date.now()
      });
    });

    const ctxA = t.withIdentity({
      subject: "user_a",
      email: "user_a@test.com",
      name: "User A",
      pictureUrl: "http://placeholder.com",
      tokenIdentifier: "user_a",
      issuer: "http://placeholder.com",
      emailVerified: true,
      updatedAt: "2023-01-01"
    });

    const friendsBefore = await ctxA.query(api.friends.list, {});
    expect(friendsBefore.length).toBe(1);
    expect(friendsBefore[0].has_linked_account).toBe(true);
    expect(friendsBefore[0].linked_account_email).toBe("user_b@test.com");

    await t.run(async (ctx) => {
      await ctx.db.delete(userBId);
    });

    const friendsAfter = await ctxA.query(api.friends.list, {});
    expect(friendsAfter.length).toBe(1);
    expect(friendsAfter[0].has_linked_account).toBe(false);
    expect(friendsAfter[0].linked_account_email).toBeUndefined();
    expect(friendsAfter[0].linked_account_id).toBeUndefined();
    expect(friendsAfter[0].linked_member_id).toBeUndefined();
  });

  test("friends.list validates linked_member_id when linked_account_email is missing", async () => {
    const t = convexTest(schema, modules);

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "user_a",
        email: "user_a@test.com",
        display_name: "User A",
        created_at: Date.now(),
        member_id: "member_a"
      });
    });

    const userBId = await t.run(async (ctx) => {
      return await ctx.db.insert("accounts", {
        id: "user_b",
        email: "user_b@test.com",
        display_name: "User B",
        created_at: Date.now(),
        member_id: "member_b"
      });
    });

    await t.run(async (ctx) => {
      await ctx.db.insert("account_friends", {
        account_email: "user_a@test.com",
        member_id: "friend_member_b",
        name: "User B (imported)",
        profile_avatar_color: "#FF0000",
        has_linked_account: true,
        linked_account_id: "user_b",
        linked_member_id: "member_b",
        link_state: "linked",
        updated_at: Date.now()
      });
    });

    const ctxA = t.withIdentity({
      subject: "user_a",
      email: "user_a@test.com",
      name: "User A",
      pictureUrl: "http://placeholder.com",
      tokenIdentifier: "user_a",
      issuer: "http://placeholder.com",
      emailVerified: true,
      updatedAt: "2023-01-01"
    });

    const friendsBefore = await ctxA.query(api.friends.list, {});
    expect(friendsBefore.length).toBe(1);
    expect(friendsBefore[0].has_linked_account).toBe(true);

    await t.run(async (ctx) => {
      await ctx.db.delete(userBId);
    });

    const friendsAfter = await ctxA.query(api.friends.list, {});
    expect(friendsAfter.length).toBe(1);
    expect(friendsAfter[0].has_linked_account).toBe(false);
    expect(friendsAfter[0].linked_member_id).toBeUndefined();
  });

  test("performHardDelete removes friend records from other users lists", async () => {
    const t = convexTest(schema, modules);

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "user_a",
        email: "user_a@test.com",
        display_name: "User A",
        created_at: Date.now(),
        member_id: "member_a"
      });
    });

    const userBId = await t.run(async (ctx) => {
      return await ctx.db.insert("accounts", {
        id: "user_b",
        email: "user_b@test.com",
        display_name: "User B",
        created_at: Date.now(),
        member_id: "member_b"
      });
    });

    await t.run(async (ctx) => {
      await ctx.db.insert("account_friends", {
        account_email: "user_a@test.com",
        member_id: "friend_b_in_a",
        name: "User B",
        profile_avatar_color: "#FF0000",
        has_linked_account: true,
        linked_account_id: "user_b",
        linked_account_email: "user_b@test.com",
        linked_member_id: "member_b",
        updated_at: Date.now()
      });
    });

    await t.run(async (ctx) => {
      await ctx.db.insert("account_friends", {
        account_email: "user_b@test.com",
        member_id: "friend_a_in_b",
        name: "User A",
        profile_avatar_color: "#00FF00",
        has_linked_account: true,
        linked_account_id: "user_a",
        linked_account_email: "user_a@test.com",
        linked_member_id: "member_a",
        updated_at: Date.now()
      });
    });

    const friendsBefore = await t.run(async (ctx) => {
      return await ctx.db.query("account_friends").collect();
    });
    expect(friendsBefore.length).toBe(2);

    process.env.ADMIN_EMAILS = "admin@test.com";
    const adminCtx = t.withIdentity(adminIdentity());
    await adminCtx.mutation(api.admin.hardDeleteUser, { email: "user_b@test.com" });

    const friendsAfter = await t.run(async (ctx) => {
      return await ctx.db.query("account_friends").collect();
    });

    expect(friendsAfter.length).toBe(0);

    const accountB = await t.run(async (ctx) => {
      return await ctx.db
        .query("accounts")
        .withIndex("by_email", (q) => q.eq("email", "user_b@test.com"))
        .unique();
    });
    expect(accountB).toBeNull();
  });

  test("performHardDelete removes an interrupted self-deletion progress record", async () => {
    const t = convexTest(schema, modules);
    const accountId = await t.run(async (ctx) => {
      const insertedAccountId = await ctx.db.insert("accounts", {
        id: "user_b",
        email: "user_b@test.com",
        display_name: "User B",
        created_at: Date.now(),
        member_id: "member_b"
      });
      await ctx.db.insert("account_deletion_progress", {
        auth_subject: "user_b",
        account_id: insertedAccountId,
        account_auth_id: "user_b",
        account_email: "user_b@test.com",
        member_ids: ["member_b"],
        request_id: "user_b",
        tombstone_email: `deleted+${insertedAccountId}@payback.invalid`,
        phase: "owned_expenses",
        friendships_unlinked: 1,
        processed_count: 12,
        started_at: Date.now(),
        updated_at: Date.now()
      });
      return insertedAccountId;
    });

    await t.mutation(internal.cleanup.hardDeleteAccount, { accountId });

    const progress = await t.run(async (ctx) =>
      ctx.db
        .query("account_deletion_progress")
        .withIndex("by_auth_subject", (q) => q.eq("auth_subject", "user_b"))
        .collect()
    );
    expect(progress).toEqual([]);
  });

  test("cleanup finds orphans via by_linked_member_id index", async () => {
    const t = convexTest(schema, modules);

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "user_a",
        email: "user_a@test.com",
        display_name: "User A",
        created_at: Date.now(),
        member_id: "member_a"
      });
    });

    await t.run(async (ctx) => {
      await ctx.db.insert("account_friends", {
        account_email: "user_a@test.com",
        member_id: "orphan_friend",
        name: "Deleted User",
        profile_avatar_color: "#999999",
        has_linked_account: true,
        linked_member_id: "member_deleted",
        updated_at: Date.now()
      });
    });

    const linkedByMemberId = await t.run(async (ctx) => {
      return await ctx.db
        .query("account_friends")
        .withIndex("by_linked_member_id", (q) => q.eq("linked_member_id", "member_deleted"))
        .collect();
    });

    expect(linkedByMemberId.length).toBe(1);
    expect(linkedByMemberId[0].name).toBe("Deleted User");
  });

  test("no ghost duplicates after hard delete - friend record is fully removed", async () => {
    const t = convexTest(schema, modules);

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "user_a",
        email: "user_a@test.com",
        display_name: "User A",
        created_at: Date.now(),
        member_id: "member_a"
      });

      await ctx.db.insert("accounts", {
        id: "user_b",
        email: "user_b@test.com",
        display_name: "User B",
        created_at: Date.now(),
        member_id: "member_b"
      });

      await ctx.db.insert("account_friends", {
        account_email: "user_a@test.com",
        member_id: "friend_b",
        name: "User B",
        profile_avatar_color: "#FF0000",
        has_linked_account: true,
        linked_account_id: "user_b",
        linked_account_email: "user_b@test.com",
        updated_at: Date.now()
      });
    });

    process.env.ADMIN_EMAILS = "admin@test.com";
    const adminCtx = t.withIdentity(adminIdentity());
    await adminCtx.mutation(api.admin.hardDeleteUser, { email: "user_b@test.com" });

    const allFriends = await t.run(async (ctx) => {
      return await ctx.db.query("account_friends").collect();
    });

    expect(allFriends.length).toBe(0);

    const ghostLinked = allFriends.filter((f) => f.linked_account_email === "user_b@test.com");
    const ghostUnlinked = allFriends.filter((f) => f.name === "User B" && !f.has_linked_account);

    expect(ghostLinked.length).toBe(0);
    expect(ghostUnlinked.length).toBe(0);
  });
});
