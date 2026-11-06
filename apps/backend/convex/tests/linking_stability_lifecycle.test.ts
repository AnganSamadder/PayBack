import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

const auth = (subject: string) => ({
  subject,
  email: `${subject}@example.com`,
  name: subject,
  tokenIdentifier: subject,
  issuer: "https://example.com",
  emailVerified: true
});
async function setup(existingB = true) {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await ctx.db.insert("identity_materialization_state", {
      key: "member_identity_v3",
      status: "ready",
      phase: "complete",
      updated_at: 1
    });
    await ctx.db.insert("cleanup_email_materialization_state", {
      key: "cleanup_email_canonicalization_v1",
      status: "ready",
      phase: "complete",
      processed: 0,
      retry_count: 0,
      updated_at: 1
    });
    for (const id of existingB ? ["a", "b"] : ["a"]) {
      await ctx.db.insert("accounts", {
        id,
        email: `${id}@example.com`,
        normalized_email: `${id}@example.com`,
        display_name: id,
        member_id: `${id}_canonical`,
        created_at: 1
      });
    }
    await ctx.db.insert("account_friends", {
      account_email: "a@example.com",
      member_id: "b_manual",
      name: "B",
      profile_avatar_color: "#000000",
      has_linked_account: false,
      link_state: "unlinked",
      status: "manual",
      updated_at: 1
    });
  });
  return { t, a: t.withIdentity(auth("a")), b: t.withIdentity(auth("b")) };
}
const createArgs = {
  id: "a_to_b",
  recipient_email: "b@example.com",
  target_member_id: "b_manual",
  target_member_name: "B"
};

test("declining an accepted link request must reject rather than falsify accepted history", async () => {
  const { t, a, b } = await setup();
  await a.mutation(api.linkRequests.createV2, createArgs);
  await b.mutation(api.linkRequests.accept, { id: "a_to_b" });
  await expect(b.mutation(api.linkRequests.decline, { id: "a_to_b" })).rejects.toThrow();
  expect(await t.run((ctx) => ctx.db.query("link_requests").unique())).toMatchObject({
    status: "accepted"
  });
  const friends = await t.run((ctx) => ctx.db.query("account_friends").collect());
  expect(friends.filter((f) => f.link_state === "linked")).toHaveLength(2);
});

test("cancelling an accepted link request must reject rather than erase accepted history", async () => {
  const { t, a, b } = await setup();
  await a.mutation(api.linkRequests.createV2, createArgs);
  await b.mutation(api.linkRequests.accept, { id: "a_to_b" });
  await expect(a.mutation(api.linkRequests.cancel, { id: "a_to_b" })).rejects.toThrow();
  expect(await t.run((ctx) => ctx.db.query("link_requests").unique())).toMatchObject({
    status: "accepted"
  });
  expect(
    (await t.run((ctx) => ctx.db.query("account_friends").collect())).filter(
      (f) => f.link_state === "linked"
    )
  ).toHaveLength(2);
});

test("invite resend returns the original client token ID", async () => {
  const { t, a } = await setup();
  await a.mutation(api.inviteTokens.create, {
    id: "original",
    target_member_id: "b_manual",
    target_member_name: "B"
  });
  await expect(
    a.mutation(api.inviteTokens.createV2, {
      id: "retry",
      target_member_id: "b_manual",
      target_member_name: "B"
    })
  ).resolves.toMatchObject({ id: "original" });
  expect(await t.run((ctx) => ctx.db.query("invite_tokens").collect())).toHaveLength(1);
});
test("email accept supports explicit reciprocal merge and exact replay", async () => {
  const { t, a, b } = await setup();
  await t.run((ctx) =>
    ctx.db.insert("account_friends", {
      account_email: "b@example.com",
      member_id: "a_manual",
      name: "A",
      profile_avatar_color: "#000000",
      has_linked_account: false,
      link_state: "unlinked",
      status: "manual",
      updated_at: 1
    })
  );
  await a.mutation(api.linkRequests.createV2, createArgs);
  const args = { id: "a_to_b", mergeLocalFriendMemberId: "a_manual" };
  const result = await b.mutation(api.linkRequests.accept, args);
  await expect(b.mutation(api.linkRequests.accept, args)).resolves.toEqual(result);
  await expect(b.mutation(api.linkRequests.accept, { id: "a_to_b" })).rejects.toThrow(
    "different merge selection"
  );
  const friends = await t.run((ctx) =>
    ctx.db
      .query("account_friends")
      .withIndex("by_account_email", (q) => q.eq("account_email", "b@example.com"))
      .collect()
  );
  expect(friends).toHaveLength(1);
  expect(friends[0].local_alias_member_ids).toContain("a_manual");
  expect(
    await t.run((ctx) =>
      ctx.db
        .query("member_aliases")
        .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", "a_manual"))
        .collect()
    )
  ).toHaveLength(0);
});

