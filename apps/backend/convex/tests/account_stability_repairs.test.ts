import { convexTest } from "convex-test";
import { expect, test, vi } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";
import { finishScheduledFunctions } from "../../tests/helpers/schedulerTestUtils";

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

test.each([false, true])(
  "signup must preserve a genuine pending incoming link request (resumable=%s)",
  async (resumable) => {
    vi.useFakeTimers();
    try {
      const { t, a, b } = await setup(false);
      await a.mutation(api.linkRequests.createV2, createArgs);
      expect(await t.run((ctx) => ctx.db.query("link_requests").collect())).toHaveLength(1);
      let stored = await b.mutation(
        api.users.store,
        resumable ? { clientCapability: "resumable_orphan_cleanup_v1" } : {}
      );
      if (resumable) {
        if (String(stored).startsWith("preparing:")) await finishScheduledFunctions(t, 200);
        stored = await b.mutation(api.users.store, {
          clientCapability: "resumable_orphan_cleanup_v1"
        });
      }
      expect(stored).not.toContain("preparing:");
      expect(await b.query(api.linkRequests.listIncoming, {})).toHaveLength(1);
      await expect(b.mutation(api.linkRequests.accept, { id: "a_to_b" })).resolves.toBeDefined();
    } finally {
      vi.useRealTimers();
    }
  }
);

test("repeating legacy friend send must preserve confirmed friend status", async () => {
  const { t, a, b } = await setup();
  await a.mutation(api.friend_requests.send, { email: "b@example.com" });
  const request = await t.run((ctx) => ctx.db.query("friend_requests").unique());
  await b.mutation(api.friend_requests.accept, { requestId: request!._id });
  await a.mutation(api.friend_requests.send, { email: "b@example.com" });
  const row = await t.run((ctx) =>
    ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", "a@example.com").eq("member_id", "b_canonical")
      )
      .unique()
  );
  expect(row).toMatchObject({ status: "friend", has_linked_account: true, link_state: "linked" });
});

test("legacy bootstrap rejects a caller-selected placeholder and store assigns a stable canonical", async () => {
  const { t, b } = await setup();
  await t.run(async (ctx) => {
    const account = await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", "b"))
      .unique();
    await ctx.db.patch(account!._id, { member_id: undefined });
  });
  await expect(
    b.mutation(api.users.updateLinkedMemberId, { member_id: "b_manual" })
  ).rejects.toThrow();
  await b.mutation(api.users.store, {});
  const first = await b.query(api.users.viewer, {});
  expect(first?.member_id).toMatch(/^[0-9a-f-]{36}$/);
  expect(first?.member_id).not.toBe("b_manual");
  await b.mutation(api.users.store, {});
  expect((await b.query(api.users.viewer, {}))?.member_id).toBe(first?.member_id);
  await expect(
    b.mutation(api.users.updateLinkedMemberId, { member_id: first!.member_id })
  ).resolves.toBe(first!._id);
});

test("directory denies an authenticated identity without a PayBack account", async () => {
  const { t } = await setup();
  await expect(
    t.withIdentity(auth("stranger")).query(api.users.validateAccountIds, { ids: ["a"] })
  ).rejects.toThrow();
});

test("directory returns only self and visible accounts, bounds and deduplicates IDs", async () => {
  const { t, a } = await setup();
  await t.run(async (ctx) => {
    await ctx.db.insert("sync_materialization_state", {
      key: "group_visibility_v1",
      status: "ready",
      processed: 0,
      updated_at: 1
    });
  });
  expect(await a.query(api.users.validateAccountIds, { ids: ["a", "b", "a"] })).toEqual(["a"]);
  await expect(
    a.query(api.users.validateAccountIds, { ids: Array.from({ length: 66 }, (_, i) => String(i)) })
  ).rejects.toThrow();
  await t.run((ctx) =>
    ctx.db.insert("account_friends", {
      account_email: "a@example.com",
      member_id: "b_canonical",
      name: "B",
      has_linked_account: true,
      linked_account_id: "b",
      linked_account_email: "b@example.com",
      linked_member_id: "b_canonical",
      link_state: "linked",
      status: "friend",
      profile_avatar_color: "#000000",
      updated_at: 1
    })
  );
  expect(await a.query(api.users.validateAccountIds, { ids: ["b", "a", "b"] })).toEqual(["b", "a"]);
});

