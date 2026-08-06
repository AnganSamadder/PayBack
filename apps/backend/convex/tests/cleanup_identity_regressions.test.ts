import { convexTest } from "convex-test";
import { afterEach, beforeEach, expect, test, vi } from "vitest";
import { api, internal } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";
import { enqueueOrphanCleanupJob } from "../users";

function identity(email: string, subject: string) {
  return {
    subject,
    email,
    name: "Legacy User",
    pictureUrl: "http://placeholder.com",
    tokenIdentifier: subject,
    issuer: "http://placeholder.com",
    emailVerified: true,
    updatedAt: "2023-01-01"
  };
}

async function finishScheduled(t: ReturnType<typeof convexTest>) {
  await (
    t.finishAllScheduledFunctions as (
      advanceTimers: () => void,
      maxIterations: number
    ) => Promise<void>
  )(vi.runAllTimers, 250);
}

beforeEach(() => vi.useFakeTimers());
afterEach(() => vi.useRealTimers());

test("users.store preserves an existing mixed-case account through normalized email", async () => {
  const t = convexTest(schema, modules);
  const existingAccountId = await t.run((ctx) =>
    ctx.db.insert("accounts", {
      id: "legacy_auth",
      email: "Legacy@Example.com",
      normalized_email: "legacy@example.com",
      display_name: "Legacy User",
      member_id: "legacy_member",
      created_at: 1
    })
  );

  const user = t.withIdentity(identity("legacy@example.com", "legacy_auth"));
  await expect(
    user.mutation(api.users.store, {
      clientCapability: "resumable_orphan_cleanup_v1"
    })
  ).resolves.toBe(existingAccountId);

  const accounts = await t.run((ctx) => ctx.db.query("accounts").collect());
  expect(accounts).toHaveLength(1);
  expect(accounts[0]?._id).toBe(existingAccountId);
});

test("users.store canonicalizes and clears mixed-case legacy artifacts before creation", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await ctx.db.insert("account_friends", {
      account_email: "Legacy@Example.com",
      member_id: "legacy_friend",
      name: "Legacy Friend",
      profile_avatar_color: "#000000",
      has_linked_account: false,
      updated_at: 1
    });
  });

  const user = t.withIdentity(identity("legacy@example.com", "new_auth"));
  await expect(
    user.mutation(api.users.store, {
      clientCapability: "resumable_orphan_cleanup_v1"
    })
  ).resolves.toBe("preparing:new_auth");
  await finishScheduled(t);

  const accountId = await user.mutation(api.users.store, {
    clientCapability: "resumable_orphan_cleanup_v1"
  });
  expect(accountId).not.toContain("preparing:");
  expect(await t.run((ctx) => ctx.db.query("account_friends").collect())).toEqual([]);
  expect(await t.run((ctx) => ctx.db.query("accounts").collect())).toHaveLength(1);
});

test("janitor preserves a lowercase email-only link to a mixed-case live account", async () => {
  const t = convexTest(schema, modules);
  const friendId = await t.run(async (ctx) => {
    await ctx.db.insert("janitor_state", {
      key: "default",
      scan_phase: "account_friends",
      updated_at: 1
    });
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@example.com",
      normalized_email: "owner@example.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: 1
    });
    await ctx.db.insert("accounts", {
      id: "legacy_auth",
      email: "Legacy@Example.com",
      normalized_email: "legacy@example.com",
      display_name: "Legacy User",
      member_id: "legacy_member",
      created_at: 1
    });
    return await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "legacy_friend",
      name: "Legacy User",
      profile_avatar_color: "#000000",
      has_linked_account: true,
      linked_account_email: "legacy@example.com",
      updated_at: 1
    });
  });

  await expect(t.mutation(internal.janitor.cleanupOrphans, {})).resolves.toMatchObject({
    orphansFound: 0,
    orphansCleaned: 0
  });
  expect(await t.run((ctx) => ctx.db.get(friendId))).not.toBeNull();
});

test("hard orphan cleanup drains alias-only provenance", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await ctx.db.insert("member_aliases", {
      canonical_member_id: "deleted_member",
      alias_member_id: "deleted_alias",
      account_email: "deleted@example.com",
      created_at: 1
    });
    await enqueueOrphanCleanupJob(ctx, {
      email: "deleted@example.com",
      subject: "deleted_auth",
      mode: "hard"
    });
  });

  await finishScheduled(t);
  expect(await t.run((ctx) => ctx.db.query("member_aliases").collect())).toEqual([]);
});

test("an account created after the job scan blocks destructive cleanup", async () => {
  const t = convexTest(schema, modules);
  const { friendId, jobId, liveAccountId } = await t.run(async (ctx) => {
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@example.com",
      normalized_email: "owner@example.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: 1
    });
    const insertedLiveAccountId = await ctx.db.insert("accounts", {
      id: "new_live_auth",
      email: "Legacy@Example.com",
      normalized_email: "legacy@example.com",
      display_name: "Legacy User",
      member_id: "new_live_member",
      created_at: 2
    });
    const insertedFriendId = await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "legacy_friend",
      name: "Legacy User",
      profile_avatar_color: "#000000",
      has_linked_account: true,
      linked_account_email: "legacy@example.com",
      updated_at: 1
    });
    const insertedJobId = await ctx.db.insert("orphan_cleanup_jobs", {
      email: "legacy@example.com",
      source_email: "legacy@example.com",
      subject: "deleted_auth",
      member_ids: [],
      mode: "hard",
      allow_live_account_hard_delete: false,
      status: "pending",
      processed_count: 0,
      retry_count: 0,
      account_scan_complete: true,
      orphan_scan_phase: "complete",
      member_scan_complete: true,
      created_at: 1,
      updated_at: 1
    });
    return {
      friendId: insertedFriendId,
      jobId: insertedJobId,
      liveAccountId: insertedLiveAccountId
    };
  });

  await t.action(internal.users.advanceOrphanCleanupJob, { jobId });
  await finishScheduled(t);

  expect(await t.run((ctx) => ctx.db.get(liveAccountId))).not.toBeNull();
  expect(await t.run((ctx) => ctx.db.get(friendId))).not.toBeNull();
});
