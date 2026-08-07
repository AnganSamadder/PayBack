import { convexTest } from "convex-test";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { internal } from "../_generated/api";
import {
  CLEANUP_EMAIL_MATERIALIZATION_KEY,
  ensureCleanupEmailMaterializationScheduled
} from "../cleanupEmailMaterialization";
import schema from "../schema";
import { modules } from "../test.setup";

async function finishScheduled(t: ReturnType<typeof convexTest>) {
  await (
    t.finishAllScheduledFunctions as (
      advanceTimers: () => void,
      maxIterations: number
    ) => Promise<void>
  )(vi.runAllTimers, 500);
}

async function runMaterialization(t: ReturnType<typeof convexTest>) {
  await t.action(internal.users.advanceCleanupEmailMaterialization, {});
  await finishScheduled(t);
  return await t.run(async (ctx) =>
    (await ctx.db.query("cleanup_email_materialization_state").collect()).find(
      (state) => state.key === CLEANUP_EMAIL_MATERIALIZATION_KEY
    )
  );
}

describe("cleanup email materialization", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  test("normalizes cleanup artifacts across every phase while preserving account email", async () => {
    const t = convexTest(schema, modules);
    const ids = await t.run(async (ctx) => {
      const accountId = await ctx.db.insert("accounts", {
        id: "legacy_auth",
        email: "  Legacy.Account@Example.COM  ",
        display_name: "Legacy",
        member_id: "legacy_member",
        created_at: 1
      });
      const friendId = await ctx.db.insert("account_friends", {
        account_email: "  Owner@Example.COM  ",
        member_id: "friend_member",
        name: "Friend",
        profile_avatar_color: "#000000",
        has_linked_account: true,
        linked_account_email: "  Linked@Example.COM  ",
        updated_at: 1
      });
      const groupId = await ctx.db.insert("groups", {
        id: "legacy_group",
        name: "Legacy Group",
        members: [{ id: "legacy_member", name: "Legacy" }],
        owner_email: "  Group.Owner@Example.COM  ",
        owner_account_id: "legacy_auth",
        owner_id: accountId,
        created_at: 1,
        updated_at: 1
      });
      const expenseId = await ctx.db.insert("expenses", {
        id: "legacy_expense",
        group_id: "legacy_group",
        description: "Dinner",
        date: 1,
        total_amount: 20,
        paid_by_member_id: "legacy_member",
        involved_member_ids: ["legacy_member"],
        splits: [{ id: "legacy_split", member_id: "legacy_member", amount: 20, is_settled: false }],
        is_settled: false,
        owner_email: "  Expense.Owner@Example.COM  ",
        owner_account_id: "legacy_auth",
        owner_id: accountId,
        group_ref: groupId,
        participant_member_ids: ["legacy_member"],
        participant_emails: ["legacy.account@example.com"],
        participants: [{ member_id: "legacy_member", name: "Legacy" }],
        created_at: 1,
        updated_at: 1
      });
      const linkRequestId = await ctx.db.insert("link_requests", {
        id: "legacy_link_request",
        requester_id: "legacy_auth",
        requester_email: "  Requester@Example.COM  ",
        requester_name: "Requester",
        recipient_email: "  Recipient@Example.COM  ",
        target_member_id: "target_member",
        target_member_name: "Target",
        created_at: 1,
        status: "pending",
        expires_at: 2
      });
      const inviteId = await ctx.db.insert("invite_tokens", {
        id: "legacy_invite",
        creator_id: "legacy_auth",
        creator_email: "  Creator@Example.COM  ",
        target_member_id: "target_member",
        target_member_name: "Target",
        created_at: 1,
        expires_at: 2
      });
      const friendRequestId = await ctx.db.insert("friend_requests", {
        sender_id: accountId,
        recipient_email: "  Friend.Recipient@Example.COM  ",
        status: "pending",
        created_at: 1
      });
      const aliasId = await ctx.db.insert("member_aliases", {
        canonical_member_id: "legacy_member",
        alias_member_id: "legacy_alias",
        account_email: "  Alias.Owner@Example.COM  ",
        created_at: 1
      });
      const progressId = await ctx.db.insert("account_deletion_progress", {
        auth_subject: "legacy_auth",
        account_id: accountId,
        account_auth_id: "legacy_auth",
        account_email: "  Progress.Owner@Example.COM  ",
        member_ids: ["legacy_member"],
        request_id: "legacy_request",
        tombstone_email: "deleted+legacy@payback.invalid",
        phase: "preflight_groups_owner_id",
        friendships_unlinked: 0,
        processed_count: 0,
        started_at: 1,
        updated_at: 1
      });
      await ctx.db.insert("cleanup_email_materialization_state", {
        key: CLEANUP_EMAIL_MATERIALIZATION_KEY,
        status: "pending",
        phase: "accounts",
        processed: 0,
        retry_count: 0,
        updated_at: 1
      });
      return {
        accountId,
        friendId,
        groupId,
        expenseId,
        linkRequestId,
        inviteId,
        friendRequestId,
        aliasId,
        progressId
      };
    });

    await expect(runMaterialization(t)).resolves.toMatchObject({
      status: "ready",
      phase: "complete",
      retry_count: 0
    });

    const materialized = await t.run(async (ctx) => ({
      account: await ctx.db.get(ids.accountId),
      friend: await ctx.db.get(ids.friendId),
      group: await ctx.db.get(ids.groupId),
      expense: await ctx.db.get(ids.expenseId),
      linkRequest: await ctx.db.get(ids.linkRequestId),
      invite: await ctx.db.get(ids.inviteId),
      friendRequest: await ctx.db.get(ids.friendRequestId),
      alias: await ctx.db.get(ids.aliasId),
      progress: await ctx.db.get(ids.progressId)
    }));
    expect(materialized.account).toMatchObject({
      email: "  Legacy.Account@Example.COM  ",
      normalized_email: "legacy.account@example.com"
    });
    expect(materialized.friend).toMatchObject({
      account_email: "owner@example.com",
      linked_account_email: "linked@example.com"
    });
    expect(materialized.group?.owner_email).toBe("group.owner@example.com");
    expect(materialized.expense?.owner_email).toBe("expense.owner@example.com");
    expect(materialized.linkRequest).toMatchObject({
      requester_email: "requester@example.com",
      recipient_email: "recipient@example.com"
    });
    expect(materialized.invite?.creator_email).toBe("creator@example.com");
    expect(materialized.friendRequest?.recipient_email).toBe("friend.recipient@example.com");
    expect(materialized.alias?.account_email).toBe("alias.owner@example.com");
    expect(materialized.progress?.account_email).toBe("progress.owner@example.com");
  });

  test("backfills retained deletion receipt identity metadata", async () => {
    const t = convexTest(schema, modules);
    const { accountId, receiptId } = await t.run(async (ctx) => {
      const insertedAccountId = await ctx.db.insert("accounts", {
        id: "soft_deleted_auth",
        email: "deleted+soft@payback.invalid",
        display_name: "Deleted User",
        member_id: "soft_deleted_member",
        status: "deleted",
        deleted_at: 1,
        created_at: 1
      });
      const insertedReceiptId = await ctx.db.insert("account_deletion_receipts", {
        auth_subject: "soft_deleted_auth",
        account_email: "  Original.User@Example.COM  ",
        request_id: "soft_delete_request",
        deleted_at: 1,
        friendships_unlinked: 2,
        expenses_preserved: true
      });
      await ctx.db.insert("cleanup_email_materialization_state", {
        key: CLEANUP_EMAIL_MATERIALIZATION_KEY,
        status: "pending",
        phase: "accounts",
        processed: 0,
        retry_count: 0,
        updated_at: 1
      });
      return { accountId: insertedAccountId, receiptId: insertedReceiptId };
    });

    await expect(runMaterialization(t)).resolves.toMatchObject({ status: "ready" });
    expect(await t.run((ctx) => ctx.db.get(receiptId))).toMatchObject({
      account_id: accountId,
      account_email: "  Original.User@Example.COM  ",
      normalized_account_email: "original.user@example.com"
    });
  });

  test("quarantines duplicate normalized account identities without blocking completion", async () => {
    const t = convexTest(schema, modules);
    const accountIds = await t.run(async (ctx) => {
      const first = await ctx.db.insert("accounts", {
        id: "duplicate_auth_a",
        email: "Duplicate@Example.COM",
        display_name: "Duplicate A",
        member_id: "duplicate_member_a",
        created_at: 1
      });
      const second = await ctx.db.insert("accounts", {
        id: "duplicate_auth_b",
        email: "duplicate@example.com",
        display_name: "Duplicate B",
        member_id: "duplicate_member_b",
        created_at: 2
      });
      await ctx.db.insert("cleanup_email_materialization_state", {
        key: CLEANUP_EMAIL_MATERIALIZATION_KEY,
        status: "pending",
        phase: "accounts",
        processed: 0,
        retry_count: 0,
        updated_at: 1
      });
      return [first, second] as const;
    });

    await expect(runMaterialization(t)).resolves.toMatchObject({
      status: "ready",
      phase: "complete"
    });
    const result = await t.run(async (ctx) => ({
      accounts: await Promise.all(accountIds.map((id) => ctx.db.get(id))),
      quarantine: await ctx.db
        .query("janitor_quarantine")
        .withIndex("by_key", (query) => query.eq("key", "account_email:duplicate@example.com"))
        .unique()
    }));
    expect(result.accounts).toEqual([
      expect.objectContaining({
        email: "Duplicate@Example.COM",
        normalized_email: "duplicate@example.com"
      }),
      expect.objectContaining({
        email: "duplicate@example.com",
        normalized_email: "duplicate@example.com"
      })
    ]);
    expect(result.quarantine?.reason).toContain("multiple accounts");
  });

  test("restarts a stale backfilling state and completes the remaining phases", async () => {
    const t = convexTest(schema, modules);
    const friendId = await t.run(async (ctx) => {
      const insertedFriendId = await ctx.db.insert("account_friends", {
        account_email: "  Stale.Owner@Example.COM  ",
        member_id: "stale_friend",
        name: "Stale Friend",
        profile_avatar_color: "#000000",
        has_linked_account: false,
        updated_at: 1
      });
      await ctx.db.insert("cleanup_email_materialization_state", {
        key: CLEANUP_EMAIL_MATERIALIZATION_KEY,
        status: "backfilling",
        phase: "account_friends",
        processed: 1,
        retry_count: 0,
        updated_at: Date.now() - 30_001
      });
      return insertedFriendId;
    });

    await t.run(async (ctx) => {
      await ensureCleanupEmailMaterializationScheduled(ctx);
    });
    await finishScheduled(t);

    const result = await t.run(async (ctx) => ({
      friend: await ctx.db.get(friendId),
      state: (await ctx.db.query("cleanup_email_materialization_state").collect()).find(
        (state) => state.key === CLEANUP_EMAIL_MATERIALIZATION_KEY
      )
    }));
    expect(result.friend?.account_email).toBe("stale.owner@example.com");
    expect(result.state).toMatchObject({
      status: "ready",
      phase: "complete",
      retry_count: 0
    });
  });
});
