import { convexTest } from "convex-test";
import { afterEach, beforeEach, expect, test, vi } from "vitest";
import { internal } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

beforeEach(() => vi.useFakeTimers());
afterEach(() => vi.useRealTimers());

async function finishScheduled(t: ReturnType<typeof convexTest>) {
  await (
    t.finishAllScheduledFunctions as (
      advanceTimers: () => void,
      maxIterations: number
    ) => Promise<void>
  )(vi.runAllTimers, 100);
}

test("janitor queues resumable cleanup for an orphaned owner", async () => {
  const t = convexTest(schema, modules);
  const orphanOwnerId = await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "orphan_auth",
      email: "orphan@example.com",
      display_name: "Orphan",
      member_id: "orphan_member",
      created_at: 1
    });
    await ctx.db.delete(ownerId);
    await ctx.db.insert("janitor_state", {
      key: "default",
      scan_phase: "groups",
      updated_at: 1
    });
    await ctx.db.insert("groups", {
      id: "orphan_group",
      name: "Orphan",
      members: [{ id: "orphan_member", name: "Orphan" }],
      owner_email: "orphan@example.com",
      owner_account_id: "orphan_auth",
      owner_id: ownerId,
      created_at: 1,
      updated_at: 1
    });
    await ctx.db.insert("expenses", {
      id: "orphan_expense",
      group_id: "orphan_group",
      context_kind: "group",
      description: "Orphan",
      date: 1,
      total_amount: 1,
      paid_by_member_id: "orphan_member",
      involved_member_ids: ["orphan_member"],
      splits: [
        {
          id: "orphan_split",
          member_id: "orphan_member",
          amount: 1,
          is_settled: false
        }
      ],
      is_settled: false,
      owner_email: "orphan@example.com",
      owner_account_id: "orphan_auth",
      owner_id: ownerId,
      participant_member_ids: ["orphan_member"],
      participant_emails: ["orphan@example.com"],
      participants: [{ member_id: "orphan_member", name: "Orphan" }],
      created_at: 1,
      updated_at: 1
    });
    return ownerId;
  });

  const result = await t.mutation(internal.janitor.cleanupOrphans, {});
  expect(result).toMatchObject({ orphansFound: 1, orphansCleaned: 1 });
  await finishScheduled(t);

  const state = await t.run(async (ctx) => ({
    groups: await ctx.db.query("groups").collect(),
    expenses: await ctx.db.query("expenses").collect()
  }));
  expect(state.groups).toEqual([]);
  expect(state.expenses).toEqual([]);
  expect(await t.run((ctx) => ctx.db.get(orphanOwnerId))).toBeNull();
});

test("janitor paginates group scans across invocations", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "live_auth",
      email: "live@example.com",
      display_name: "Live",
      member_id: "live_member",
      created_at: 1
    });
    await ctx.db.insert("janitor_state", {
      key: "default",
      scan_phase: "groups",
      updated_at: 1
    });
    for (let index = 0; index < 101; index += 1) {
      await ctx.db.insert("groups", {
        id: `live_group_${index}`,
        name: "Live",
        members: [{ id: "live_member", name: "Live" }],
        owner_email: "live@example.com",
        owner_account_id: "live_auth",
        owner_id: ownerId,
        created_at: 1,
        updated_at: 1
      });
    }
  });

  for (let invocation = 0; invocation < 3; invocation += 1) {
    await expect(t.mutation(internal.janitor.cleanupOrphans, {})).resolves.toMatchObject({
      orphansFound: 0
    });
  }
  const firstState = await t.run((ctx) =>
    ctx.db
      .query("janitor_state")
      .withIndex("by_key", (q) => q.eq("key", "default"))
      .unique()
  );
  expect(firstState?.scan_phase).toBe("groups");
  expect(firstState?.groups_cursor).toBeTruthy();

  await expect(t.mutation(internal.janitor.cleanupOrphans, {})).resolves.toMatchObject({
    orphansFound: 0
  });
  const finalState = await t.run((ctx) =>
    ctx.db
      .query("janitor_state")
      .withIndex("by_key", (q) => q.eq("key", "default"))
      .unique()
  );
  expect(finalState?.scan_phase).toBe("expenses");
  expect(finalState?.groups_cursor).toBeUndefined();
});

