import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

function identity(email: string, subject: string) {
  return {
    subject,
    email,
    tokenIdentifier: subject,
    issuer: "https://issuer.example.com"
  };
}

async function insertAccount(
  t: ReturnType<typeof convexTest>,
  input: { id: string; email: string; memberId: string }
) {
  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: input.id,
      email: input.email,
      normalized_email: input.email,
      display_name: input.id,
      member_id: input.memberId,
      created_at: Date.now()
    });
  });
}

async function insertUnlinkedFriends(
  t: ReturnType<typeof convexTest>,
  accountEmail: string,
  memberIds: string[]
) {
  await t.run(async (ctx) => {
    for (const memberId of memberIds) {
      await ctx.db.insert("account_friends", {
        account_email: accountEmail,
        member_id: memberId,
        name: memberId,
        profile_avatar_color: "#123456",
        has_linked_account: false,
        updated_at: Date.now()
      });
    }
  });
}

describe("linking abuse controls", () => {
  test("friend request send gives a generic success for an unavailable recipient", async () => {
    const t = convexTest(schema, modules);
    await insertAccount(t, {
      id: "sender_auth",
      email: "sender@example.com",
      memberId: "sender_member"
    });
    const sender = t.withIdentity(identity("sender@example.com", "sender_auth"));

    await expect(
      sender.mutation(api.friend_requests.send, { email: "missing@example.com" })
    ).resolves.toEqual({ success: true });

    const artifacts = await t.run(async (ctx) => ({
      requests: await ctx.db.query("friend_requests").collect(),
      friends: await ctx.db.query("account_friends").collect()
    }));
    expect(artifacts).toEqual({ requests: [], friends: [] });
  });

  test("friend request send is limited per sender", async () => {
    const t = convexTest(schema, modules);
    await insertAccount(t, {
      id: "sender_auth",
      email: "sender@example.com",
      memberId: "sender_member"
    });
    for (let index = 0; index < 11; index += 1) {
      await insertAccount(t, {
        id: `recipient_auth_${index}`,
        email: `recipient${index}@example.com`,
        memberId: `recipient_member_${index}`
      });
    }
    const sender = t.withIdentity(identity("sender@example.com", "sender_auth"));

    for (let index = 0; index < 10; index += 1) {
      await sender.mutation(api.friend_requests.send, {
        email: `recipient${index}@example.com`
      });
    }
    await expect(
      sender.mutation(api.friend_requests.send, { email: "recipient10@example.com" })
    ).rejects.toThrow("429");
  });

  test("only one active link request can target an owned friend", async () => {
    const t = convexTest(schema, modules);
    await insertAccount(t, {
      id: "owner_auth",
      email: "owner@example.com",
      memberId: "owner_member"
    });
    await insertUnlinkedFriends(t, "owner@example.com", ["friend_member"]);
    const owner = t.withIdentity(identity("owner@example.com", "owner_auth"));

    await owner.mutation(api.linkRequests.createV2, {
      id: "request_one",
      recipient_email: "first@example.com",
      target_member_id: "friend_member",
      target_member_name: "Friend"
    });
    await expect(
      owner.mutation(api.linkRequests.createV2, {
        id: "request_two",
        recipient_email: "second@example.com",
        target_member_id: "friend_member",
        target_member_name: "Friend"
      })
    ).rejects.toThrow("active link request already exists for this friend");
  });

  test("link request creation is limited per requester", async () => {
    const t = convexTest(schema, modules);
    const memberIds = Array.from({ length: 11 }, (_, index) => `friend_member_${index}`);
    await insertAccount(t, {
      id: "owner_auth",
      email: "owner@example.com",
      memberId: "owner_member"
    });
    await insertUnlinkedFriends(t, "owner@example.com", memberIds);
    const owner = t.withIdentity(identity("owner@example.com", "owner_auth"));

    for (let index = 0; index < 10; index += 1) {
      await owner.mutation(api.linkRequests.createV2, {
        id: `request_${index}`,
        recipient_email: `recipient${index}@example.com`,
        target_member_id: memberIds[index],
        target_member_name: memberIds[index]
      });
    }
    await expect(
      owner.mutation(api.linkRequests.createV2, {
        id: "request_10",
        recipient_email: "recipient10@example.com",
        target_member_id: memberIds[10],
        target_member_name: memberIds[10]
      })
    ).rejects.toThrow("429");
  });

  test("only one active invite token can target an owned friend", async () => {
    const t = convexTest(schema, modules);
    await insertAccount(t, {
      id: "owner_auth",
      email: "owner@example.com",
      memberId: "owner_member"
    });
    await insertUnlinkedFriends(t, "owner@example.com", ["friend_member"]);
    const owner = t.withIdentity(identity("owner@example.com", "owner_auth"));

    await owner.mutation(api.inviteTokens.create, {
      id: "invite_one",
      target_member_id: "friend_member",
      target_member_name: "Friend"
    });
    await expect(
      owner.mutation(api.inviteTokens.create, {
        id: "invite_two",
        target_member_id: "friend_member",
        target_member_name: "Friend"
      })
    ).rejects.toThrow("active invite already exists for this friend");
  });

  test("invite creation is limited per creator", async () => {
    const t = convexTest(schema, modules);
    const memberIds = Array.from({ length: 11 }, (_, index) => `friend_member_${index}`);
    await insertAccount(t, {
      id: "owner_auth",
      email: "owner@example.com",
      memberId: "owner_member"
    });
    await insertUnlinkedFriends(t, "owner@example.com", memberIds);
    const owner = t.withIdentity(identity("owner@example.com", "owner_auth"));

    for (let index = 0; index < 10; index += 1) {
      await owner.mutation(api.inviteTokens.create, {
        id: `invite_${index}`,
        target_member_id: memberIds[index],
        target_member_name: memberIds[index]
      });
    }
    await expect(
      owner.mutation(api.inviteTokens.create, {
        id: "invite_10",
        target_member_id: memberIds[10],
        target_member_name: memberIds[10]
      })
    ).rejects.toThrow("429");
  });
});
