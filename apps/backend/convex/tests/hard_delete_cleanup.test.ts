import { convexTest } from "convex-test";
import { expect, test, describe } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";

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
  test("friends.list returns unlinked state when linked account is manually deleted", async () => {
    const t = convexTest(schema);

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
    const t = convexTest(schema);

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
        linked_member_id: "member_b",
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
    const t = convexTest(schema);

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

  test("cleanup finds orphans via by_linked_member_id index", async () => {
    const t = convexTest(schema);

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
    const t = convexTest(schema);

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