test("janitor discovers expense-only orphan owners", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "expense_orphan_auth",
      email: "expense-orphan@example.com",
      display_name: "Expense Orphan",
      member_id: "expense_orphan_member",
      created_at: 1
    });
    await ctx.db.delete(ownerId);
    await ctx.db.insert("janitor_state", {
      key: "default",
      scan_phase: "expenses",
      updated_at: 1
    });
    await ctx.db.insert("expenses", {
      id: "expense_only_orphan",
      group_id: "",
      context_kind: "grouped_individual",
      description: "Orphan",
      date: 1,
      total_amount: 1,
      paid_by_member_id: "expense_orphan_member",
      involved_member_ids: ["expense_orphan_member"],
      splits: [
        {
          id: "expense_only_split",
          member_id: "expense_orphan_member",
          amount: 1,
          is_settled: false
        }
      ],
      is_settled: false,
      owner_email: "expense-orphan@example.com",
      owner_account_id: "expense_orphan_auth",
      owner_id: ownerId,
      participant_member_ids: ["expense_orphan_member"],
      participant_emails: ["expense-orphan@example.com"],
      participants: [{ member_id: "expense_orphan_member", name: "Orphan" }],
      created_at: 1,
      updated_at: 1
    });
  });

  await expect(t.mutation(internal.janitor.cleanupOrphans, {})).resolves.toMatchObject({
    orphansFound: 1,
    orphansCleaned: 1
  });
  await finishScheduled(t);
  expect(await t.run((ctx) => ctx.db.query("expenses").collect())).toEqual([]);
});

test("janitor preserves links when any populated identity resolves to a live account", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await ctx.db.insert("janitor_state", {
      key: "default",
      scan_phase: "account_friends",
      updated_at: 1
    });
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@example.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: 1
    });
    await ctx.db.insert("accounts", {
      id: "live_link_auth",
      email: "live-link@example.com",
      display_name: "Live Link",
      member_id: "live_link_member",
      alias_member_ids: ["live_link_alias"],
      created_at: 1
    });
    await ctx.db.insert("member_aliases", {
      canonical_member_id: "live_link_member",
      alias_member_id: "live_link_alias",
      account_email: "live-link@example.com",
      materialization_source: "account_alias",
      source_account_id: "live_link_auth",
      created_at: 1
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "friend_by_id",
      name: "By ID",
      profile_avatar_color: "#000000",
      has_linked_account: true,
      linked_account_id: "live_link_auth",
      linked_account_email: "stale@example.com",
      updated_at: 1
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "friend_by_alias",
      name: "By Alias",
      profile_avatar_color: "#000000",
      has_linked_account: true,
      linked_member_id: "live_link_alias",
      updated_at: 1
    });
  });

  await expect(t.mutation(internal.janitor.cleanupOrphans, {})).resolves.toMatchObject({
    orphansFound: 0,
    orphansCleaned: 0
  });
  expect(await t.run((ctx) => ctx.db.query("account_friends").collect())).toHaveLength(2);
});

test("janitor ghosts links to an existing soft-deleted account", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await ctx.db.insert("janitor_state", {
      key: "default",
      scan_phase: "account_friends",
      updated_at: 1
    });
    await ctx.db.insert("accounts", {
      id: "ghost_owner_auth",
      email: "ghost-owner@example.com",
      display_name: "Owner",
      member_id: "ghost_owner_member",
      created_at: 1
    });
    await ctx.db.insert("accounts", {
      id: "soft_deleted_auth",
      email: "deleted+soft@payback.invalid",
      display_name: "Deleted User",
      member_id: "soft_deleted_member",
      status: "deleted",
      created_at: 1
    });
    await ctx.db.insert("account_friends", {
      account_email: "ghost-owner@example.com",
      member_id: "soft_deleted_member",
      name: "Deleted User",
      profile_avatar_color: "#000000",
      has_linked_account: true,
      linked_account_id: "soft_deleted_auth",
      linked_member_id: "soft_deleted_member",
      updated_at: 1
    });
  });

  await t.mutation(internal.janitor.cleanupOrphans, {});
  const friend = await t.run((ctx) => ctx.db.query("account_friends").unique());
  expect(friend).toMatchObject({
    has_linked_account: false,
    link_state: "ghost",
    status: "ghost",
    linked_member_id: "soft_deleted_member"
  });
  expect(friend?.linked_account_id).toBeUndefined();
  await t.run(async (ctx) => {
    const state = await ctx.db
      .query("janitor_state")
      .withIndex("by_key", (q) => q.eq("key", "default"))
      .unique();
    if (state) {
      await ctx.db.patch(state._id, { scan_phase: "account_friends", updated_at: 2 });
    }
  });
  await expect(t.mutation(internal.janitor.cleanupOrphans, {})).resolves.toMatchObject({
    orphansFound: 0,
    orphansCleaned: 0
  });
});

