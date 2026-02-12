import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";

function identity(email: string, subject: string) {
  return {
    subject,
    email,
    name: email.split("@")[0],
    pictureUrl: "http://placeholder.com",
    tokenIdentifier: subject,
    issuer: "http://placeholder.com",
    emailVerified: true,
    updatedAt: "2023-01-01",
  };
}

describe("Security Authorization", () => {
  test("aliases.mergeMemberIds does not trust forged accountEmail", async () => {
    const t = convexTest(schema);

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "attacker_id",
        email: "attacker@test.com",
        display_name: "Attacker",
        created_at: Date.now(),
        member_id: "attacker_member",
      });
      await ctx.db.insert("accounts", {
        id: "victim_id",
        email: "victim@test.com",
        display_name: "Victim",
        created_at: Date.now(),
        member_id: "victim_member",
      });
    });

    const attackerCtx = t.withIdentity(identity("attacker@test.com", "attacker_id"));

    await attackerCtx.mutation(api.aliases.mergeMemberIds, {
      sourceId: "source_member",
      targetCanonicalId: "target_member",
      accountEmail: "victim@test.com",
    });

    const aliases = await t.run(async (ctx) => ctx.db.query("member_aliases").collect());
    expect(aliases).toHaveLength(1);
    expect(aliases[0].account_email).toBe("attacker@test.com");
  });

  test("aliases.mergeUnlinkedFriends does not allow forged accountEmail", async () => {
    const t = convexTest(schema);

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "attacker_id",
        email: "attacker@test.com",
        display_name: "Attacker",
        created_at: Date.now(),
        member_id: "attacker_member",
      });
      await ctx.db.insert("accounts", {
        id: "victim_id",
        email: "victim@test.com",
        display_name: "Victim",
        created_at: Date.now(),
        member_id: "victim_member",
      });
      await ctx.db.insert("account_friends", {
        account_email: "victim@test.com",
        member_id: "victim_friend_a",
        name: "Victim A",
        profile_avatar_color: "#000000",
        has_linked_account: false,
        updated_at: Date.now(),
      });
      await ctx.db.insert("account_friends", {
        account_email: "victim@test.com",
        member_id: "victim_friend_b",
        name: "Victim B",
        profile_avatar_color: "#111111",
        has_linked_account: false,
        updated_at: Date.now(),
      });
    });

    const attackerCtx = t.withIdentity(identity("attacker@test.com", "attacker_id"));

    await expect(
      attackerCtx.mutation(api.aliases.mergeUnlinkedFriends, {
        friendId1: "victim_friend_a",
        friendId2: "victim_friend_b",
        accountEmail: "victim@test.com",
      })
    ).rejects.toThrow();
  });

  test("cleanup.deleteLinkedFriend does not allow forged accountEmail", async () => {
    const t = convexTest(schema);

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "attacker_id",
        email: "attacker@test.com",
        display_name: "Attacker",
        created_at: Date.now(),
        member_id: "attacker_member",
      });
      await ctx.db.insert("accounts", {
        id: "victim_id",
        email: "victim@test.com",
        display_name: "Victim",
        created_at: Date.now(),
        member_id: "victim_member",
      });
      await ctx.db.insert("account_friends", {
        account_email: "victim@test.com",
        member_id: "victim_friend_linked",
        name: "Linked Friend",
        profile_avatar_color: "#123456",
        has_linked_account: true,
        linked_account_id: "linked_auth_id",
        linked_account_email: "linked@test.com",
        updated_at: Date.now(),
      });
    });

    const attackerCtx = t.withIdentity(identity("attacker@test.com", "attacker_id"));
    const result = await attackerCtx.mutation(api.cleanup.deleteLinkedFriend, {
      friendMemberId: "victim_friend_linked",
      accountEmail: "victim@test.com",
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
    const t = convexTest(schema);

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "attacker_id",
        email: "attacker@test.com",
        display_name: "Attacker",
        created_at: Date.now(),
        member_id: "attacker_member",
      });
      await ctx.db.insert("accounts", {
        id: "victim_id",
        email: "victim@test.com",
        display_name: "Victim",
        created_at: Date.now(),
        member_id: "victim_member",
      });
      await ctx.db.insert("account_friends", {
        account_email: "victim@test.com",
        member_id: "victim_friend_unlinked",
        name: "Unlinked Friend",
        profile_avatar_color: "#654321",
        has_linked_account: false,
        updated_at: Date.now(),
      });
    });

    const attackerCtx = t.withIdentity(identity("attacker@test.com", "attacker_id"));
    const result = await attackerCtx.mutation(api.cleanup.deleteUnlinkedFriend, {
      friendMemberId: "victim_friend_unlinked",
      accountEmail: "victim@test.com",
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

  test("admin.hardDeleteUser requires admin authorization", async () => {
    const t = convexTest(schema);

    process.env.ADMIN_EMAILS = "admin@test.com";

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "victim_id",
        email: "victim@test.com",
        display_name: "Victim",
        created_at: Date.now(),
        member_id: "victim_member",
      });
      await ctx.db.insert("accounts", {
        id: "attacker_id",
        email: "attacker@test.com",
        display_name: "Attacker",
        created_at: Date.now(),
        member_id: "attacker_member",
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
    const t = convexTest(schema);

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "sender_auth_id",
        email: "sender@test.com",
        display_name: "Sender",
        created_at: Date.now(),
        member_id: "sender_member",
      });
      await ctx.db.insert("accounts", {
        id: "recipient_auth_id",
        email: "recipient@test.com",
        display_name: "Recipient",
        created_at: Date.now(),
        member_id: "recipient_member",
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