test.each(["decline", "cancel"] as const)(
  "stale %s must not revoke historical link provenance",
  async (action) => {
    const { t, a, b } = await setup();
    await a.mutation(api.linkRequests.createV2, createArgs);
    await t.run(async (ctx) => {
      const request = await ctx.db.query("link_requests").unique();
      await ctx.db.patch(request!._id, { status: "accepted" });
      const friend = await ctx.db.query("account_friends").unique();
      await ctx.db.patch(friend!._id, {
        has_linked_account: true,
        link_state: undefined,
        linked_account_id: "b",
        linked_member_id: "b_canonical",
        linked_account_email: "b@example.com"
      });
    });
    expect((await a.query(api.friends.list, {}))[0].has_linked_account).toBe(true);
    if (action === "decline")
      await expect(b.mutation(api.linkRequests.decline, { id: "a_to_b" })).rejects.toThrow(
        "no longer pending"
      );
    else
      await expect(a.mutation(api.linkRequests.cancel, { id: "a_to_b" })).rejects.toThrow(
        "no longer pending"
      );
    expect((await a.query(api.friends.list, {}))[0].has_linked_account).toBe(true);
  }
);

test("active invite recovery does not consume creation quota and previews remain unavailable", async () => {
  const { t, a } = await setup();
  for (let index = 0; index < 12; index++) {
    const token = await a.mutation(api.inviteTokens.createV2, {
      id: `retry_${index}`,
      target_member_id: "b_manual",
      target_member_name: "B"
    });
    expect(token.id).toBe("retry_0");
  }
  expect(await t.run((ctx) => ctx.db.query("invite_tokens").collect())).toHaveLength(1);
  expect(await t.query(api.inviteTokens.validate, { id: "retry_0" })).toMatchObject({
    is_valid: true,
    expense_preview: null
  });
  await expect(
    a.mutation(api.inviteTokens.create, {
      id: "legacy_retry",
      target_member_id: "b_manual",
      target_member_name: "B"
    })
  ).rejects.toThrow("active invite already exists");
});

test.each(["invite", "email"] as const)(
  "legacy %s replay cannot restore revoked alias consent",
  async (kind) => {
    const { t, a, b } = await setup();
    if (kind === "invite")
      await a.mutation(api.inviteTokens.createV2, {
        id: "a_to_b",
        target_member_id: "b_manual",
        target_member_name: "B"
      });
    else await a.mutation(api.linkRequests.createV2, createArgs);
    const endpoint = kind === "invite" ? api.inviteTokens.claim : api.linkRequests.accept;
    await b.mutation(endpoint, { id: "a_to_b" });
    await t.run(async (ctx) => {
      const account = await ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", "b"))
        .unique();
      await ctx.db.patch(account!._id, { alias_member_ids: [] });
    });
    await expect(b.mutation(endpoint, { id: "a_to_b" })).rejects.toThrow(
      "identity is no longer current"
    );
    const stored = await t.run((ctx) =>
      ctx.db.query(kind === "invite" ? "invite_tokens" : "link_requests").unique()
    );
    expect(stored).not.toBeNull();
  }
);
