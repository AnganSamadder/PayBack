import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api, internal } from "../_generated/api";
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

async function setupClaimScenario() {
  const t = convexTest(schema, modules);
  const now = Date.now();
  let claimerAccountId: any;
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "creator_auth",
      email: "creator@test.com",
      display_name: "Creator",
      created_at: now,
      member_id: "creator_member"
    });
    claimerAccountId = await ctx.db.insert("accounts", {
      id: "claimer_auth",
      email: "claimer@test.com",
      display_name: "Claimer",
      created_at: now,
      member_id: "claimer_member"
    });
    await ctx.db.insert("invite_tokens", {
      id: "pending_rollout_invite",
      creator_id: "creator_auth",
      creator_email: "creator@test.com",
      target_member_id: "Legacy_Target",
      target_member_name: "Claimer",
      created_at: now,
      expires_at: now + 60_000
    });
  });
  return { t, claimerAccountId };
}

async function expectClaimStateUnchanged(t: any) {
  const state = await t.run(async (ctx) => ({
    account: await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", "claimer_auth"))
      .unique(),
    token: await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", "pending_rollout_invite"))
      .unique(),
    aliases: await ctx.db.query("member_aliases").collect()
  }));
  expect(state.account?.alias_member_ids).toBeUndefined();
  expect(state.token?.claimed_by).toBeUndefined();
  expect(state.aliases).toHaveLength(0);
}

describe("identity mutation readiness gates", () => {
  test("normal invite claim fails atomically while materialization is pending", async () => {
    const { t } = await setupClaimScenario();
    const claimer = t.withIdentity(identity("claimer@test.com", "claimer_auth"));

    await expect(
      claimer.mutation(api.inviteTokens.claim, { id: "pending_rollout_invite" })
    ).rejects.toThrow("Identity maintenance required");
    await expectClaimStateUnchanged(t);
  });

  test("internal token claim fails atomically while materialization is pending", async () => {
    const { t, claimerAccountId } = await setupClaimScenario();

    await expect(
      t.mutation(internal.inviteTokens._internalClaimForAccount, {
        userAccountId: claimerAccountId,
        tokenId: "pending_rollout_invite"
      })
    ).rejects.toThrow("Identity maintenance required");
    await expectClaimStateUnchanged(t);
  });

  test("internal target claim fails atomically while materialization is pending", async () => {
    const { t, claimerAccountId } = await setupClaimScenario();

    await expect(
      t.mutation(internal.inviteTokens._internalClaimTargetMemberForAccount, {
        userAccountId: claimerAccountId,
        targetMemberId: "Legacy_Target",
        creatorEmail: "creator@test.com",
        creatorId: "creator_auth"
      })
    ).rejects.toThrow("Identity maintenance required");
    await expectClaimStateUnchanged(t);
  });

  test("link request acceptance remains pending while materialization is pending", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "requester_auth",
        email: "requester@test.com",
        display_name: "Requester",
        created_at: now,
        member_id: "requester_member"
      });
      await ctx.db.insert("accounts", {
        id: "recipient_auth",
        email: "recipient@test.com",
        display_name: "Recipient",
        created_at: now,
        member_id: "recipient_member"
      });
      const targetFriendId = await ctx.db.insert("account_friends", {
        account_email: "requester@test.com",
        member_id: "legacy_recipient",
        name: "Recipient",
        profile_avatar_color: "#123456",
        has_linked_account: false,
        updated_at: now
      });
      await ctx.db.insert("link_requests", {
        id: "pending_link_request",
        requester_id: "requester_auth",
        requester_email: "requester@test.com",
        requester_name: "Requester",
        recipient_email: "recipient@test.com",
        target_member_id: "legacy_recipient",
        target_friend_id: targetFriendId,
        target_member_name: "Recipient",
        created_at: now,
        status: "pending",
        expires_at: now + 60_000
      });
    });

    const recipient = t.withIdentity(identity("recipient@test.com", "recipient_auth"));
    await expect(
      recipient.mutation(api.linkRequests.accept, { id: "pending_link_request" })
    ).rejects.toThrow("Identity maintenance required");
    const request = await t.run(async (ctx) =>
      ctx.db
        .query("link_requests")
        .withIndex("by_client_id", (q) => q.eq("id", "pending_link_request"))
        .unique()
    );
    expect(request?.status).toBe("pending");
  });

  test("linked bulk import writes nothing while materialization is pending", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "owner_auth",
        email: "owner@test.com",
        display_name: "Owner",
        created_at: now,
        member_id: "owner_member"
      });
      await ctx.db.insert("accounts", {
        id: "linked_auth",
        email: "linked@test.com",
        display_name: "Linked",
        created_at: now,
        member_id: "linked_canonical"
      });
    });

    const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
    await expect(
      owner.mutation(api.bulkImport.bulkImport, {
        friends: [
          {
            member_id: "Legacy_Linked",
            name: "Linked",
            profile_avatar_color: "#123456",
            has_linked_account: true,
            linked_account_email: "linked@test.com"
          }
        ],
        groups: [],
        expenses: []
      })
    ).rejects.toThrow("Identity maintenance required");
    const rows = await t.run(async (ctx) => ({
      friends: await ctx.db.query("account_friends").collect(),
      aliases: await ctx.db.query("member_aliases").collect()
    }));
    expect(rows.friends).toHaveLength(0);
    expect(rows.aliases).toHaveLength(0);
  });

  test.each([
    ["linked", true, "deleteLinkedFriend"],
    ["unlinked", false, "deleteUnlinkedFriend"]
  ] as const)(
    "%s friend cleanup writes nothing while materialization is pending",
    async (_, isLinked, mutationName) => {
      const t = convexTest(schema, modules);
      await t.run(async (ctx) => {
        await ctx.db.insert("accounts", {
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
          has_linked_account: isLinked,
          linked_account_id: isLinked ? "friend_auth" : undefined,
          linked_account_email: isLinked ? "friend@test.com" : undefined,
          updated_at: Date.now()
        });
      });

      const owner = t.withIdentity(identity("owner@test.com", "owner_auth"));
      const cleanupMutation =
        mutationName === "deleteLinkedFriend"
          ? api.cleanup.deleteLinkedFriend
          : api.cleanup.deleteUnlinkedFriend;
      await expect(
        owner.mutation(cleanupMutation as any, { friendMemberId: "friend_member" })
      ).rejects.toThrow("Identity maintenance required");
      const friend = await t.run(async (ctx) =>
        ctx.db
          .query("account_friends")
          .withIndex("by_account_email_and_member_id", (q) =>
            q.eq("account_email", "owner@test.com").eq("member_id", "friend_member")
          )
          .unique()
      );
      expect(friend).not.toBeNull();
    }
  );

  test("legacy canonical bootstrap writes nothing while materialization is pending", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "legacy_auth",
        email: "legacy@test.com",
        display_name: "Legacy",
        created_at: Date.now(),
        alias_member_ids: ["Legacy_Alias"]
      });
    });

    const legacy = t.withIdentity(identity("legacy@test.com", "legacy_auth"));
    await expect(
      legacy.mutation(api.users.updateLinkedMemberId, { member_id: "Canonical_Member" })
    ).rejects.toThrow("Identity maintenance required");
    const account = await t.run(async (ctx) =>
      ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", "legacy_auth"))
        .unique()
    );
    expect(account?.member_id).toBeUndefined();
  });
});
