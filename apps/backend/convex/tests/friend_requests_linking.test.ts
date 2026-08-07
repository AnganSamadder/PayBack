import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

function identity(email: string, subject: string) {
  return {
    subject,
    email,
    name: subject,
    pictureUrl: "http://placeholder.com",
    tokenIdentifier: subject,
    issuer: "http://placeholder.com",
    emailVerified: true,
    updatedAt: "2023-01-01"
  };
}

async function seedFriendRequestAccounts() {
  const t = convexTest(schema, modules);
  const now = Date.now();

  const senderDocId = await t.run((ctx) =>
    ctx.db.insert("accounts", {
      id: "sender_auth_id",
      email: "sender@example.com",
      display_name: "Sender",
      member_id: "sender_member",
      created_at: now
    })
  );
  await t.run((ctx) =>
    ctx.db.insert("accounts", {
      id: "recipient_auth_id",
      email: "recipient@example.com",
      display_name: "Recipient",
      member_id: "recipient_member",
      created_at: now
    })
  );

  return {
    t,
    senderDocId,
    sender: t.withIdentity(identity("sender@example.com", "sender_auth_id")),
    recipient: t.withIdentity(identity("recipient@example.com", "recipient_auth_id"))
  };
}

test("friend_requests:send stores a pending request for the authenticated sender", async () => {
  const { t, sender, senderDocId } = await seedFriendRequestAccounts();

  await sender.mutation(api.friend_requests.send, { email: " Recipient@Example.com " });

  const requests = await t.run((ctx) => ctx.db.query("friend_requests").collect());
  expect(requests).toHaveLength(1);
  expect(requests[0]).toMatchObject({
    sender_id: senderDocId,
    recipient_email: "recipient@example.com",
    status: "pending"
  });
});

test("friend_requests:send keeps the pre-accept friend row unlinked", async () => {
  const { t, sender } = await seedFriendRequestAccounts();

  await sender.mutation(api.friend_requests.send, { email: "recipient@example.com" });

  const friend = await t.run((ctx) =>
    ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "sender@example.com").eq("member_id", "recipient_member")
      )
      .unique()
  );
  expect(friend).toMatchObject({
    member_id: "recipient_member",
    status: "request_sent",
    has_linked_account: false,
    link_state: "unlinked"
  });
  expect(friend?.linked_account_id).toBeUndefined();
  expect(friend?.linked_account_email).toBeUndefined();
  expect(friend?.linked_member_id).toBeUndefined();
});

test("friend_requests:accept persists canonical linked provenance for both accounts", async () => {
  const { t, sender, recipient } = await seedFriendRequestAccounts();

  await sender.mutation(api.friend_requests.send, { email: "recipient@example.com" });
  const request = await t.run((ctx) => ctx.db.query("friend_requests").unique());
  expect(request).not.toBeNull();
  await recipient.mutation(api.friend_requests.accept, { requestId: request!._id });

  const friendRows = await t.run((ctx) => ctx.db.query("account_friends").collect());
  expect(friendRows).toHaveLength(2);
  expect(friendRows).toContainEqual(
    expect.objectContaining({
      account_email: "sender@example.com",
      member_id: "recipient_member",
      linked_member_id: "recipient_member",
      linked_account_id: "recipient_auth_id",
      linked_account_email: "recipient@example.com",
      has_linked_account: true,
      link_state: "linked",
      status: "friend"
    })
  );
  expect(friendRows).toContainEqual(
    expect.objectContaining({
      account_email: "recipient@example.com",
      member_id: "sender_member",
      linked_member_id: "sender_member",
      linked_account_id: "sender_auth_id",
      linked_account_email: "sender@example.com",
      has_linked_account: true,
      link_state: "linked",
      status: "friend"
    })
  );
});

test("friend_requests:listIncoming exposes sender auth and canonical member IDs", async () => {
  const { sender, recipient } = await seedFriendRequestAccounts();

  await sender.mutation(api.friend_requests.send, { email: "recipient@example.com" });

  const incoming = (await recipient.query(api.friend_requests.listIncoming, {})) as Array<{
    sender: { id: string; member_id: string; email: string };
  }>;
  expect(incoming).toHaveLength(1);
  expect(incoming[0].sender).toMatchObject({
    id: "sender_auth_id",
    member_id: "sender_member",
    email: "sender@example.com"
  });
});