test("janitor preserves an email-only link to a mixed-case legacy account", async () => {
  const t = convexTest(schema, modules);
  await t.run(async (ctx) => {
    await ctx.db.insert("janitor_state", {
      key: "default",
      scan_phase: "account_friends",
      updated_at: 1
    });
    await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@example.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: 1
    });
    await ctx.db.insert("accounts", {
      id: "legacy_auth",
      email: "Legacy@Example.com",
      display_name: "Legacy",
      member_id: "legacy_member",
      created_at: 1
    });
    await ctx.db.insert("account_friends", {
      account_email: "owner@example.com",
      member_id: "legacy_member",
      name: "Legacy",
      profile_avatar_color: "#000000",
      has_linked_account: true,
      linked_account_email: "Legacy@Example.com",
      updated_at: 1
    });
  });

  await expect(t.mutation(internal.janitor.cleanupOrphans, {})).resolves.toMatchObject({
    orphansFound: 0
  });
  expect(await t.run((ctx) => ctx.db.query("account_friends").unique())).not.toBeNull();
});

test("janitor never hard-deletes a mixed-case live owner misclassified by exact lookup", async () => {
  const t = convexTest(schema, modules);
  const { accountId, groupId } = await t.run(async (ctx) => {
    const liveAccountId = await ctx.db.insert("accounts", {
      id: "legacy_auth",
      email: "Legacy@Example.com",
      display_name: "Legacy",
      member_id: "legacy_member",
      created_at: 1
    });
    const liveGroupId = await ctx.db.insert("groups", {
      id: "legacy_group",
      name: "Legacy",
      members: [{ id: "legacy_member", name: "Legacy" }],
      owner_email: "legacy@example.com",
      owner_account_id: "legacy_auth",
      owner_id: liveAccountId,
      created_at: 1,
      updated_at: 1
    });
    await ctx.db.insert("janitor_state", {
      key: "default",
      scan_phase: "groups",
      updated_at: 1
    });
    return { accountId: liveAccountId, groupId: liveGroupId };
  });

  await expect(t.mutation(internal.janitor.cleanupOrphans, {})).resolves.toMatchObject({
    orphansFound: 1
  });
  await finishScheduled(t);
  expect(await t.run((ctx) => ctx.db.get(accountId))).not.toBeNull();
  expect(await t.run((ctx) => ctx.db.get(groupId))).not.toBeNull();
  await t.run(async (ctx) => {
    const state = await ctx.db
      .query("janitor_state")
      .withIndex("by_key", (q) => q.eq("key", "default"))
      .unique();
    if (state) await ctx.db.patch(state._id, { scan_phase: "groups", updated_at: 2 });
  });
  await expect(t.mutation(internal.janitor.cleanupOrphans, {})).resolves.toMatchObject({
    orphansFound: 0,
    orphansCleaned: 0
  });
});

test("janitor discovers document-reference-only orphan cleanup", async () => {
  const t = convexTest(schema, modules);
  const visibilityId = await t.run(async (ctx) => {
    const ownerId = await ctx.db.insert("accounts", {
      id: "owner_auth",
      email: "owner@example.com",
      display_name: "Owner",
      member_id: "owner_member",
      created_at: 1
    });
    const deletedAccountId = await ctx.db.insert("accounts", {
      id: "deleted_auth",
      email: "deleted@example.com",
      display_name: "Deleted",
      member_id: "deleted_member",
      created_at: 1
    });
    const groupId = await ctx.db.insert("groups", {
      id: "shared_group",
      name: "Shared",
      members: [{ id: "owner_member", name: "Owner" }],
      owner_email: "owner@example.com",
      owner_account_id: "owner_auth",
      owner_id: ownerId,
      created_at: 1,
      updated_at: 1
    });
    const rowId = await ctx.db.insert("group_visibility", {
      account_id: deletedAccountId,
      group_id: groupId,
      group_updated_at: 1,
      created_at: 1,
      updated_at: 1
    });
    await ctx.db.delete(deletedAccountId);
    await ctx.db.insert("janitor_state", {
      key: "default",
      scan_phase: "group_visibility",
      updated_at: 1
    });
    return rowId;
  });

  await expect(t.mutation(internal.janitor.cleanupOrphans, {})).resolves.toMatchObject({
    orphansFound: 1,
    orphansCleaned: 1
  });
  await finishScheduled(t);
  const state = await t.run(async (ctx) => ({
    visibility: await ctx.db.get(visibilityId),
    jobs: await ctx.db.query("orphan_cleanup_jobs").collect()
  }));
  expect(state.visibility).toBeNull();
  expect(state.jobs).toHaveLength(1);
  expect(state.jobs[0]?.status).toBe("complete");
});
