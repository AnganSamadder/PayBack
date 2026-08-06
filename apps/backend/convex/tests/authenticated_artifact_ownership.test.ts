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

test("same-email different-subject identities cannot read another account's artifacts", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_subject",
      email: "shared@example.com",
      normalized_email: "shared@example.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "shared@example.com",
      member_id: "friend_member",
      name: "Owner Friend",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      link_state: "unlinked",
      updated_at: now
    });
    await ctx.db.insert("link_requests", {
      id: "incoming_request",
      requester_id: "requester_subject",
      requester_email: "requester@example.com",
      requester_name: "Requester",
      recipient_email: "shared@example.com",
      target_member_id: "friend_member",
      target_member_name: "Owner Friend",
      created_at: now,
      status: "pending",
      expires_at: now + 60_000
    });
    await ctx.db.insert("link_requests", {
      id: "outgoing_request",
      requester_id: "owner_subject",
      requester_email: "shared@example.com",
      requester_name: "Owner",
      recipient_email: "recipient@example.com",
      target_member_id: "friend_member",
      target_member_name: "Owner Friend",
      created_at: now,
      status: "pending",
      expires_at: now + 60_000
    });
  });

  const attacker = t.withIdentity(identity("shared@example.com", "attacker_subject"));

  await expect(attacker.query(api.friends.list, {})).resolves.toEqual([]);
  await expect(attacker.query(api.linkRequests.listIncoming, {})).resolves.toEqual([]);
  await expect(
    attacker.query(api.linkRequests.listIncomingPage, { cursor: null, numItems: 5 })
  ).resolves.toMatchObject({ page: [], isDone: true });
  await expect(attacker.query(api.linkRequests.listOutgoing, {})).resolves.toEqual([]);
  await expect(
    attacker.query(api.linkRequests.listOutgoingPage, { cursor: null, numItems: 5 })
  ).resolves.toMatchObject({ page: [], isDone: true });
});

test.each(["upsert", "clear", "clearV2"] as const)(
  "friends.%s rejects a same-email different-subject caller without writes",
  async (operation) => {
    const t = convexTest(schema, modules);
    const now = Date.now();

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "owner_subject",
        email: "shared@example.com",
        normalized_email: "shared@example.com",
        display_name: "Owner",
        member_id: "owner_member",
        created_at: now
      });
      await ctx.db.insert("account_friends", {
        account_email: "shared@example.com",
        member_id: "existing_friend",
        name: "Existing Friend",
        profile_avatar_color: "#123456",
        has_linked_account: false,
        link_state: "unlinked",
        updated_at: now
      });
    });

    const attacker = t.withIdentity(identity("shared@example.com", "attacker_subject"));
    const result =
      operation === "upsert"
        ? attacker.mutation(api.friends.upsert, {
            member_id: "new_friend",
            name: "New Friend",
            has_linked_account: false
          })
        : operation === "clear"
          ? attacker.mutation(api.friends.clearAllForUser, {})
          : attacker.mutation(api.friends.clearAllForUserV2, {});

    await expect(result).rejects.toThrow("User not found");
    const friends = await t.run((ctx) => ctx.db.query("account_friends").collect());
    expect(friends.map((friend) => friend.member_id)).toEqual(["existing_friend"]);
  }
);