test("friend sync validates expected actor before every upsert", async () => {
  const { t, b } = await setup();
  await expect(
    b.mutation(api.friends.upsert, {
      member_id: "new",
      name: "New",
      has_linked_account: false,
      expected_account_id: "a",
      expected_account_email: "a@example.com"
    })
  ).rejects.toThrow("account changed");
  expect(
    await t.run((ctx) =>
      ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (q) => q.eq("account_email", "b@example.com"))
        .collect()
    )
  ).toEqual([]);
});

test("omitted legacy name preferences survive a friend update", async () => {
  const { t, a } = await setup();
  await t.run(async (ctx) => {
    const f = await ctx.db.query("account_friends").unique();
    await ctx.db.patch(f!._id, {
      original_name: "Original",
      original_nickname: "Old nickname",
      prefer_nickname: true
    });
  });
  await a.mutation(api.friends.upsert, {
    member_id: "b_manual",
    name: "B updated",
    has_linked_account: false
  });
  expect(await t.run((ctx) => ctx.db.query("account_friends").unique())).toMatchObject({
    original_name: "Original",
    original_nickname: "Old nickname",
    prefer_nickname: true
  });
});

test("versioned bootstrap returns the server canonical across retries and rejects a stale actor", async () => {
  const { b } = await setup();
  const args = { expected_account_id: "b", financial_contract_version: 2 };
  const first = await b.mutation(api.users.bootstrapMemberIdentityV2, args);
  expect(first).toEqual({ account_id: "b", member_id: "b_canonical", version: 2 });
  expect(await b.mutation(api.users.bootstrapMemberIdentityV2, args)).toEqual(first);
  await expect(
    b.mutation(api.users.bootstrapMemberIdentityV2, { ...args, expected_account_id: "a" })
  ).rejects.toThrow("account changed");
});

test("capability floor blocks alias-bearing channels while neutral authentication recovery remains available", async () => {
  const { t, a } = await setup();
  await t.run(async (ctx) => {
    const user = await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", "a"))
      .unique();
    await ctx.db.patch(user!._id, { required_financial_contract: 2 });
  });
  await expect(a.query(api.users.viewer, {})).rejects.toThrow(
    "FINANCIAL_CONTRACT_UPGRADE_REQUIRED"
  );
  await expect(a.query(api.friends.list, {})).rejects.toThrow(
    "FINANCIAL_CONTRACT_UPGRADE_REQUIRED"
  );
  expect(await a.query(api.users.authenticationStatus, {})).toEqual({
    id: "a",
    email: "a@example.com",
    display_name: "a",
    status: "active"
  });
  expect((await a.query(api.users.viewer, { financial_contract_version: 2 }))?.member_id).toBe(
    "a_canonical"
  );
});

test("signup drains stale incoming requests beyond retained pages and preserves every live request", async () => {
  vi.useFakeTimers();
  try {
    const { t, b } = await setup(false);
    await t.run(async (ctx) => {
      const friend = await ctx.db.query("account_friends").unique();
      for (let index = 0; index < 19; index++)
        await ctx.db.insert("link_requests", {
          id: `request_${index}`,
          requester_id: "a",
          requester_email: "a@example.com",
          requester_name: "A",
          recipient_email: "b@example.com",
          target_member_id: "b_manual",
          target_friend_id: friend!._id,
          target_member_name: "B",
          created_at: index,
          status: "pending",
          expires_at: index === 18 ? 1 : Date.now() + 100000
        });
    });
    expect(
      await b.mutation(api.users.store, { clientCapability: "resumable_orphan_cleanup_v1" })
    ).toBe("preparing:b");
    await finishScheduledFunctions(t, 200);
    await b.mutation(api.users.store, { clientCapability: "resumable_orphan_cleanup_v1" });
    expect(await t.run((ctx) => ctx.db.query("link_requests").collect())).toHaveLength(18);
  } finally {
    vi.useRealTimers();
  }
});

test("settings and each account deletion step reject a switched actor before any write", async () => {
  const { t, b } = await setup();
  await expect(
    b.mutation(api.users.updateSettings, { expected_account_id: "a", prefer_nicknames: true })
  ).rejects.toThrow("account changed");
  await expect(
    b.mutation(api.cleanup.selfDeleteAccount, {
      expected_account_id: "a",
      clientCapability: "bounded_progress_v1"
    })
  ).rejects.toThrow("account changed");
  const account = await t.run((ctx) =>
    ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", "b"))
      .unique()
  );
  expect(account?.prefer_nicknames).toBeUndefined();
  expect(account?.status).toBeUndefined();
  expect(await t.run((ctx) => ctx.db.query("account_deletion_progress").collect())).toEqual([]);
});
