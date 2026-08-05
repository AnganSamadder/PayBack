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

async function withReadyIdentity(t: any, email: string, subject: string) {
  await t.run(async (ctx) => {
    const existing = await ctx.db
      .query("identity_materialization_state")
      .withIndex("by_key", (q) => q.eq("key", "member_identity_v3"))
      .unique();
    if (!existing) {
      await ctx.db.insert("identity_materialization_state", {
        key: "member_identity_v3",
        status: "ready",
        phase: "complete",
        updated_at: Date.now()
      });
    }
  });
  return t.withIdentity(identity(email, subject));
}

async function insertBoundInvite(
  ctx: any,
  token: {
    id: string;
    creator_id: string;
    creator_email: string;
    target_member_id: string;
    target_member_name: string;
    created_at: number;
    expires_at: number;
  }
) {
  const targetFriendId = await ctx.db.insert("account_friends", {
    account_email: token.creator_email,
    member_id: token.target_member_id,
    name: token.target_member_name,
    profile_avatar_color: "#654321",
    has_linked_account: false,
    link_state: "unlinked",
    status: "friend",
    updated_at: token.created_at
  });

  return await ctx.db.insert("invite_tokens", {
    ...token,
    target_friend_id: targetFriendId
  });
}

describe("inviteTokens.claim mergeLocalFriendMemberId", () => {
  test("accepts a claimed-token alias whose audit email is the creator", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "creator_auth",
        email: "creator@test.com",
        display_name: "Creator",
        created_at: now,
        member_id: "creator_member"
      });
      await ctx.db.insert("accounts", {
        id: "claimer_auth",
        email: "claimer@test.com",
        display_name: "Claimer",
        created_at: now,
        member_id: "claimer_member"
      });
      await insertBoundInvite(ctx, {
        id: "historical_claim_fixture",
        creator_id: "creator_auth",
        creator_email: "creator@test.com",
        target_member_id: "claimer_legacy_member",
        target_member_name: "Claimer",
        created_at: now,
        expires_at: now + 60_000
      });
      await ctx.db.insert("member_aliases", {
        alias_member_id: "claimer_legacy_member",
        canonical_member_id: "claimer_member",
        account_email: "creator@test.com",
        created_at: now - 1
      });
    });

    const claimerCtx = await withReadyIdentity(t, "claimer@test.com", "claimer_auth");
    await expect(
      claimerCtx.mutation(api.inviteTokens.claim, { id: "historical_claim_fixture" })
    ).resolves.toMatchObject({ canonical_member_id: "claimer_member" });

    const historicalAlias = await t.run(async (ctx) =>
      ctx.db
        .query("member_aliases")
        .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", "claimer_legacy_member"))
        .first()
    );
    expect(historicalAlias?.account_email).toBe("creator@test.com");
  });

  test("preserves a standalone merge alias during an unrelated invite claim", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "creator_auth",
        email: "creator@test.com",
        display_name: "Creator",
        created_at: now,
        member_id: "creator_member"
      });
      await ctx.db.insert("accounts", {
        id: "claimer_auth",
        email: "claimer@test.com",
        display_name: "Claimer",
        created_at: now,
        member_id: "claimer_member"
      });
      await ctx.db.insert("identity_materialization_state", {
        key: "member_identity_v3",
        status: "ready",
        phase: "complete",
        updated_at: now
      });
      await insertBoundInvite(ctx, {
        id: "unrelated_claim",
        creator_id: "creator_auth",
        creator_email: "creator@test.com",
        target_member_id: "claimer_invite_alias",
        target_member_name: "Claimer",
        created_at: now,
        expires_at: now + 60_000
      });
      await ctx.db.insert("member_aliases", {
        alias_member_id: "standalone_alias",
        canonical_member_id: "claimer_member",
        account_email: "claimer@test.com",
        created_at: now
      });
    });

    const claimerCtx = await withReadyIdentity(t, "claimer@test.com", "claimer_auth");
    await claimerCtx.mutation(api.inviteTokens.claim, { id: "unrelated_claim" });

    const standaloneAlias = await t.run(async (ctx) =>
      ctx.db
        .query("member_aliases")
        .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", "standalone_alias"))
        .first()
    );
    expect(standaloneAlias).toMatchObject({
      canonical_member_id: "claimer_member",
      account_email: "claimer@test.com"
    });
  });

  test("fails safely instead of scanning an 8,192-alias live account", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();
    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "creator_auth",
        email: "creator@test.com",
        display_name: "Creator",
        created_at: now,
        member_id: "creator_member"
      });
      await ctx.db.insert("accounts", {
        id: "large_claimer_auth",
        email: "large-claimer@test.com",
        display_name: "Large Claimer",
        created_at: now,
        member_id: "large_claimer_member",
        alias_member_ids: Array.from({ length: 8192 }, (_, index) => `legacy_${index}`)
      });
      await insertBoundInvite(ctx, {
        id: "large_live_claim",
        creator_id: "creator_auth",
        creator_email: "creator@test.com",
        target_member_id: "new_alias",
        target_member_name: "Large Claimer",
        created_at: now,
        expires_at: now + 60_000
      });
    });

    const claimerCtx = await withReadyIdentity(t, "large-claimer@test.com", "large_claimer_auth");
    await expect(
      claimerCtx.mutation(api.inviteTokens.claim, { id: "large_live_claim" })
    ).rejects.toThrow("Identity maintenance required");
  });

  test("accepts a verified local selection that already uses the creator canonical ID", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "creator_auth",
        email: "creator@test.com",
        display_name: "Creator",
        created_at: now,
        member_id: "creator_member"
      });
      await ctx.db.insert("accounts", {
        id: "claimer_auth",
        email: "claimer@test.com",
        display_name: "Claimer",
        created_at: now,
        member_id: "claimer_member",
        alias_member_ids: ["preexisting_claimer_alias"]
      });
      await ctx.db.insert("member_aliases", {
        alias_member_id: "preexisting_claimer_alias",
        canonical_member_id: "claimer_member",
        account_email: "claimer@test.com",
        materialization_source: "account_alias",
        source_account_id: "claimer_auth",
        created_at: now
      });
      await insertBoundInvite(ctx, {
        id: "invite_same_id",
        creator_id: "creator_auth",
        creator_email: "creator@test.com",
        target_member_id: "claimer_legacy_member",
        target_member_name: "Claimer",
        created_at: now,
        expires_at: now + 60_000
      });
      await ctx.db.insert("account_friends", {
        account_email: "claimer@test.com",
        member_id: "creator_member",
        name: "Creator Local",
        profile_avatar_color: "#111111",
        has_linked_account: false,
        status: "friend",
        link_state: "unlinked",
        updated_at: now
      });
    });

    const claimerCtx = await withReadyIdentity(t, "claimer@test.com", "claimer_auth");
    await expect(
      claimerCtx.mutation(api.inviteTokens.claim, {
        id: "invite_same_id",
        mergeLocalFriendMemberId: "creator_member"
      })
    ).resolves.toMatchObject({ canonical_member_id: "claimer_member" });

    const claimedTarget = await t.run(async (ctx) =>
      ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", "claimer@test.com").eq("member_id", "creator_member")
        )
        .unique()
    );
    expect(claimedTarget).toMatchObject({
      has_linked_account: true,
      linked_account_id: "creator_auth",
      linked_member_id: "creator_member",
      link_state: "linked",
      status: "friend"
    });

    const claimantAliases = await t.run(async (ctx) =>
      ctx.db
        .query("member_aliases")
        .withIndex("by_account_email", (q) => q.eq("account_email", "claimer@test.com"))
        .collect()
    );
    expect(claimantAliases.map((alias) => alias.alias_member_id).sort()).toEqual([
      "claimer_legacy_member",
      "preexisting_claimer_alias"
    ]);
  });

  test("normalizes a legacy pending target before merging a separate local friend", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "creator_auth",
        email: "creator@test.com",
        display_name: "Creator",
        created_at: now,
        member_id: "creator_member"
      });
      await ctx.db.insert("accounts", {
        id: "claimer_auth",
        email: "claimer@test.com",
        display_name: "Claimer",
        created_at: now,
        member_id: "claimer_member"
      });
      await insertBoundInvite(ctx, {
        id: "invite_pending_target",
        creator_id: "creator_auth",
        creator_email: "creator@test.com",
        target_member_id: "claimer_legacy_member",
        target_member_name: "Claimer",
        created_at: now,
        expires_at: now + 60_000
      });
      await ctx.db.insert("account_friends", {
        account_email: "claimer@test.com",
        member_id: "creator_member",
        name: "Creator Pending",
        profile_avatar_color: "#111111",
        has_linked_account: false,
        status: "pending",
        link_state: "unlinked",
        updated_at: now
      });
      await ctx.db.insert("account_friends", {
        account_email: "claimer@test.com",
        member_id: "local_duplicate",
        name: "Creator Duplicate",
        profile_avatar_color: "#222222",
        has_linked_account: false,
        status: "friend",
        link_state: "unlinked",
        updated_at: now
      });
    });

    const claimerCtx = await withReadyIdentity(t, "claimer@test.com", "claimer_auth");
    await expect(
      claimerCtx.mutation(api.inviteTokens.claim, {
        id: "invite_pending_target",
        mergeLocalFriendMemberId: "local_duplicate"
      })
    ).resolves.toMatchObject({ canonical_member_id: "claimer_member" });

    const claimedTarget = await t.run(async (ctx) =>
      ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", "claimer@test.com").eq("member_id", "creator_member")
        )
        .unique()
    );
    expect(claimedTarget).toMatchObject({
      has_linked_account: true,
      link_state: "linked",
      status: "friend",
      local_alias_member_ids: ["local_duplicate"]
    });
  });

  test("merges a selected local unlinked friend into the creator canonical identity", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();

    await t.run(async (ctx) => {
      const creatorDoc = await ctx.db.insert("accounts", {
        id: "creator_auth",
        email: "creator@test.com",
        display_name: "Charlie Creator",
        created_at: now,
        member_id: "creator_member"
      });
      const claimerDoc = await ctx.db.insert("accounts", {
        id: "claimer_auth",
        email: "claimer@test.com",
        display_name: "Claimer",
        created_at: now,
        member_id: "claimer_member"
      });
      await ctx.db.insert("accounts", {
        id: "observer_auth",
        email: "observer@test.com",
        display_name: "Observer",
        created_at: now,
        member_id: "observer_member"
      });
      await ctx.db.insert("accounts", {
        id: "stale_auth",
        email: "stale@test.com",
        display_name: "Stale Link",
        created_at: now,
        member_id: "stale_member"
      });
      await ctx.db.insert("accounts", {
        id: "stale_creator_auth",
        email: "stale-creator@test.com",
        display_name: "Stale Creator Link",
        created_at: now,
        member_id: "stale_creator_member"
      });
      await ctx.db.insert("accounts", {
        id: "stale_owner_auth",
        email: "stale-owner@test.com",
        display_name: "Stale Owner Link",
        created_at: now,
        member_id: "stale_owner_member"
      });

      await insertBoundInvite(ctx, {
        id: "invite_token_1",
        creator_id: "creator_auth",
        creator_email: "creator@test.com",
        target_member_id: "claimer_legacy_member",
        target_member_name: "Claimer",
        created_at: now,
        expires_at: now + 60_000
      });

      await ctx.db.insert("account_friends", {
        account_email: "claimer@test.com",
        member_id: "local_ghost_member",
        name: "Chuck",
        profile_avatar_color: "#123456",
        has_linked_account: false,
        updated_at: now
      });

      const groupDoc = await ctx.db.insert("groups", {
        id: "local_group",
        name: "Claimer Group",
        members: [
          { id: "claimer_member", name: "Claimer", is_current_user: true },
          { id: "local_ghost_member", name: "Chuck" },
          { id: "creator_member", name: "Charlie Creator" }
        ],
        owner_email: "claimer@test.com",
        owner_account_id: "claimer_auth",
        owner_id: claimerDoc,
        created_at: now,
        updated_at: now,
        is_direct: false
      });

      await ctx.db.insert("expenses", {
        id: "expense_local_ghost",
        group_id: "local_group",
        group_ref: groupDoc,
        description: "Dinner",
        date: now,
        total_amount: 40,
        paid_by_member_id: "local_ghost_member",
        involved_member_ids: ["claimer_member", "local_ghost_member"],
        splits: [
          { id: "split_1", member_id: "claimer_member", amount: 20, is_settled: false },
          { id: "split_2", member_id: "local_ghost_member", amount: 20, is_settled: false }
        ],
        is_settled: false,
        owner_email: "stale-owner@test.com",
        owner_account_id: "claimer_auth",
        owner_id: claimerDoc,
        participant_member_ids: [
          "claimer_member",
          "local_ghost_member",
          "creator_member",
          "observer_member"
        ],
        participant_emails: [
          "claimer@test.com",
          "observer@test.com",
          "stale@test.com",
          "stale-creator@test.com",
          "stale-owner@test.com"
        ],
        participants: [
          { member_id: "claimer_member", name: "Claimer" },
          {
            member_id: "local_ghost_member",
            name: "Chuck",
            linked_account_id: "stale_auth"
          },
          {
            member_id: "creator_member",
            name: "Charlie Creator",
            linked_account_id: "stale_creator_auth",
            linked_account_email: "stale-creator@test.com"
          },
          {
            member_id: "observer_member",
            name: "Observer",
            linked_account_id: "observer_auth",
            linked_account_email: "observer@test.com"
          }
        ],
        created_at: now,
        updated_at: now
      });

      await ctx.db.insert("user_expenses", {
        user_id: "claimer_auth",
        expense_id: "expense_local_ghost",
        updated_at: now
      });
      await ctx.db.insert("user_expenses", {
        user_id: "observer_auth",
        expense_id: "expense_local_ghost",
        updated_at: now
      });
      await ctx.db.insert("user_expenses", {
        user_id: "stale_auth",
        expense_id: "expense_local_ghost",
        updated_at: now
      });
      await ctx.db.insert("user_expenses", {
        user_id: "stale_creator_auth",
        expense_id: "expense_local_ghost",
        updated_at: now
      });
      await ctx.db.insert("user_expenses", {
        user_id: "stale_owner_auth",
        expense_id: "expense_local_ghost",
        updated_at: now
      });

      expect(creatorDoc).toBeDefined();
    });

    const claimerCtx = await withReadyIdentity(t, "claimer@test.com", "claimer_auth");

    const result = await claimerCtx.mutation(api.inviteTokens.claim, {
      id: "invite_token_1",
      mergeLocalFriendMemberId: "local_ghost_member"
    });

    expect(result.canonical_member_id).toBe("claimer_member");

    const aliases = await t.run(async (ctx) => ctx.db.query("member_aliases").collect());
    expect(
      aliases.find(
        (alias) =>
          alias.alias_member_id === "claimer_legacy_member" &&
          alias.canonical_member_id === "claimer_member"
      )
    ).toBeDefined();
    expect(aliases.find((alias) => alias.alias_member_id === "local_ghost_member")).toBeUndefined();

    const claimedFriend = await t.run(async (ctx) =>
      ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", "claimer@test.com").eq("member_id", "creator_member")
        )
        .unique()
    );
    expect(claimedFriend?.has_linked_account).toBe(true);
    expect(claimedFriend?.linked_account_id).toBe("creator_auth");
    expect(claimedFriend?.local_alias_member_ids).toContain("local_ghost_member");

    const group = await t.run(async (ctx) =>
      ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", "local_group"))
        .unique()
    );
    expect(group?.members.map((member) => member.id)).toContain("creator_member");
    expect(group?.members.map((member) => member.id)).not.toContain("local_ghost_member");

    const expense = await t.run(async (ctx) =>
      ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", "expense_local_ghost"))
        .unique()
    );
    expect(expense?.paid_by_member_id).toBe("creator_member");
    expect(expense?.participant_member_ids).toContain("creator_member");
    expect(expense?.participant_member_ids).not.toContain("local_ghost_member");
    expect(expense?.participant_emails).toContain("creator@test.com");
    expect(expense?.participant_emails).not.toContain("stale@test.com");
    expect(expense?.participant_emails).not.toContain("stale-creator@test.com");
    expect(expense?.participant_emails).not.toContain("stale-owner@test.com");
    expect(expense?.splits.some((split) => split.member_id === "local_ghost_member")).toBe(false);

    const visibility = await t.run(async (ctx) =>
      ctx.db
        .query("user_expenses")
        .withIndex("by_expense_id", (q) => q.eq("expense_id", "expense_local_ghost"))
        .collect()
    );
    expect(visibility.map((row) => row.user_id).sort()).toEqual([
      "claimer_auth",
      "creator_auth",
      "observer_auth"
    ]);

    const retryResult = await claimerCtx.mutation(api.inviteTokens.claim, {
      id: "invite_token_1",
      mergeLocalFriendMemberId: "local_ghost_member"
    });
    expect(retryResult.canonical_member_id).toBe("claimer_member");

    await t.run(async (ctx) => {
      const token = await ctx.db
        .query("invite_tokens")
        .withIndex("by_client_id", (q) => q.eq("id", "invite_token_1"))
        .unique();
      if (token) {
        await ctx.db.patch(token._id, { expires_at: Date.now() - 1 });
      }
      await ctx.db.insert("account_friends", {
        account_email: "claimer@test.com",
        member_id: "different_local_friend",
        name: "Different Friend",
        profile_avatar_color: "#999999",
        has_linked_account: false,
        updated_at: Date.now()
      });
    });

    const expiredRetry = await claimerCtx.mutation(api.inviteTokens.claim, {
      id: "invite_token_1",
      mergeLocalFriendMemberId: "local_ghost_member"
    });
    expect(expiredRetry.canonical_member_id).toBe("claimer_member");

    await expect(
      claimerCtx.mutation(api.inviteTokens.claim, {
        id: "invite_token_1",
        mergeLocalFriendMemberId: "different_local_friend"
      })
    ).rejects.toThrow("different merge selection");
  });

  test("grants visibility when the merged friend is referenced only as payer", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "creator_auth",
        email: "creator@test.com",
        display_name: "Creator",
        created_at: now,
        member_id: "creator_member"
      });
      const claimerDoc = await ctx.db.insert("accounts", {
        id: "claimer_auth",
        email: "claimer@test.com",
        display_name: "Claimer",
        created_at: now,
        member_id: "claimer_member"
      });
      await insertBoundInvite(ctx, {
        id: "invite_payer_only",
        creator_id: "creator_auth",
        creator_email: "creator@test.com",
        target_member_id: "claimer_legacy_member",
        target_member_name: "Claimer",
        created_at: now,
        expires_at: now + 60_000
      });
      await ctx.db.insert("account_friends", {
        account_email: "claimer@test.com",
        member_id: "payer_only_duplicate",
        name: "Creator Duplicate",
        profile_avatar_color: "#444444",
        has_linked_account: false,
        status: "friend",
        link_state: "unlinked",
        updated_at: now
      });
      const groupDoc = await ctx.db.insert("groups", {
        id: "payer_only_group",
        name: "Payer-only Group",
        members: [
          { id: "claimer_member", name: "Claimer", is_current_user: true },
          { id: "payer_only_duplicate", name: "Creator Duplicate" }
        ],
        owner_email: "claimer@test.com",
        owner_account_id: "claimer_auth",
        owner_id: claimerDoc,
        created_at: now,
        updated_at: now,
        is_direct: false
      });
      await ctx.db.insert("expenses", {
        id: "payer_only_expense",
        group_id: "payer_only_group",
        group_ref: groupDoc,
        description: "Legacy payer-only expense",
        date: now,
        total_amount: 10,
        paid_by_member_id: "payer_only_duplicate",
        involved_member_ids: ["claimer_member"],
        splits: [
          { id: "claimer_split", member_id: "claimer_member", amount: 10, is_settled: false }
        ],
        is_settled: false,
        owner_email: "claimer@test.com",
        owner_account_id: "claimer_auth",
        owner_id: claimerDoc,
        participant_member_ids: ["claimer_member"],
        participant_emails: ["claimer@test.com"],
        participants: [{ member_id: "claimer_member", name: "Claimer" }],
        created_at: now,
        updated_at: now
      });
      await ctx.db.insert("user_expenses", {
        user_id: "claimer_auth",
        expense_id: "payer_only_expense",
        updated_at: now
      });
    });

    const claimerCtx = await withReadyIdentity(t, "claimer@test.com", "claimer_auth");
    await claimerCtx.mutation(api.inviteTokens.claim, {
      id: "invite_payer_only",
      mergeLocalFriendMemberId: "payer_only_duplicate"
    });

    const state = await t.run(async (ctx) => ({
      expense: await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", "payer_only_expense"))
        .unique(),
      visibility: await ctx.db
        .query("user_expenses")
        .withIndex("by_expense_id", (q) => q.eq("expense_id", "payer_only_expense"))
        .collect()
    }));
    expect(state.expense?.paid_by_member_id).toBe("creator_member");
    expect(state.expense?.participant_emails).toContain("creator@test.com");
    expect(state.visibility.map((row) => row.user_id).sort()).toEqual([
      "claimer_auth",
      "creator_auth"
    ]);
  });

  test("rejects mergeLocalFriendMemberId when the friend is not owned by the claimer", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "creator_auth",
        email: "creator@test.com",
        display_name: "Creator",
        created_at: now,
        member_id: "creator_member"
      });
      await ctx.db.insert("accounts", {
        id: "claimer_auth",
        email: "claimer@test.com",
        display_name: "Claimer",
        created_at: now,
        member_id: "claimer_member"
      });
      await insertBoundInvite(ctx, {
        id: "invite_token_not_owned",
        creator_id: "creator_auth",
        creator_email: "creator@test.com",
        target_member_id: "claimer_legacy_member",
        target_member_name: "Claimer",
        created_at: now,
        expires_at: now + 60_000
      });
      await ctx.db.insert("account_friends", {
        account_email: "other@test.com",
        member_id: "someone_else_friend",
        name: "Not Yours",
        profile_avatar_color: "#999999",
        has_linked_account: false,
        updated_at: now
      });
    });

    const claimerCtx = await withReadyIdentity(t, "claimer@test.com", "claimer_auth");

    await expect(
      claimerCtx.mutation(api.inviteTokens.claim, {
        id: "invite_token_not_owned",
        mergeLocalFriendMemberId: "someone_else_friend"
      })
    ).rejects.toThrow("not found");

    const token = await t.run(async (ctx) =>
      ctx.db
        .query("invite_tokens")
        .withIndex("by_client_id", (q) => q.eq("id", "invite_token_not_owned"))
        .unique()
    );
    expect(token?.claimed_by).toBeUndefined();
  });

  test("rejects mergeLocalFriendMemberId when the selected friend is already linked", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "creator_auth",
        email: "creator@test.com",
        display_name: "Creator",
        created_at: now,
        member_id: "creator_member"
      });
      await ctx.db.insert("accounts", {
        id: "claimer_auth",
        email: "claimer@test.com",
        display_name: "Claimer",
        created_at: now,
        member_id: "claimer_member"
      });
      await insertBoundInvite(ctx, {
        id: "invite_token_linked_friend",
        creator_id: "creator_auth",
        creator_email: "creator@test.com",
        target_member_id: "claimer_legacy_member",
        target_member_name: "Claimer",
        created_at: now,
        expires_at: now + 60_000
      });
      await ctx.db.insert("account_friends", {
        account_email: "claimer@test.com",
        member_id: "already_linked_friend",
        name: "Linked Friend",
        profile_avatar_color: "#444444",
        has_linked_account: true,
        linked_account_id: "linked_account",
        linked_account_email: "linked@test.com",
        linked_member_id: "linked_member",
        updated_at: now
      });
    });

    const claimerCtx = await withReadyIdentity(t, "claimer@test.com", "claimer_auth");

    await expect(
      claimerCtx.mutation(api.inviteTokens.claim, {
        id: "invite_token_linked_friend",
        mergeLocalFriendMemberId: "already_linked_friend"
      })
    ).rejects.toThrow("not an unlinked friend");

    const aliases = await t.run(async (ctx) => ctx.db.query("member_aliases").collect());
    expect(
      aliases.find((alias) => alias.alias_member_id === "already_linked_friend")
    ).toBeUndefined();
  });

  test("rejects an over-cap local alias closure without claiming the invite", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();
    const sourceAliases = Array.from({ length: 257 }, (_, index) => `source_alias_${index}`);

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "creator_auth",
        email: "creator@test.com",
        display_name: "Creator",
        created_at: now,
        member_id: "creator_member"
      });
      await ctx.db.insert("accounts", {
        id: "claimer_auth",
        email: "claimer@test.com",
        display_name: "Claimer",
        created_at: now,
        member_id: "claimer_member"
      });
      await insertBoundInvite(ctx, {
        id: "invite_over_cap_source",
        creator_id: "creator_auth",
        creator_email: "creator@test.com",
        target_member_id: "claimer_legacy_member",
        target_member_name: "Claimer",
        created_at: now,
        expires_at: now + 60_000
      });
      await ctx.db.insert("account_friends", {
        account_email: "claimer@test.com",
        member_id: "local_duplicate",
        local_alias_member_ids: sourceAliases,
        name: "Creator Duplicate",
        profile_avatar_color: "#444444",
        has_linked_account: false,
        status: "friend",
        link_state: "unlinked",
        updated_at: now
      });
    });

    const claimerCtx = await withReadyIdentity(t, "claimer@test.com", "claimer_auth");
    await expect(
      claimerCtx.mutation(api.inviteTokens.claim, {
        id: "invite_over_cap_source",
        mergeLocalFriendMemberId: "local_duplicate"
      })
    ).rejects.toThrow("Friend merge is too large to complete safely");

    const state = await t.run(async (ctx) => ({
      token: await ctx.db
        .query("invite_tokens")
        .withIndex("by_client_id", (q) => q.eq("id", "invite_over_cap_source"))
        .unique(),
      source: await ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", "claimer@test.com").eq("member_id", "local_duplicate")
        )
        .unique(),
      target: await ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", "claimer@test.com").eq("member_id", "creator_member")
        )
        .unique()
    }));
    expect(state.token?.claimed_by).toBeUndefined();
    expect(state.source?.local_alias_member_ids).toEqual(sourceAliases);
    expect(state.target).toBeNull();
  });

  test("rejects a local row whose member ID belongs to a registered account", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "creator_auth",
        email: "creator@test.com",
        display_name: "Creator",
        created_at: now,
        member_id: "creator_member"
      });
      await ctx.db.insert("accounts", {
        id: "claimer_auth",
        email: "claimer@test.com",
        display_name: "Claimer",
        created_at: now,
        member_id: "claimer_member"
      });
      await ctx.db.insert("accounts", {
        id: "registered_auth",
        email: "registered@test.com",
        display_name: "Registered",
        created_at: now,
        member_id: "registered_member"
      });
      await insertBoundInvite(ctx, {
        id: "invite_registered_source",
        creator_id: "creator_auth",
        creator_email: "creator@test.com",
        target_member_id: "claimer_legacy_member",
        target_member_name: "Claimer",
        created_at: now,
        expires_at: now + 60_000
      });
      await ctx.db.insert("account_friends", {
        account_email: "claimer@test.com",
        member_id: "registered_member",
        name: "Forged Unlinked Row",
        profile_avatar_color: "#444444",
        has_linked_account: false,
        updated_at: now
      });
    });

    const claimerCtx = await withReadyIdentity(t, "claimer@test.com", "claimer_auth");
    await expect(
      claimerCtx.mutation(api.inviteTokens.claim, {
        id: "invite_registered_source",
        mergeLocalFriendMemberId: "registered_member"
      })
    ).rejects.toThrow("registered account");
  });

  test("rejects an invite merge source materialized from an account alias", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "creator_auth",
        email: "creator@test.com",
        display_name: "Creator",
        created_at: now,
        member_id: "creator_member"
      });
      await ctx.db.insert("accounts", {
        id: "claimer_auth",
        email: "claimer@test.com",
        display_name: "Claimer",
        created_at: now,
        member_id: "claimer_member"
      });
      await ctx.db.insert("accounts", {
        id: "registered_auth",
        email: "registered@test.com",
        display_name: "Registered",
        created_at: now,
        member_id: "registered_member",
        alias_member_ids: ["registered_alias"]
      });
      await insertBoundInvite(ctx, {
        id: "invite_registered_alias_source",
        creator_id: "creator_auth",
        creator_email: "creator@test.com",
        target_member_id: "claimer_legacy_member",
        target_member_name: "Claimer",
        created_at: now,
        expires_at: now + 60_000
      });
      await ctx.db.insert("account_friends", {
        account_email: "claimer@test.com",
        member_id: "registered_alias",
        name: "Forged Unlinked Row",
        profile_avatar_color: "#444444",
        has_linked_account: false,
        updated_at: now
      });
    });
    for (let attempt = 0; attempt < 20; attempt += 1) {
      const result = await t.mutation(internal.migrations.runIdentityMaterializationMigration, {
        batchSize: 10
      });
      if (result.status === "ready") break;
    }

    const materializedAlias = await t.run(async (ctx) =>
      ctx.db
        .query("member_aliases")
        .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", "registered_alias"))
        .unique()
    );
    expect(materializedAlias).toMatchObject({
      canonical_member_id: "registered_member",
      account_email: "registered@test.com"
    });

    const claimerCtx = await withReadyIdentity(t, "claimer@test.com", "claimer_auth");
    await expect(
      claimerCtx.mutation(api.inviteTokens.claim, {
        id: "invite_registered_alias_source",
        mergeLocalFriendMemberId: "registered_alias"
      })
    ).rejects.toThrow("globally linked");
  });

  test("claims a zero-expense merge invite with 2,049 accounts", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "creator_auth",
        email: "creator@test.com",
        display_name: "Creator",
        created_at: now,
        member_id: "creator_member"
      });
      await ctx.db.insert("accounts", {
        id: "claimer_auth",
        email: "claimer@test.com",
        display_name: "Claimer",
        created_at: now,
        member_id: "claimer_member"
      });
      await insertBoundInvite(ctx, {
        id: "invite_large_account_table",
        creator_id: "creator_auth",
        creator_email: "creator@test.com",
        target_member_id: "claimer_legacy_member",
        target_member_name: "Claimer",
        created_at: now,
        expires_at: now + 60_000
      });
      await ctx.db.insert("account_friends", {
        account_email: "claimer@test.com",
        member_id: "local_duplicate",
        name: "Creator Duplicate",
        profile_avatar_color: "#444444",
        has_linked_account: false,
        updated_at: now
      });
    });

    for (let batchStart = 0; batchStart < 2047; batchStart += 250) {
      const batchEnd = Math.min(batchStart + 250, 2047);
      await t.run(async (ctx) => {
        for (let index = batchStart; index < batchEnd; index += 1) {
          await ctx.db.insert("accounts", {
            id: `unrelated_auth_${index}`,
            email: `unrelated-${index}@test.com`,
            display_name: `Unrelated ${index}`,
            created_at: now,
            member_id: `unrelated_member_${index}`
          });
        }
      });
    }

    const claimerCtx = await withReadyIdentity(t, "claimer@test.com", "claimer_auth");
    await expect(
      claimerCtx.mutation(api.inviteTokens.claim, {
        id: "invite_large_account_table",
        mergeLocalFriendMemberId: "local_duplicate"
      })
    ).resolves.toMatchObject({ canonical_member_id: "claimer_member" });
  });

  test("does not rewrite another owner's group that reuses the same local UUID", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();

    await t.run(async (ctx) => {
      const outsiderDoc = await ctx.db.insert("accounts", {
        id: "outsider_auth",
        email: "outsider@test.com",
        display_name: "Outsider",
        created_at: now,
        member_id: "outsider_member"
      });
      await ctx.db.insert("accounts", {
        id: "creator_auth",
        email: "creator@test.com",
        display_name: "Creator",
        created_at: now,
        member_id: "creator_member"
      });
      await ctx.db.insert("accounts", {
        id: "claimer_auth",
        email: "claimer@test.com",
        display_name: "Claimer",
        created_at: now,
        member_id: "claimer_member"
      });
      await insertBoundInvite(ctx, {
        id: "invite_owner_scope",
        creator_id: "creator_auth",
        creator_email: "creator@test.com",
        target_member_id: "claimer_legacy_member",
        target_member_name: "Claimer",
        created_at: now,
        expires_at: now + 60_000
      });
      await ctx.db.insert("account_friends", {
        account_email: "claimer@test.com",
        member_id: "shared_uuid",
        name: "Creator Local",
        profile_avatar_color: "#111111",
        has_linked_account: false,
        updated_at: now
      });
      const outsiderGroup = await ctx.db.insert("groups", {
        id: "outsider_group",
        name: "Outsider Group",
        members: [
          { id: "outsider_member", name: "Outsider", is_current_user: true },
          { id: "shared_uuid", name: "Different Person" }
        ],
        owner_email: "outsider@test.com",
        owner_account_id: "outsider_auth",
        owner_id: outsiderDoc,
        created_at: now,
        updated_at: now
      });
      await ctx.db.insert("expenses", {
        id: "outsider_expense",
        group_id: "outsider_group",
        group_ref: outsiderGroup,
        description: "Outsider dinner",
        date: now,
        total_amount: 10,
        paid_by_member_id: "shared_uuid",
        involved_member_ids: ["outsider_member", "shared_uuid"],
        splits: [
          { id: "one", member_id: "outsider_member", amount: 5, is_settled: false },
          { id: "two", member_id: "shared_uuid", amount: 5, is_settled: false }
        ],
        is_settled: false,
        owner_email: "outsider@test.com",
        owner_account_id: "outsider_auth",
        owner_id: outsiderDoc,
        participant_member_ids: ["outsider_member", "shared_uuid"],
        participant_emails: ["outsider@test.com"],
        participants: [
          { member_id: "outsider_member", name: "Outsider" },
          { member_id: "shared_uuid", name: "Different Person" }
        ],
        created_at: now,
        updated_at: now
      });
    });

    const claimerCtx = await withReadyIdentity(t, "claimer@test.com", "claimer_auth");
    await claimerCtx.mutation(api.inviteTokens.claim, {
      id: "invite_owner_scope",
      mergeLocalFriendMemberId: "shared_uuid"
    });

    const outsiderGroup = await t.run(async (ctx) =>
      ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", "outsider_group"))
        .unique()
    );
    const outsiderExpense = await t.run(async (ctx) =>
      ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", "outsider_expense"))
        .unique()
    );
    expect(outsiderGroup?.members.map((member) => member.id)).toContain("shared_uuid");
    expect(outsiderExpense?.paid_by_member_id).toBe("shared_uuid");
    expect(outsiderExpense?.participant_emails).not.toContain("creator@test.com");
  });
});