test.each(["create", "accept", "decline", "cancel"] as const)(
  "linkRequests.%s rejects a same-email different-subject caller without writes",
  async (operation) => {
    const t = convexTest(schema, modules);
    const now = Date.now();

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "owner_subject",
        email: "shared@example.com",
        normalized_email: "shared@example.com",
        display_name: "Owner",
        member_id: "owner_member",
        created_at: now
      });
      await ctx.db.insert("accounts", {
        id: "requester_subject",
        email: "requester@example.com",
        normalized_email: "requester@example.com",
        display_name: "Requester",
        member_id: "requester_member",
        created_at: now
      });
      await ctx.db.insert("identity_materialization_state", {
        key: "member_identity_v3",
        status: "ready",
        phase: "complete",
        updated_at: now
      });
      const ownerFriendId = await ctx.db.insert("account_friends", {
        account_email: "shared@example.com",
        member_id: "owner_friend",
        name: "Owner Friend",
        profile_avatar_color: "#123456",
        has_linked_account: false,
        link_state: "unlinked",
        updated_at: now
      });
      const requesterFriendId = await ctx.db.insert("account_friends", {
        account_email: "requester@example.com",
        member_id: "requester_friend",
        name: "Requester Friend",
        profile_avatar_color: "#654321",
        has_linked_account: false,
        link_state: "unlinked",
        updated_at: now
      });

      if (operation !== "create") {
        await ctx.db.insert("link_requests", {
          id: "existing_request",
          requester_id: operation === "cancel" ? "owner_subject" : "requester_subject",
          requester_email: operation === "cancel" ? "shared@example.com" : "requester@example.com",
          requester_name: operation === "cancel" ? "Owner" : "Requester",
          recipient_email: operation === "cancel" ? "recipient@example.com" : "shared@example.com",
          target_member_id: operation === "cancel" ? "owner_friend" : "requester_friend",
          target_friend_id: operation === "cancel" ? ownerFriendId : requesterFriendId,
          target_member_name: operation === "cancel" ? "Owner Friend" : "Requester Friend",
          created_at: now,
          status: "pending",
          expires_at: now + 60_000
        });
      }
    });

    const attacker = t.withIdentity(identity("shared@example.com", "attacker_subject"));
    const result =
      operation === "create"
        ? attacker.mutation(api.linkRequests.createV2, {
            id: "new_request",
            recipient_email: "recipient@example.com",
            target_member_id: "owner_friend",
            target_member_name: "Owner Friend"
          })
        : operation === "accept"
          ? attacker.mutation(api.linkRequests.accept, { id: "existing_request" })
          : operation === "decline"
            ? attacker.mutation(api.linkRequests.decline, { id: "existing_request" })
            : attacker.mutation(api.linkRequests.cancel, { id: "existing_request" });

    await expect(result).rejects.toThrow("User not found");
    const requests = await t.run((ctx) => ctx.db.query("link_requests").collect());
    if (operation === "create") {
      expect(requests).toEqual([]);
    } else {
      expect(requests).toHaveLength(1);
      expect(requests[0]?.status).toBe("pending");
    }
  }
);

test("subject-owned mixed-case accounts use normalized artifact keys", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_subject",
      email: "Owner@Example.COM",
      normalized_email: "owner@example.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "existing_friend",
      name: "Existing Friend",
      profile_avatar_color: "#123456",
      has_linked_account: false,
      link_state: "unlinked",
      updated_at: now
    });
    await ctx.db.insert("link_requests", {
      id: "incoming_request",
      requester_id: "requester_subject",
      requester_email: "requester@example.com",
      requester_name: "Requester",
      recipient_email: "owner@example.com",
      target_member_id: "existing_friend",
      target_member_name: "Existing Friend",
      created_at: now,
      status: "pending",
      expires_at: now + 60_000
    });
  });

  const owner = t.withIdentity(identity("owner@example.com", "owner_subject"));
  await expect(owner.query(api.friends.list, {})).resolves.toMatchObject([
    { member_id: "existing_friend" }
  ]);

  await owner.mutation(api.friends.upsert, {
    member_id: "new_friend",
    name: "New Friend",
    has_linked_account: false
  });
  const created = await owner.mutation(api.linkRequests.createV2, {
    id: "outgoing_request",
    recipient_email: "recipient@example.com",
    target_member_id: "existing_friend",
    target_member_name: "Existing Friend"
  });

  expect(created).toMatchObject({
    requester_id: "owner_subject",
    requester_email: "owner@example.com",
    recipient_email: "recipient@example.com"
  });
  await expect(owner.query(api.linkRequests.listIncoming, {})).resolves.toMatchObject([
    { id: "incoming_request" }
  ]);
  await expect(owner.query(api.linkRequests.listOutgoing, {})).resolves.toMatchObject([
    { id: "outgoing_request" }
  ]);

  const friendEmails = await t.run(async (ctx) =>
    (await ctx.db.query("account_friends").collect()).map((friend) => friend.account_email)
  );
  expect(friendEmails).toEqual(["owner@example.com", "owner@example.com"]);
});

test("mixed-case legacy accounts can delete a linked friend stored under normalized email", async () => {
  const t = convexTest(schema, modules);
  const now = Date.now();

  await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_subject",
      email: "Owner@Example.COM",
      normalized_email: "owner@example.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: now
    });
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: now
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "linked_friend",
      name: "Linked Friend",
      profile_avatar_color: "#123456",
      has_linked_account: true,
      linked_account_id: "friend_subject",
      linked_account_email: "friend@example.com",
      link_state: "linked",
      updated_at: now
    });
  });

  const owner = t.withIdentity(identity("owner@example.com", "owner_subject"));
  await expect(
    owner.mutation(api.cleanup.deleteLinkedFriend, { friendMemberId: "linked_friend" })
  ).resolves.toMatchObject({ success: true });
  expect(await t.run((ctx) => ctx.db.query("account_friends").collect())).toEqual([]);
});
