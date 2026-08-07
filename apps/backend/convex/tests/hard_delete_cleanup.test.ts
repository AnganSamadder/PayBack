import { convexTest } from "convex-test";
import { afterEach, beforeEach, expect, test, describe, vi } from "vitest";
import { api, internal } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";
import { enqueueOrphanCleanupJob } from "../users";

function adminIdentity() {
  return {
    subject: "admin_user",
    email: "admin@test.com",
    name: "Admin",
    pictureUrl: "http://placeholder.com",
    tokenIdentifier: "admin_user",
    issuer: "http://placeholder.com",
    emailVerified: true,
    updatedAt: "2023-01-01"
  };
}

async function markCleanupEmailMaterializationReady(t: ReturnType<typeof convexTest>) {
  await t.run((ctx) =>
    ctx.db.insert("cleanup_email_materialization_state", {
      key: "cleanup_email_canonicalization_v1",
      status: "ready",
      phase: "complete",
      processed: 0,
      retry_count: 0,
      updated_at: 1
    })
  );
}

describe("Hard Delete Cleanup", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  async function finishScheduled(t: ReturnType<typeof convexTest>) {
    await (
      t.finishAllScheduledFunctions as (
        advanceTimers: () => void,
        maxIterations: number
      ) => Promise<void>
    )(vi.runAllTimers, 2_000);
  }

  test("admin missing-account cleanup resumes orphan deletion", async () => {
    const t = convexTest(schema, modules);
    await markCleanupEmailMaterializationReady(t);
    await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "missing_auth",
        email: "missing@test.com",
        display_name: "Missing",
        member_id: "missing_member",
        created_at: 1
      });
      await ctx.db.delete(ownerId);
      await ctx.db.insert("groups", {
        id: "missing_group",
        name: "Missing",
        members: [{ id: "missing_member", name: "Missing" }],
        owner_email: "missing@test.com",
        owner_account_id: "missing_auth",
        owner_id: ownerId,
        created_at: 1,
        updated_at: 1
      });
      await ctx.db.insert("account_friends", {
        account_email: "survivor@test.com",
        member_id: "missing_friend",
        name: "Missing",
        profile_avatar_color: "#000000",
        has_linked_account: true,
        linked_account_id: "missing_auth",
        linked_account_email: "missing@test.com",
        updated_at: 1
      });
    });

    process.env.ADMIN_EMAILS = "admin@test.com";
    const result = await t
      .withIdentity(adminIdentity())
      .mutation(api.admin.hardDeleteUser, { email: "missing@test.com" });
    expect(result.status).toBe("not_found_cleanup_in_progress");
    await finishScheduled(t);
    expect(await t.run((ctx) => ctx.db.query("groups").collect())).toEqual([]);
    expect(await t.run((ctx) => ctx.db.query("account_friends").collect())).toEqual([]);
  });

  test("admin hard deletion fails closed when supplied selectors disagree", async () => {
    const t = convexTest(schema, modules);
    await markCleanupEmailMaterializationReady(t);
    const accountId = await t.run((ctx) =>
      ctx.db.insert("accounts", {
        id: "selected_auth",
        email: "selected@example.com",
        normalized_email: "selected@example.com",
        display_name: "Selected",
        member_id: "selected_member",
        created_at: 1
      })
    );

    process.env.ADMIN_EMAILS = "admin@test.com";
    const admin = t.withIdentity(adminIdentity());
    await expect(
      admin.mutation(api.admin.hardDeleteUser, {
        accountId,
        email: "wrong@example.com"
      })
    ).rejects.toThrow("Email does not resolve to the supplied account selector");
    await expect(
      admin.mutation(api.admin.hardDeleteUser, {
        accountId,
        authSubject: "wrong_auth"
      })
    ).rejects.toThrow("Auth subject does not resolve to an account");
    expect(await t.run((ctx) => ctx.db.get(accountId))).not.toBeNull();
    expect(await t.run((ctx) => ctx.db.query("account_deletion_progress").collect())).toEqual([]);
  });

  test("admin email-only orphan purge never follows stale ownership to a live account", async () => {
    const t = convexTest(schema, modules);
    await markCleanupEmailMaterializationReady(t);
    const { liveAccountId, requestId, inviteId } = await t.run(async (ctx) => {
      const accountId = await ctx.db.insert("accounts", {
        id: "live_auth",
        email: "current@example.com",
        normalized_email: "current@example.com",
        display_name: "Live",
        member_id: "live_member",
        created_at: 1
      });
      const staleRequestId = await ctx.db.insert("link_requests", {
        id: "stale_request",
        requester_id: "live_auth",
        requester_email: "orphan@example.com",
        requester_name: "Live",
        recipient_email: "recipient@example.com",
        target_member_id: "recipient_member",
        target_member_name: "Recipient",
        created_at: 1,
        status: "pending",
        expires_at: 2
      });
      const staleInviteId = await ctx.db.insert("invite_tokens", {
        id: "stale_invite",
        creator_id: "live_auth",
        creator_email: "orphan@example.com",
        target_member_id: "recipient_member",
        target_member_name: "Recipient",
        created_at: 1,
        expires_at: 2
      });
      return { liveAccountId: accountId, requestId: staleRequestId, inviteId: staleInviteId };
    });

    process.env.ADMIN_EMAILS = "admin@test.com";
    await expect(
      t.withIdentity(adminIdentity()).mutation(api.admin.hardDeleteUser, {
        email: "orphan@example.com"
      })
    ).resolves.toMatchObject({ status: "not_found_cleanup_in_progress" });
    await finishScheduled(t);

    expect(await t.run((ctx) => ctx.db.get(liveAccountId))).not.toBeNull();
    expect(await t.run((ctx) => ctx.db.get(requestId))).not.toBeNull();
    expect(await t.run((ctx) => ctx.db.get(inviteId))).not.toBeNull();
    expect(await t.run((ctx) => ctx.db.query("account_deletion_progress").collect())).toEqual([]);
    expect(await t.run((ctx) => ctx.db.query("orphan_cleanup_jobs").unique())).toMatchObject({
      status: "failed"
    });
  });

  test("admin can resume an orphan cleanup after bounded worker retries", async () => {
    const t = convexTest(schema, modules);
    await t.run((ctx) =>
      ctx.db.insert("orphan_cleanup_jobs", {
        email: "resume@example.com",
        subject: "poisoned_auth",
        member_ids: ["poisoned_member"],
        mode: "hard",
        status: "failed",
        processed_count: 4,
        retry_count: 3,
        last_error: "temporary outage",
        account_scan_complete: true,
        metadata_refresh_complete: true,
        orphan_scan_phase: "complete",
        linked_scan_phase: "complete",
        member_scan_complete: true,
        created_at: 1,
        updated_at: 1
      })
    );

    process.env.ADMIN_EMAILS = "admin@test.com";
    await expect(
      t.withIdentity(adminIdentity()).mutation(api.admin.resumeOrphanCleanup, {
        email: "resume@example.com",
        resetDerivedState: true
      })
    ).resolves.toMatchObject({ status: "pending", resetDerivedState: true });
    expect(await t.run((ctx) => ctx.db.query("orphan_cleanup_jobs").unique())).toMatchObject({
      status: "pending",
      retry_count: 0,
      processed_count: 4,
      subject: "orphan:resume@example.com",
      member_ids: []
    });
    await finishScheduled(t);
    expect(await t.run((ctx) => ctx.db.query("orphan_cleanup_jobs").unique())).toMatchObject({
      status: "complete",
      subject: "orphan:resume@example.com",
      member_ids: []
    });
  });

  test("admin hard deletion completes above the legacy expense limit", async () => {
    const t = convexTest(schema, modules);
    await markCleanupEmailMaterializationReady(t);
    const accountId = await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "large_delete_auth",
        email: "large-delete@test.com",
        display_name: "Large Delete",
        member_id: "large_delete_member",
        created_at: 1
      });
      for (let index = 0; index < 513; index += 1) {
        await ctx.db.insert("expenses", {
          id: `large_delete_expense_${index}`,
          group_id: "",
          context_kind: "grouped_individual",
          description: "Large delete",
          date: 1,
          total_amount: 1,
          paid_by_member_id: "large_delete_member",
          involved_member_ids: ["large_delete_member"],
          splits: [
            {
              id: `large_delete_split_${index}`,
              member_id: "large_delete_member",
              amount: 1,
              is_settled: false
            }
          ],
          is_settled: false,
          owner_email: "large-delete@test.com",
          owner_account_id: "large_delete_auth",
          owner_id: ownerId,
          participant_member_ids: ["large_delete_member"],
          participant_emails: ["large-delete@test.com"],
          participants: [{ member_id: "large_delete_member", name: "Owner" }],
          created_at: 1,
          updated_at: 1
        });
      }
      return ownerId;
    });

    process.env.ADMIN_EMAILS = "admin@test.com";
    const result = await t
      .withIdentity(adminIdentity())
      .mutation(api.admin.hardDeleteUser, { email: "large-delete@test.com" });
    expect(result.status).toBe("in_progress");
    await finishScheduled(t);

    expect(await t.run((ctx) => ctx.db.get(accountId))).toBeNull();
    expect(await t.run((ctx) => ctx.db.query("expenses").collect())).toEqual([]);
    const receipt = await t.run((ctx) =>
      ctx.db
        .query("account_deletion_receipts")
        .withIndex("by_auth_subject", (q) => q.eq("auth_subject", "large_delete_auth"))
        .unique()
    );
    expect(receipt?.expenses_preserved).toBe(false);
  }, 240_000);

  test("admin hard deletion accepts a 65-participant expense", async () => {
    const t = convexTest(schema, modules);
    await markCleanupEmailMaterializationReady(t);
    const accountId = await t.run(async (ctx) => {
      const ownerId = await ctx.db.insert("accounts", {
        id: "boundary_delete_auth",
        email: "boundary-delete@test.com",
        display_name: "Boundary Delete",
        member_id: "boundary_delete_member",
        created_at: 1
      });
      const memberIds = Array.from({ length: 65 }, (_, index) => `boundary_member_${index}`);
      await ctx.db.insert("expenses", {
        id: "boundary_delete_expense",
        group_id: "",
        context_kind: "grouped_individual",
        description: "Boundary delete",
        date: 1,
        total_amount: 65,
        paid_by_member_id: memberIds[0],
        involved_member_ids: memberIds,
        splits: memberIds.map((memberId, index) => ({
          id: `boundary_split_${index}`,
          member_id: memberId,
          amount: 1,
          is_settled: false
        })),
        is_settled: false,
        owner_email: "boundary-delete@test.com",
        owner_account_id: "boundary_delete_auth",
        owner_id: ownerId,
        participant_member_ids: memberIds,
        participant_emails: [],
        participants: memberIds.map((memberId) => ({ member_id: memberId, name: memberId })),
        created_at: 1,
        updated_at: 1
      });
      return ownerId;
    });

    process.env.ADMIN_EMAILS = "admin@test.com";
    await expect(
      t
        .withIdentity(adminIdentity())
        .mutation(api.admin.hardDeleteUser, { email: "boundary-delete@test.com" })
    ).resolves.toMatchObject({ status: "in_progress" });
    await finishScheduled(t);

    expect(await t.run((ctx) => ctx.db.get(accountId))).toBeNull();
    expect(
      await t.run((ctx) =>
        ctx.db
          .query("expenses")
          .withIndex("by_client_id", (q) => q.eq("id", "boundary_delete_expense"))
          .unique()
      )
    ).toBeNull();
  });

  test("internal hard delete awaits centralized expense cleanup and bumps surviving viewers once", async () => {
    const t = convexTest(schema, modules);
    await markCleanupEmailMaterializationReady(t);
    const fixture = await t.run(async (ctx) => {
      const survivorId = await ctx.db.insert("accounts", {
        id: "survivor_auth",
        email: "survivor@test.com",
        display_name: "Survivor",
        created_at: 1,
        member_id: "survivor_member"
      });
      const deletedId = await ctx.db.insert("accounts", {
        id: "deleted_auth",
        email: "deleted@test.com",
        display_name: "Deleted",
        created_at: 1,
        member_id: "deleted_member"
      });
      const expenseId = await ctx.db.insert("expenses", {
        id: "hard_delete_expense",
        group_id: "hard_delete_group",
        description: "Dinner",
        date: 1,
        total_amount: 20,
        paid_by_member_id: "deleted_member",
        involved_member_ids: ["deleted_member", "survivor_member"],
        splits: [
          { id: "deleted_split", member_id: "deleted_member", amount: 10, is_settled: false },
          { id: "survivor_split", member_id: "survivor_member", amount: 10, is_settled: false }
        ],
        is_settled: false,
        owner_email: "deleted@test.com",
        owner_account_id: "deleted_auth",
        owner_id: deletedId,
        participant_member_ids: ["deleted_member", "survivor_member"],
        participant_emails: ["deleted@test.com", "survivor@test.com"],
        participants: [
          { member_id: "deleted_member", name: "Deleted" },
          { member_id: "survivor_member", name: "Survivor" }
        ],
        created_at: 1,
        updated_at: 1
      });
      for (const account of [
        { id: deletedId, auth: "deleted_auth" },
        { id: survivorId, auth: "survivor_auth" }
      ]) {
        await ctx.db.insert("user_expenses", {
          user_id: account.auth,
          expense_id: "hard_delete_expense",
          account_ref: account.id,
          expense_ref: expenseId,
          updated_at: 1
        });
      }
      return { survivorId, deletedId };
    });

    await t.mutation(internal.cleanup.hardDeleteAccount, { accountId: fixture.deletedId });
    await finishScheduled(t);

    const state = await t.run(async (ctx) => ({
      expenses: await ctx.db.query("expenses").collect(),
      visibility: await ctx.db.query("user_expenses").collect(),
      survivorRevision: await ctx.db
        .query("account_sync_state")
        .withIndex("by_account_id", (query) => query.eq("account_id", fixture.survivorId))
        .unique(),
      deletedRevision: await ctx.db
        .query("account_sync_state")
        .withIndex("by_account_id", (query) => query.eq("account_id", fixture.deletedId))
        .unique()
    }));
    expect(state.expenses).toEqual([]);
    expect(state.visibility).toEqual([]);
    expect(state.survivorRevision?.expenses_revision).toBe(1);
    expect(state.deletedRevision).toBeNull();
  });

  test("hard delete removes owned survivor groups and aliases created by another account", async () => {
    const t = convexTest(schema, modules);
    await markCleanupEmailMaterializationReady(t);
    const fixture = await t.run(async (ctx) => {
      const deletedId = await ctx.db.insert("accounts", {
        id: "hard_owner_auth",
        email: "hard-owner@test.com",
        display_name: "Hard Owner",
        member_id: "hard_owner_member",
        alias_member_ids: ["hard_owner_alias"],
        created_at: 1
      });
      await ctx.db.insert("accounts", {
        id: "hard_survivor_auth",
        email: "hard-survivor@test.com",
        display_name: "Hard Survivor",
        member_id: "hard_survivor_member",
        created_at: 1
      });
      await ctx.db.insert("member_aliases", {
        canonical_member_id: "hard_owner_member",
        alias_member_id: "hard_owner_alias",
        account_email: "hard-survivor@test.com",
        created_at: 1
      });
      await ctx.db.insert("member_aliases", {
        canonical_member_id: "hard_survivor_member",
        alias_member_id: "hard_owner_member",
        account_email: "hard-survivor@test.com",
        created_at: 1
      });
      const groupId = await ctx.db.insert("groups", {
        id: "hard_owned_group",
        name: "Hard Owned",
        members: [{ id: "hard_survivor_member", name: "Survivor" }],
        owner_email: "hard-owner@test.com",
        owner_account_id: "hard_owner_auth",
        owner_id: deletedId,
        created_at: 1,
        updated_at: 1
      });
      await ctx.db.insert("expenses", {
        id: "hard_owned_group_expense",
        group_id: "hard_owned_group",
        group_ref: groupId,
        context_kind: "group",
        description: "Delete me",
        date: 1,
        total_amount: 1,
        paid_by_member_id: "hard_owner_member",
        involved_member_ids: ["hard_owner_member", "hard_survivor_member"],
        splits: [
          {
            id: "hard_owned_split",
            member_id: "hard_survivor_member",
            amount: 1,
            is_settled: false
          }
        ],
        is_settled: false,
        owner_email: "hard-owner@test.com",
        owner_account_id: "hard_owner_auth",
        owner_id: deletedId,
        participant_member_ids: ["hard_owner_member", "hard_survivor_member"],
        participant_emails: ["hard-owner@test.com", "hard-survivor@test.com"],
        participants: [
          { member_id: "hard_owner_member", name: "Owner" },
          { member_id: "hard_survivor_member", name: "Survivor" }
        ],
        created_at: 1,
        updated_at: 1
      });
      return deletedId;
    });

    await t.mutation(internal.cleanup.hardDeleteAccount, { accountId: fixture });
    await finishScheduled(t);

    const state = await t.run(async (ctx) => ({
      deletedAccount: await ctx.db.get(fixture),
      groups: await ctx.db.query("groups").collect(),
      expenses: await ctx.db.query("expenses").collect(),
      aliases: await ctx.db.query("member_aliases").collect()
    }));
    expect(state.deletedAccount).toBeNull();
    expect(state.groups).toEqual([]);
    expect(state.expenses).toEqual([]);
    expect(state.aliases).toEqual([]);
  });

  test("admin orphan cleanup routes expense deletion through surviving viewer revisions", async () => {
    const t = convexTest(schema, modules);
    await markCleanupEmailMaterializationReady(t);
    const fixture = await t.run(async (ctx) => {
      const survivorId = await ctx.db.insert("accounts", {
        id: "janitor_survivor_auth",
        email: "janitor-survivor@test.com",
        display_name: "Survivor",
        created_at: 1,
        member_id: "janitor_survivor_member"
      });
      const deletedId = await ctx.db.insert("accounts", {
        id: "janitor_deleted_auth",
        email: "janitor-deleted@test.com",
        display_name: "Deleted",
        created_at: 1,
        member_id: "janitor_deleted_member"
      });
      const expenseId = await ctx.db.insert("expenses", {
        id: "janitor_delete_expense",
        group_id: "janitor_delete_group",
        description: "Dinner",
        date: 1,
        total_amount: 20,
        paid_by_member_id: "janitor_deleted_member",
        involved_member_ids: ["janitor_deleted_member", "janitor_survivor_member"],
        splits: [
          {
            id: "janitor_deleted_split",
            member_id: "janitor_deleted_member",
            amount: 10,
            is_settled: false
          },
          {
            id: "janitor_survivor_split",
            member_id: "janitor_survivor_member",
            amount: 10,
            is_settled: false
          }
        ],
        is_settled: false,
        owner_email: "janitor-deleted@test.com",
        owner_account_id: "janitor_deleted_auth",
        owner_id: deletedId,
        participant_member_ids: ["janitor_deleted_member", "janitor_survivor_member"],
        participant_emails: ["janitor-deleted@test.com", "janitor-survivor@test.com"],
        participants: [
          { member_id: "janitor_deleted_member", name: "Deleted" },
          { member_id: "janitor_survivor_member", name: "Survivor" }
        ],
        created_at: 1,
        updated_at: 1
      });
      await ctx.db.insert("user_expenses", {
        user_id: "janitor_survivor_auth",
        expense_id: "janitor_delete_expense",
        account_ref: survivorId,
        expense_ref: expenseId,
        updated_at: 1
      });
      return { survivorId };
    });

    process.env.ADMIN_EMAILS = "admin@test.com";
    await t
      .withIdentity(adminIdentity())
      .mutation(api.admin.hardDeleteUser, { email: "janitor-deleted@test.com" });
    await finishScheduled(t);

    const state = await t.run(async (ctx) => ({
      expenses: await ctx.db.query("expenses").collect(),
      visibility: await ctx.db.query("user_expenses").collect(),
      survivorRevision: await ctx.db
        .query("account_sync_state")
        .withIndex("by_account_id", (query) => query.eq("account_id", fixture.survivorId))
        .unique()
    }));
    expect(state.expenses).toEqual([]);
    expect(state.visibility).toEqual([]);
    expect(state.survivorRevision?.expenses_revision).toBe(1);
  });

  test("friends.list returns unlinked state when linked account is manually deleted", async () => {
    const t = convexTest(schema, modules);
    await markCleanupEmailMaterializationReady(t);

    const userAId = await t.run(async (ctx) => {
      return await ctx.db.insert("accounts", {
        id: "user_a",
        email: "user_a@test.com",
        display_name: "User A",
        created_at: Date.now(),
        member_id: "member_a"
      });
    });

    const userBId = await t.run(async (ctx) => {
      return await ctx.db.insert("accounts", {
        id: "user_b",
        email: "user_b@test.com",
        display_name: "User B",
        created_at: Date.now(),
        member_id: "member_b"
      });
    });

    await t.run(async (ctx) => {
      await ctx.db.insert("account_friends", {
        account_email: "user_a@test.com",
        member_id: "friend_member_b",
        name: "User B",
        profile_avatar_color: "#FF0000",
        has_linked_account: true,
        linked_account_id: "user_b",
        linked_account_email: "user_b@test.com",
        linked_member_id: "member_b",
        link_state: "linked",
        updated_at: Date.now()
      });
    });

    const ctxA = t.withIdentity({
      subject: "user_a",
      email: "user_a@test.com",
      name: "User A",
      pictureUrl: "http://placeholder.com",
      tokenIdentifier: "user_a",
      issuer: "http://placeholder.com",
      emailVerified: true,
      updatedAt: "2023-01-01"
    });

    const friendsBefore = await ctxA.query(api.friends.list, {});
    expect(friendsBefore.length).toBe(1);
    expect(friendsBefore[0].has_linked_account).toBe(true);
    expect(friendsBefore[0].linked_account_email).toBe("user_b@test.com");

    await t.run(async (ctx) => {
      await ctx.db.delete(userBId);
    });

    const friendsAfter = await ctxA.query(api.friends.list, {});
    expect(friendsAfter.length).toBe(1);
    expect(friendsAfter[0].has_linked_account).toBe(false);
    expect(friendsAfter[0].linked_account_email).toBeUndefined();
    expect(friendsAfter[0].linked_account_id).toBeUndefined();
    expect(friendsAfter[0].linked_member_id).toBeUndefined();
  });

  test("friends.list validates linked_member_id when linked_account_email is missing", async () => {
    const t = convexTest(schema, modules);
    await markCleanupEmailMaterializationReady(t);

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "user_a",
        email: "user_a@test.com",
        display_name: "User A",
        created_at: Date.now(),
        member_id: "member_a"
      });
    });

    const userBId = await t.run(async (ctx) => {
      return await ctx.db.insert("accounts", {
        id: "user_b",
        email: "user_b@test.com",
        display_name: "User B",
        created_at: Date.now(),
        member_id: "member_b"
      });
    });

    await t.run(async (ctx) => {
      await ctx.db.insert("account_friends", {
        account_email: "user_a@test.com",
        member_id: "friend_member_b",
        name: "User B (imported)",
        profile_avatar_color: "#FF0000",
        has_linked_account: true,
        linked_account_id: "user_b",
        linked_member_id: "member_b",
        link_state: "linked",
        updated_at: Date.now()
      });
    });

    const ctxA = t.withIdentity({
      subject: "user_a",
      email: "user_a@test.com",
      name: "User A",
      pictureUrl: "http://placeholder.com",
      tokenIdentifier: "user_a",
      issuer: "http://placeholder.com",
      emailVerified: true,
      updatedAt: "2023-01-01"
    });

    const friendsBefore = await ctxA.query(api.friends.list, {});
    expect(friendsBefore.length).toBe(1);
    expect(friendsBefore[0].has_linked_account).toBe(true);

    await t.run(async (ctx) => {
      await ctx.db.delete(userBId);
    });

    const friendsAfter = await ctxA.query(api.friends.list, {});
    expect(friendsAfter.length).toBe(1);
    expect(friendsAfter[0].has_linked_account).toBe(false);
    expect(friendsAfter[0].linked_member_id).toBeUndefined();
  });

  test("performHardDelete removes friend records from other users lists", async () => {
    const t = convexTest(schema, modules);
    await markCleanupEmailMaterializationReady(t);

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "user_a",
        email: "user_a@test.com",
        display_name: "User A",
        created_at: Date.now(),
        member_id: "member_a"
      });
    });

    const userBId = await t.run(async (ctx) => {
      return await ctx.db.insert("accounts", {
        id: "user_b",
        email: "user_b@test.com",
        display_name: "User B",
        created_at: Date.now(),
        member_id: "member_b"
      });
    });

    await t.run(async (ctx) => {
      await ctx.db.insert("account_friends", {
        account_email: "user_a@test.com",
        member_id: "friend_b_in_a",
        name: "User B",
        profile_avatar_color: "#FF0000",
        has_linked_account: true,
        linked_account_id: "user_b",
        linked_account_email: "user_b@test.com",
        linked_member_id: "member_b",
        updated_at: Date.now()
      });
    });

    await t.run(async (ctx) => {
      await ctx.db.insert("account_friends", {
        account_email: "user_b@test.com",
        member_id: "friend_a_in_b",
        name: "User A",
        profile_avatar_color: "#00FF00",
        has_linked_account: true,
        linked_account_id: "user_a",
        linked_account_email: "user_a@test.com",
        linked_member_id: "member_a",
        updated_at: Date.now()
      });
    });

    const friendsBefore = await t.run(async (ctx) => {
      return await ctx.db.query("account_friends").collect();
    });
    expect(friendsBefore.length).toBe(2);

    process.env.ADMIN_EMAILS = "admin@test.com";
    const adminCtx = t.withIdentity(adminIdentity());
    await adminCtx.mutation(api.admin.hardDeleteUser, { email: "user_b@test.com" });
    await finishScheduled(t);

    const friendsAfter = await t.run(async (ctx) => {
      return await ctx.db.query("account_friends").collect();
    });

    expect(friendsAfter.length).toBe(0);

    const accountB = await t.run(async (ctx) => {
      return await ctx.db
        .query("accounts")
        .withIndex("by_email", (q) => q.eq("email", "user_b@test.com"))
        .unique();
    });
    expect(accountB).toBeNull();
  });

  test("admin hard delete rejects promotion after soft deletion has mutated data", async () => {
    const t = convexTest(schema, modules);
    await markCleanupEmailMaterializationReady(t);
    const accountId = await t.run(async (ctx) => {
      const insertedAccountId = await ctx.db.insert("accounts", {
        id: "user_b",
        email: "user_b@test.com",
        display_name: "User B",
        created_at: Date.now(),
        member_id: "member_b"
      });
      await ctx.db.insert("account_deletion_progress", {
        auth_subject: "user_b",
        account_id: insertedAccountId,
        account_auth_id: "user_b",
        account_email: "user_b@test.com",
        member_ids: ["member_b"],
        request_id: "user_b",
        tombstone_email: `deleted+${insertedAccountId}@payback.invalid`,
        deletion_mode: "soft",
        phase: "owned_expenses",
        friendships_unlinked: 1,
        processed_count: 12,
        started_at: Date.now(),
        updated_at: Date.now()
      });
      return insertedAccountId;
    });

    await expect(t.mutation(internal.cleanup.hardDeleteAccount, { accountId })).rejects.toThrow(
      "Soft deletion is already applying changes"
    );

    const progress = await t.run(async (ctx) =>
      ctx.db
        .query("account_deletion_progress")
        .withIndex("by_auth_subject", (q) => q.eq("auth_subject", "user_b"))
        .collect()
    );
    expect(progress).toHaveLength(1);
    expect(progress[0]?.deletion_mode).toBe("soft");
  });

  test("hard orphan cleanup removes links found only by persisted member identity", async () => {
    const t = convexTest(schema, modules);
    await markCleanupEmailMaterializationReady(t);

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "user_a",
        email: "user_a@test.com",
        display_name: "User A",
        created_at: Date.now(),
        member_id: "member_a"
      });
    });

    await t.run(async (ctx) => {
      await ctx.db.insert("account_friends", {
        account_email: "user_a@test.com",
        member_id: "orphan_friend",
        name: "Deleted User",
        profile_avatar_color: "#999999",
        has_linked_account: true,
        linked_account_email: "deleted@example.com",
        linked_member_id: "member_deleted",
        updated_at: Date.now()
      });
      await ctx.db.insert("member_aliases", {
        canonical_member_id: "member_deleted",
        alias_member_id: "member_deleted_alias",
        account_email: "external@example.com",
        created_at: 1
      });
    });
    process.env.ADMIN_EMAILS = "admin@test.com";
    await t
      .withIdentity(adminIdentity())
      .mutation(api.admin.hardDeleteUser, { email: "deleted@example.com" });
    await finishScheduled(t);

    expect(await t.run((ctx) => ctx.db.query("account_friends").collect())).toEqual([]);
    expect(await t.run((ctx) => ctx.db.query("member_aliases").collect())).toEqual([]);
  });

  test("failed precreate cleanup upgrades identity and mode before hard retry", async () => {
    const t = convexTest(schema, modules);
    await markCleanupEmailMaterializationReady(t);
    await t.run(async (ctx) => {
      await ctx.db.insert("account_friends", {
        account_email: "owner@example.com",
        member_id: "deleted_member",
        name: "Deleted",
        profile_avatar_color: "#999999",
        has_linked_account: true,
        linked_member_id: "deleted_member",
        updated_at: 1
      });
      await ctx.db.insert("orphan_cleanup_jobs", {
        email: "deleted@example.com",
        subject: "old_subject",
        member_ids: [],
        mode: "precreate",
        status: "failed",
        processed_count: 0,
        retry_count: 0,
        last_error: "temporary",
        created_at: 1,
        updated_at: 1
      });
      await enqueueOrphanCleanupJob(ctx, {
        email: "deleted@example.com",
        subject: "deleted_auth",
        memberIds: ["deleted_member"],
        mode: "hard"
      });
    });
    await finishScheduled(t);

    expect(await t.run((ctx) => ctx.db.query("account_friends").collect())).toEqual([]);
    const job = await t.run((ctx) => ctx.db.query("orphan_cleanup_jobs").unique());
    expect(job).toMatchObject({
      subject: "deleted_auth",
      member_ids: ["deleted_member"],
      mode: "hard",
      status: "complete"
    });
  });

  test("completed admin cleanup does not leak delete authority into janitor recurrence", async () => {
    const t = convexTest(schema, modules);
    await markCleanupEmailMaterializationReady(t);
    await t.run(async (ctx) => {
      await ctx.db.insert("orphan_cleanup_jobs", {
        email: "legacy@example.com",
        subject: "legacy_auth",
        member_ids: [],
        mode: "hard",
        allow_live_account_hard_delete: true,
        status: "complete",
        processed_count: 1,
        retry_count: 2,
        account_scan_complete: true,
        orphan_scan_phase: "complete",
        member_scan_complete: true,
        created_at: 1,
        updated_at: 1
      });
      await enqueueOrphanCleanupJob(ctx, {
        email: "legacy@example.com",
        mode: "hard"
      });
    });

    const job = await t.run((ctx) => ctx.db.query("orphan_cleanup_jobs").unique());
    expect(job).toMatchObject({
      status: "pending",
      retry_count: 0,
      allow_live_account_hard_delete: false
    });
  });

  test("hard orphan cleanup processes member identities beyond one transaction's safety cap", async () => {
    const t = convexTest(schema, modules);
    await markCleanupEmailMaterializationReady(t);
    const memberIds = Array.from({ length: 129 }, (_, index) => `deleted_member_${index}`);
    await t.run(async (ctx) => {
      await ctx.db.insert("account_friends", {
        account_email: "owner@example.com",
        member_id: "deleted_friend",
        name: "Deleted",
        profile_avatar_color: "#999999",
        has_linked_account: true,
        linked_member_id: memberIds[128],
        updated_at: 1
      });
      await ctx.db.insert("member_aliases", {
        canonical_member_id: memberIds[128],
        alias_member_id: "last_alias",
        account_email: "external@example.com",
        created_at: 1
      });
      await enqueueOrphanCleanupJob(ctx, {
        email: "deleted@example.com",
        subject: "deleted_auth",
        memberIds,
        mode: "hard"
      });
    });
    await (
      t.finishAllScheduledFunctions as (
        advanceTimers: () => void,
        maxIterations: number
      ) => Promise<void>
    )(vi.runAllTimers, 1_000);

    expect(await t.run((ctx) => ctx.db.query("account_friends").collect())).toEqual([]);
    expect(await t.run((ctx) => ctx.db.query("member_aliases").collect())).toEqual([]);
    expect(await t.run((ctx) => ctx.db.query("orphan_cleanup_member_fences").collect())).toEqual(
      []
    );
    expect(await t.run((ctx) => ctx.db.query("orphan_cleanup_jobs").unique())).toMatchObject({
      status: "complete"
    });
  }, 120_000);

  test("admin hard delete resolves a mixed-case legacy account before cleanup", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
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
        member_id: "legacy_friend",
        name: "Legacy",
        profile_avatar_color: "#999999",
        has_linked_account: true,
        linked_account_email: "Legacy@Example.com",
        updated_at: 1
      });
      await ctx.db.insert("account_friends", {
        account_email: "Legacy@Example.com",
        member_id: "owned_friend",
        name: "Owned Friend",
        profile_avatar_color: "#999999",
        has_linked_account: false,
        updated_at: 1
      });
    });
    process.env.ADMIN_EMAILS = "admin@test.com";
    await t
      .withIdentity(adminIdentity())
      .mutation(api.admin.hardDeleteUser, { email: "legacy@example.com" });
    await finishScheduled(t);

    const accounts = await t.run((ctx) => ctx.db.query("accounts").collect());
    expect(accounts).toHaveLength(1);
    expect(accounts[0]?.id).toBe("owner_auth");
    expect(await t.run((ctx) => ctx.db.query("account_friends").collect())).toEqual([]);
  });

  test("admin hard purge removes an account retained by completed soft deletion", async () => {
    const t = convexTest(schema, modules);
    await markCleanupEmailMaterializationReady(t);
    const accountId = await t.run(async (ctx) => {
      const retainedId = await ctx.db.insert("accounts", {
        id: "soft_deleted_auth",
        email: "deleted+soft@payback.invalid",
        normalized_email: "deleted+soft@payback.invalid",
        display_name: "Deleted User",
        member_id: "soft_deleted_member",
        status: "deleted",
        deleted_at: 1,
        created_at: 1
      });
      await ctx.db.insert("account_deletion_receipts", {
        auth_subject: "soft_deleted_auth",
        account_id: retainedId,
        account_email: "Soft@Example.com",
        normalized_account_email: "soft@example.com",
        request_id: "soft_deleted_auth",
        deleted_at: 1,
        friendships_unlinked: 1,
        expenses_preserved: true
      });
      return retainedId;
    });

    process.env.ADMIN_EMAILS = "admin@test.com";
    await t
      .withIdentity(adminIdentity())
      .mutation(api.admin.hardDeleteUser, { email: "soft@example.com" });
    await finishScheduled(t);

    expect(await t.run((ctx) => ctx.db.get(accountId))).toBeNull();
    expect(await t.run((ctx) => ctx.db.query("account_deletion_receipts").collect())).toHaveLength(
      1
    );
  });

  test("hard deletion persists terminal worker failure after bounded retries", async () => {
    const t = convexTest(schema, modules);
    await markCleanupEmailMaterializationReady(t);
    const progressId = await t.run(async (ctx) => {
      const accountId = await ctx.db.insert("accounts", {
        id: "failing_auth",
        email: "failing@example.com",
        display_name: "Failing",
        member_id: "failing_member",
        created_at: 1
      });
      return await ctx.db.insert("account_deletion_progress", {
        auth_subject: "failing_auth",
        account_id: accountId,
        account_auth_id: "failing_auth",
        account_email: "failing@example.com",
        member_ids: ["failing_member"],
        request_id: "admin:failing",
        tombstone_email: "deleted+failing@payback.invalid",
        deletion_mode: "hard",
        hard_delete_status: "pending",
        hard_delete_retry_count: 0,
        phase: "activate_deletion_fence",
        fence_activated: true,
        friendships_unlinked: 0,
        processed_count: 0,
        started_at: 1,
        updated_at: 1
      });
    });

    await t.action(internal.cleanup.advanceHardDeleteAccount, { progressId });
    await finishScheduled(t);
    expect(await t.run((ctx) => ctx.db.get(progressId))).toMatchObject({
      hard_delete_status: "failed",
      hard_delete_retry_count: 3
    });
  });

  test("hard deletion rejects stale progress bound to the same auth subject", async () => {
    const t = convexTest(schema, modules);
    await markCleanupEmailMaterializationReady(t);
    const accountId = await t.run(async (ctx) => {
      const targetId = await ctx.db.insert("accounts", {
        id: "target_auth",
        email: "target@example.com",
        display_name: "Target",
        member_id: "target_member",
        created_at: 1
      });
      const staleId = await ctx.db.insert("accounts", {
        id: "stale_auth",
        email: "stale@example.com",
        display_name: "Stale",
        member_id: "stale_member",
        created_at: 1
      });
      await ctx.db.insert("account_deletion_progress", {
        auth_subject: "target_auth",
        account_id: staleId,
        account_auth_id: "stale_auth",
        account_email: "stale@example.com",
        member_ids: ["stale_member"],
        request_id: "stale",
        tombstone_email: "deleted+stale@payback.invalid",
        deletion_mode: "hard",
        phase: "preflight_groups_owner_id",
        fence_activated: false,
        friendships_unlinked: 0,
        processed_count: 0,
        started_at: 1,
        updated_at: 1
      });
      return targetId;
    });

    await expect(t.mutation(internal.cleanup.hardDeleteAccount, { accountId })).rejects.toThrow(
      "does not match the account identity"
    );
  });

  test("no ghost duplicates after hard delete - friend record is fully removed", async () => {
    const t = convexTest(schema, modules);
    await markCleanupEmailMaterializationReady(t);

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "user_a",
        email: "user_a@test.com",
        display_name: "User A",
        created_at: Date.now(),
        member_id: "member_a"
      });

      await ctx.db.insert("accounts", {
        id: "user_b",
        email: "user_b@test.com",
        display_name: "User B",
        created_at: Date.now(),
        member_id: "member_b"
      });

      await ctx.db.insert("account_friends", {
        account_email: "user_a@test.com",
        member_id: "friend_b",
        name: "User B",
        profile_avatar_color: "#FF0000",
        has_linked_account: true,
        linked_account_id: "user_b",
        linked_account_email: "user_b@test.com",
        updated_at: Date.now()
      });
    });

    process.env.ADMIN_EMAILS = "admin@test.com";
    const adminCtx = t.withIdentity(adminIdentity());
    await adminCtx.mutation(api.admin.hardDeleteUser, { email: "user_b@test.com" });
    await finishScheduled(t);

    const allFriends = await t.run(async (ctx) => {
      return await ctx.db.query("account_friends").collect();
    });

    expect(allFriends.length).toBe(0);

    const ghostLinked = allFriends.filter((f) => f.linked_account_email === "user_b@test.com");
    const ghostUnlinked = allFriends.filter((f) => f.name === "User B" && !f.has_linked_account);

    expect(ghostLinked.length).toBe(0);
    expect(ghostUnlinked.length).toBe(0);
  });
});
