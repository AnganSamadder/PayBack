import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api, internal } from "../_generated/api";
import { createLinkingReadBudget } from "../aliases";
import { prepareClaimForUser } from "../inviteTokens";
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

async function insertLargeRewriteSurface(
  ctx: any,
  options: {
    ownerId: any;
    ownerAuthId: string;
    ownerEmail: string;
    ownerMemberId: string;
    sourceMemberId: string;
    prefix: string;
    payloadBytes: number;
    now: number;
  }
) {
  const largePayload = "x".repeat(options.payloadBytes);
  const groupId = await ctx.db.insert("groups", {
    id: `${options.prefix}_group`,
    name: largePayload,
    members: [
      { id: options.ownerMemberId, name: "Owner", is_current_user: true },
      { id: options.sourceMemberId, name: "Merge source" }
    ],
    owner_email: options.ownerEmail,
    owner_account_id: options.ownerAuthId,
    owner_id: options.ownerId,
    created_at: options.now,
    updated_at: options.now
  });
  await ctx.db.insert("expenses", {
    id: `${options.prefix}_expense`,
    group_id: `${options.prefix}_group`,
    group_ref: groupId,
    description: "Large merge expense",
    notes: largePayload,
    date: options.now,
    total_amount: 20,
    paid_by_member_id: options.sourceMemberId,
    involved_member_ids: [options.ownerMemberId, options.sourceMemberId],
    splits: [
      {
        id: `${options.prefix}_owner_split`,
        member_id: options.ownerMemberId,
        amount: 10,
        is_settled: false
      },
      {
        id: `${options.prefix}_source_split`,
        member_id: options.sourceMemberId,
        amount: 10,
        is_settled: false
      }
    ],
    is_settled: false,
    owner_email: options.ownerEmail,
    owner_account_id: options.ownerAuthId,
    owner_id: options.ownerId,
    participant_member_ids: [options.ownerMemberId, options.sourceMemberId],
    participant_emails: [options.ownerEmail],
    participants: [
      { member_id: options.ownerMemberId, name: "Owner" },
      { member_id: options.sourceMemberId, name: "Merge source" }
    ],
    created_at: options.now,
    updated_at: options.now
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
        owner_email: "claimer@test.com",
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

  test("preflights selected-friend identity conflicts before returning an apply plan", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();
    await t.run(async (ctx) => {
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
      await ctx.db.insert("account_friends", {
        account_email: "claimer@test.com",
        member_id: "creator_member",
        name: "Creator",
        profile_avatar_color: "#111111",
        has_linked_account: false,
        updated_at: now
      });
      await ctx.db.insert("account_friends", {
        account_email: "claimer@test.com",
        member_id: "selected_duplicate",
        local_alias_member_ids: ["conflicting_alias"],
        name: "Selected duplicate",
        profile_avatar_color: "#222222",
        has_linked_account: false,
        updated_at: now
      });
      await ctx.db.insert("account_friends", {
        account_email: "claimer@test.com",
        member_id: "conflicting_alias",
        name: "Different friend",
        profile_avatar_color: "#333333",
        has_linked_account: false,
        updated_at: now
      });
    });

    const { prepareInviteMergeSourceInternal } = await import("../aliases");
    await expect(
      t.run(async (ctx) => {
        await prepareInviteMergeSourceInternal(ctx, {
          accountEmail: "claimer@test.com",
          sourceMemberId: "selected_duplicate",
          targetMemberId: "creator_member",
          targetName: "Creator",
          targetLinkedAccountId: "creator_auth",
          targetLinkedAccountEmail: "creator@test.com"
        });
        return "prepared";
      })
    ).rejects.toThrow("already attached to another friend");
  });

  test("rejects a selected merge target alias owned by another registered account", async () => {
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
        id: "foreign_auth",
        email: "foreign@test.com",
        display_name: "Foreign account",
        created_at: now,
        member_id: "foreign_member"
      });
      await insertBoundInvite(ctx, {
        id: "invite_target_foreign_alias",
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
        local_alias_member_ids: ["foreign_member"],
        name: "Creator",
        profile_avatar_color: "#111111",
        has_linked_account: false,
        updated_at: now
      });
      await ctx.db.insert("account_friends", {
        account_email: "claimer@test.com",
        member_id: "selected_creator_duplicate",
        name: "Selected creator duplicate",
        profile_avatar_color: "#222222",
        has_linked_account: false,
        updated_at: now
      });
    });

    const claimer = await withReadyIdentity(t, "claimer@test.com", "claimer_auth");
    await expect(
      claimer.mutation(api.inviteTokens.claim, {
        id: "invite_target_foreign_alias",
        mergeLocalFriendMemberId: "selected_creator_duplicate"
      })
    ).rejects.toThrow("target alias belongs to another registered account");

    const state = await t.run(async (ctx) => ({
      token: await ctx.db
        .query("invite_tokens")
        .withIndex("by_client_id", (q) => q.eq("id", "invite_target_foreign_alias"))
        .unique(),
      friends: await ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (q) => q.eq("account_email", "claimer@test.com"))
        .collect()
    }));
    expect(state.token?.claimed_by).toBeUndefined();
    expect(state.friends.map((friend) => friend.member_id).sort()).toEqual([
      "creator_member",
      "selected_creator_duplicate"
    ]);
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
  }, 30_000);

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

  test.each([
    { label: "token target", mergeMemberId: "claimer_legacy_member" },
    { label: "claimant canonical member", mergeMemberId: "claimer_member" },
    { label: "claimant account alias", mergeMemberId: "claimer_alias" }
  ])("rejects the $label as an invite merge source", async ({ mergeMemberId }) => {
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
        alias_member_ids: ["claimer_alias"]
      });
      await ctx.db.insert("member_aliases", {
        alias_member_id: "claimer_alias",
        canonical_member_id: "claimer_member",
        account_email: "claimer@test.com",
        materialization_source: "account_alias",
        source_account_id: "claimer_auth",
        created_at: now
      });
      await insertBoundInvite(ctx, {
        id: `identity_closure_${mergeMemberId}`,
        creator_id: "creator_auth",
        creator_email: "creator@test.com",
        target_member_id: "claimer_legacy_member",
        target_member_name: "Claimer",
        created_at: now,
        expires_at: now + 60_000
      });
      await ctx.db.insert("account_friends", {
        account_email: "claimer@test.com",
        member_id: mergeMemberId,
        name: "Invalid creator duplicate",
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
        id: `identity_closure_${mergeMemberId}`,
        mergeLocalFriendMemberId: mergeMemberId
      })
    ).rejects.toThrow("Cannot merge the claimant identity into the inviter");

    const token = await t.run(async (ctx) =>
      ctx.db
        .query("invite_tokens")
        .withIndex("by_client_id", (q) => q.eq("id", `identity_closure_${mergeMemberId}`))
        .unique()
    );
    expect(token?.claimed_by).toBeUndefined();
  });

  test("rejects a merge source whose local aliases intersect the claimant identity", async () => {
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
      const claimerId = await ctx.db.insert("accounts", {
        id: "claimer_auth",
        email: "claimer@test.com",
        display_name: "Claimer",
        created_at: now,
        member_id: "claimer_member"
      });
      await insertBoundInvite(ctx, {
        id: "invite_source_alias_claimant_identity",
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
        local_alias_member_ids: ["claimer_legacy_member"],
        name: "Creator duplicate",
        profile_avatar_color: "#444444",
        has_linked_account: false,
        status: "friend",
        link_state: "unlinked",
        updated_at: now
      });
      const groupId = await ctx.db.insert("groups", {
        id: "claimant_alias_group",
        name: "Claimant alias group",
        members: [
          { id: "claimer_member", name: "Claimer", is_current_user: true },
          { id: "local_duplicate", name: "Creator duplicate" }
        ],
        owner_email: "claimer@test.com",
        owner_account_id: "claimer_auth",
        owner_id: claimerId,
        created_at: now,
        updated_at: now
      });
      await ctx.db.insert("expenses", {
        id: "claimant_alias_expense",
        group_id: "claimant_alias_group",
        group_ref: groupId,
        description: "Must remain unchanged",
        date: now,
        total_amount: 20,
        paid_by_member_id: "local_duplicate",
        involved_member_ids: ["claimer_member", "local_duplicate"],
        splits: [
          { id: "claimant_split", member_id: "claimer_member", amount: 10, is_settled: false },
          {
            id: "duplicate_split",
            member_id: "local_duplicate",
            amount: 10,
            is_settled: false
          }
        ],
        is_settled: false,
        owner_email: "claimer@test.com",
        owner_account_id: "claimer_auth",
        owner_id: claimerId,
        participant_member_ids: ["claimer_member", "local_duplicate"],
        participant_emails: ["claimer@test.com"],
        participants: [
          { member_id: "claimer_member", name: "Claimer" },
          { member_id: "local_duplicate", name: "Creator duplicate" }
        ],
        created_at: now,
        updated_at: now
      });
    });

    const claimer = await withReadyIdentity(t, "claimer@test.com", "claimer_auth");
    await expect(
      claimer.mutation(api.inviteTokens.claim, {
        id: "invite_source_alias_claimant_identity",
        mergeLocalFriendMemberId: "local_duplicate"
      })
    ).rejects.toThrow("Cannot merge the claimant identity into the inviter");

    const state = await t.run(async (ctx) => ({
      token: await ctx.db
        .query("invite_tokens")
        .withIndex("by_client_id", (q) => q.eq("id", "invite_source_alias_claimant_identity"))
        .unique(),
      materializedAlias: await ctx.db
        .query("member_aliases")
        .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", "claimer_legacy_member"))
        .first(),
      group: await ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", "claimant_alias_group"))
        .unique(),
      expense: await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", "claimant_alias_expense"))
        .unique()
    }));
    expect(state.token?.claimed_by).toBeUndefined();
    expect(state.materializedAlias).toBeNull();
    expect(state.group?.members.map((member) => member.id)).toEqual([
      "claimer_member",
      "local_duplicate"
    ]);
    expect(state.expense?.paid_by_member_id).toBe("local_duplicate");
    expect(state.expense?.participant_member_ids).toEqual(["claimer_member", "local_duplicate"]);
  });

  test("rewrites the bound invite target's owner-local alias history without globalizing it", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();

    await t.run(async (ctx) => {
      const creatorId = await ctx.db.insert("accounts", {
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
        id: "invite_with_local_target_alias",
        creator_id: "creator_auth",
        creator_email: "creator@test.com",
        target_member_id: "claimer_legacy_member",
        target_member_name: "Claimer",
        created_at: now,
        expires_at: now + 60_000
      });
      const targetFriend = await ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", "creator@test.com").eq("member_id", "claimer_legacy_member")
        )
        .unique();
      if (!targetFriend) throw new Error("missing target friend");
      await ctx.db.patch(targetFriend._id, {
        local_alias_member_ids: ["claimer_local_alias"]
      });

      const groupId = await ctx.db.insert("groups", {
        id: "local_target_alias_group",
        name: "Alias history",
        members: [
          { id: "creator_member", name: "Creator", is_current_user: true },
          { id: "claimer_local_alias", name: "Claimer alias" }
        ],
        owner_email: "creator@test.com",
        owner_account_id: "creator_auth",
        owner_id: creatorId,
        created_at: now,
        updated_at: now
      });
      await ctx.db.insert("expenses", {
        id: "local_target_alias_expense",
        group_id: "local_target_alias_group",
        group_ref: groupId,
        description: "Alias-only dinner",
        date: now,
        total_amount: 20,
        paid_by_member_id: "creator_member",
        involved_member_ids: ["creator_member", "claimer_local_alias"],
        splits: [
          { id: "creator_split", member_id: "creator_member", amount: 10, is_settled: false },
          { id: "alias_split", member_id: "claimer_local_alias", amount: 10, is_settled: false }
        ],
        is_settled: false,
        owner_email: "creator@test.com",
        owner_account_id: "creator_auth",
        owner_id: creatorId,
        participant_member_ids: ["creator_member", "claimer_local_alias"],
        participant_emails: ["creator@test.com"],
        participants: [
          { member_id: "creator_member", name: "Creator" },
          { member_id: "claimer_local_alias", name: "Claimer alias" }
        ],
        created_at: now,
        updated_at: now
      });
      await ctx.db.insert("user_expenses", {
        user_id: "creator_auth",
        expense_id: "local_target_alias_expense",
        updated_at: now
      });
    });

    const claimerCtx = await withReadyIdentity(t, "claimer@test.com", "claimer_auth");
    await claimerCtx.mutation(api.inviteTokens.claim, {
      id: "invite_with_local_target_alias"
    });

    const state = await t.run(async (ctx) => ({
      group: await ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", "local_target_alias_group"))
        .unique(),
      expense: await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", "local_target_alias_expense"))
        .unique(),
      visibility: await ctx.db
        .query("user_expenses")
        .withIndex("by_expense_id", (q) => q.eq("expense_id", "local_target_alias_expense"))
        .collect(),
      localAliasMaterialization: await ctx.db
        .query("member_aliases")
        .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", "claimer_local_alias"))
        .first()
    }));
    expect(state.group?.members.map((member) => member.id)).toContain("claimer_member");
    expect(state.group?.members.map((member) => member.id)).not.toContain("claimer_local_alias");
    expect(state.expense?.participant_member_ids).toContain("claimer_member");
    expect(state.expense?.participant_member_ids).not.toContain("claimer_local_alias");
    expect(state.visibility.map((row) => row.user_id)).toEqual(
      expect.arrayContaining(["creator_auth", "claimer_auth"])
    );
    expect(state.localAliasMaterialization).toBeNull();
  });

  test("preserves a bound target's local aliases when retaining an existing canonical row", async () => {
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
        id: "invite_with_canonical_collision",
        creator_id: "creator_auth",
        creator_email: "creator@test.com",
        target_member_id: "claimer_legacy_member",
        target_member_name: "Claimer",
        created_at: now,
        expires_at: now + 60_000
      });
      const targetFriend = await ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", "creator@test.com").eq("member_id", "claimer_legacy_member")
        )
        .unique();
      if (!targetFriend) throw new Error("missing target friend");
      await ctx.db.patch(targetFriend._id, {
        local_alias_member_ids: ["claimer_local_alias"],
        nickname: "Roadtrip Claimer",
        original_name: "Imported Claimer",
        original_nickname: "Roadtrip",
        prefer_nickname: true,
        first_name: "Imported",
        last_name: "Friend",
        display_preference: "nickname",
        profile_image_url: "https://example.com/imported.png"
      });
      await ctx.db.insert("account_friends", {
        account_email: "creator@test.com",
        member_id: "claimer_member",
        local_alias_member_ids: ["canonical_local_alias"],
        name: "Existing canonical Claimer",
        profile_avatar_color: "#123456",
        has_linked_account: false,
        link_state: "unlinked",
        status: "friend",
        updated_at: now
      });
    });

    const claimerCtx = await withReadyIdentity(t, "claimer@test.com", "claimer_auth");
    await claimerCtx.mutation(api.inviteTokens.claim, {
      id: "invite_with_canonical_collision"
    });

    const creatorFriends = await t.run(async (ctx) =>
      ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (q) => q.eq("account_email", "creator@test.com"))
        .collect()
    );
    const canonicalFriend = creatorFriends.find((friend) => friend.member_id === "claimer_member");
    expect(creatorFriends.some((friend) => friend.member_id === "claimer_legacy_member")).toBe(
      false
    );
    expect(canonicalFriend?.local_alias_member_ids).toEqual(
      expect.arrayContaining(["canonical_local_alias", "claimer_local_alias"])
    );
    expect(canonicalFriend).toMatchObject({
      nickname: "Roadtrip Claimer",
      original_name: "Imported Claimer",
      original_nickname: "Roadtrip",
      prefer_nickname: true,
      first_name: "Imported",
      last_name: "Friend",
      display_preference: "nickname",
      profile_image_url: "https://example.com/imported.png"
    });
  });

  test("bounds creator and claimant fallback friend rows in the shared claim budget", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();
    const largeProfile = "x".repeat(360 * 1024);

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
        id: "invite_large_friend_fallbacks",
        creator_id: "creator_auth",
        creator_email: "creator@test.com",
        target_member_id: "claimer_legacy_member",
        target_member_name: "Claimer",
        created_at: now,
        expires_at: now + 60_000
      });
      await ctx.db.insert("account_friends", {
        account_email: "claimer@test.com",
        member_id: "creator_duplicate",
        name: "Creator duplicate",
        profile_avatar_color: "#444444",
        has_linked_account: false,
        link_state: "unlinked",
        status: "friend",
        updated_at: now
      });
      for (const accountEmail of ["creator@test.com", "claimer@test.com"]) {
        for (let index = 0; index < 12; index += 1) {
          await ctx.db.insert("account_friends", {
            account_email: accountEmail,
            member_id: `${accountEmail}_large_friend_${index}`,
            name: `Large friend ${index}`,
            profile_avatar_color: "#333333",
            profile_image_url: largeProfile,
            has_linked_account: false,
            link_state: "unlinked",
            status: "friend",
            updated_at: now
          });
        }
      }
    });

    const claimerCtx = await withReadyIdentity(t, "claimer@test.com", "claimer_auth");
    await expect(
      claimerCtx.mutation(api.inviteTokens.claim, {
        id: "invite_large_friend_fallbacks",
        mergeLocalFriendMemberId: "creator_duplicate"
      })
    ).rejects.toThrow("Friend merge is too large to complete safely");

    const token = await t.run(async (ctx) =>
      ctx.db
        .query("invite_tokens")
        .withIndex("by_client_id", (q) => q.eq("id", "invite_large_friend_fallbacks"))
        .unique()
    );
    expect(token?.claimed_by).toBeUndefined();
  });

  test("charges legacy alias-preflight rows to the shared claim budget", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();
    const largeProfile = "p".repeat(500 * 1024);
    const largeAuditEmail = `${"a".repeat(900 * 1024)}@test.com`;

    await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "creator_auth",
        email: "creator@test.com",
        display_name: "Creator",
        profile_image_url: largeProfile,
        created_at: now,
        member_id: "creator_member"
      });
      await ctx.db.insert("accounts", {
        id: "claimer_auth",
        email: "claimer@test.com",
        display_name: "Claimer",
        profile_image_url: largeProfile,
        created_at: now,
        member_id: "claimer_member"
      });
      await insertBoundInvite(ctx, {
        id: "invite_large_alias_preflight",
        creator_id: "creator_auth",
        creator_email: "creator@test.com",
        target_member_id: "claimer_legacy_member",
        target_member_name: "Claimer",
        created_at: now,
        expires_at: now + 60_000
      });
      for (let index = 0; index < 8; index += 1) {
        await ctx.db.insert("member_aliases", {
          alias_member_id: "claimer_legacy_member",
          canonical_member_id: "claimer_member",
          account_email: `${index}${largeAuditEmail}`,
          created_at: now - index - 1
        });
      }
    });

    const claimerCtx = await withReadyIdentity(t, "claimer@test.com", "claimer_auth");
    await expect(
      claimerCtx.mutation(api.inviteTokens.claim, {
        id: "invite_large_alias_preflight"
      })
    ).rejects.toThrow("Friend merge is too large to complete safely");

    const token = await t.run(async (ctx) =>
      ctx.db
        .query("invite_tokens")
        .withIndex("by_client_id", (q) => q.eq("id", "invite_large_alias_preflight"))
        .unique()
    );
    expect(token?.claimed_by).toBeUndefined();
  });

  test("shares the merge read budget across claimant and creator account rewrites", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();
    const largeName = "x".repeat(650 * 1024);

    await t.run(async (ctx) => {
      const creatorId = await ctx.db.insert("accounts", {
        id: "creator_auth",
        email: "creator@test.com",
        display_name: "Creator",
        created_at: now,
        member_id: "creator_member"
      });
      const claimerId = await ctx.db.insert("accounts", {
        id: "claimer_auth",
        email: "claimer@test.com",
        display_name: "Claimer",
        created_at: now,
        member_id: "claimer_member"
      });
      await insertBoundInvite(ctx, {
        id: "shared_merge_budget",
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
        name: "Creator duplicate",
        profile_avatar_color: "#444444",
        has_linked_account: false,
        status: "friend",
        link_state: "unlinked",
        updated_at: now
      });

      for (const [accountEmail, accountId, ownerId, memberId] of [
        ["creator@test.com", "creator_auth", creatorId, "creator_member"],
        ["claimer@test.com", "claimer_auth", claimerId, "claimer_member"]
      ] as const) {
        for (let index = 0; index < 3; index += 1) {
          await ctx.db.insert("groups", {
            id: `${accountId}_large_group_${index}`,
            name: largeName,
            members: [{ id: memberId, name: accountEmail, is_current_user: true }],
            owner_email: accountEmail,
            owner_account_id: accountId,
            owner_id: ownerId,
            created_at: now,
            updated_at: now
          });
        }
      }
    });

    const claimerCtx = await withReadyIdentity(t, "claimer@test.com", "claimer_auth");
    await expect(
      claimerCtx.mutation(api.inviteTokens.claim, {
        id: "shared_merge_budget",
        mergeLocalFriendMemberId: "local_duplicate"
      })
    ).rejects.toThrow("Friend merge is too large to complete safely");

    const token = await t.run(async (ctx) =>
      ctx.db
        .query("invite_tokens")
        .withIndex("by_client_id", (q) => q.eq("id", "shared_merge_budget"))
        .unique()
    );
    expect(token?.claimed_by).toBeUndefined();
  });

  test("rejects aggregate group and expense rewrite work before claiming the invite", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();

    await t.run(async (ctx) => {
      const creatorId = await ctx.db.insert("accounts", {
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
        id: "aggregate_rewrite_invite",
        creator_id: "creator_auth",
        creator_email: "creator@test.com",
        target_member_id: "claimer_legacy_member",
        target_member_name: "Claimer",
        created_at: now,
        expires_at: now + 60_000
      });
      await insertLargeRewriteSurface(ctx, {
        ownerId: creatorId,
        ownerAuthId: "creator_auth",
        ownerEmail: "creator@test.com",
        ownerMemberId: "creator_member",
        sourceMemberId: "claimer_legacy_member",
        prefix: "aggregate_rewrite",
        payloadBytes: 850 * 1024,
        now
      });
      const staleJobId = await ctx.db.insert("orphan_cleanup_jobs", {
        email: "stale-aggregate@example.com",
        subject: "stale_aggregate_auth",
        member_ids: ["claimer_legacy_member"],
        mode: "hard",
        status: "complete",
        processed_count: 1,
        retry_count: 0,
        member_fence_complete: true,
        created_at: now,
        updated_at: now
      });
      await ctx.db.insert("orphan_cleanup_member_fences", {
        job_id: staleJobId,
        member_id: "claimer_legacy_member",
        generation: 0,
        created_at: now
      });
    });

    const claimer = await withReadyIdentity(t, "claimer@test.com", "claimer_auth");
    await expect(
      claimer.mutation(api.inviteTokens.claim, { id: "aggregate_rewrite_invite" })
    ).rejects.toThrow("Friend merge is too large to complete safely");

    const state = await t.run(async (ctx) => ({
      token: await ctx.db
        .query("invite_tokens")
        .withIndex("by_client_id", (q) => q.eq("id", "aggregate_rewrite_invite"))
        .unique(),
      group: await ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", "aggregate_rewrite_group"))
        .unique(),
      expense: await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", "aggregate_rewrite_expense"))
        .unique(),
      claimant: await ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", "claimer_auth"))
        .unique(),
      targetFriend: await ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", "creator@test.com").eq("member_id", "claimer_legacy_member")
        )
        .unique(),
      aliases: await ctx.db.query("member_aliases").collect(),
      groupVisibility: await ctx.db.query("group_visibility").collect(),
      expenseVisibility: await ctx.db.query("user_expenses").collect(),
      syncStates: await ctx.db.query("account_sync_state").collect(),
      staleFences: await ctx.db
        .query("orphan_cleanup_member_fences")
        .withIndex("by_member_id", (q) => q.eq("member_id", "claimer_legacy_member"))
        .collect()
    }));
    expect(state.token?.claimed_by).toBeUndefined();
    expect(state.claimant?.alias_member_ids).toBeUndefined();
    expect(state.targetFriend).toMatchObject({
      has_linked_account: false,
      link_state: "unlinked"
    });
    expect(state.aliases).toEqual([]);
    expect(state.group?.members.map((member) => member.id)).toContain("claimer_legacy_member");
    expect(state.expense?.participant_member_ids).toContain("claimer_legacy_member");
    expect(state.groupVisibility).toEqual([]);
    expect(state.expenseVisibility).toEqual([]);
    expect(state.syncStates).toEqual([]);
    expect(state.staleFences).toHaveLength(1);
  }, 30_000);

  test("keeps a deferred stale fence when the aggregate write reservation is exhausted", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();
    const fixture = await t.run(async (ctx) => {
      await ctx.db.insert("accounts", {
        id: "fence_limit_creator_auth",
        email: "fence-limit-creator@test.com",
        display_name: "Creator",
        created_at: now,
        member_id: "fence_limit_creator_member"
      });
      const claimantId = await ctx.db.insert("accounts", {
        id: "fence_limit_claimant_auth",
        email: "fence-limit-claimant@test.com",
        display_name: "Claimant",
        created_at: now,
        member_id: "fence_limit_claimant_member"
      });
      await ctx.db.insert("identity_materialization_state", {
        key: "member_identity_v3",
        status: "ready",
        phase: "complete",
        updated_at: now
      });
      const targetFriendId = await ctx.db.insert("account_friends", {
        account_email: "fence-limit-creator@test.com",
        member_id: "fence_limit_legacy_member",
        name: "Claimant",
        profile_avatar_color: "#123456",
        has_linked_account: false,
        link_state: "unlinked",
        status: "friend",
        updated_at: now
      });
      await ctx.db.insert("invite_tokens", {
        id: "fence_limit_invite",
        creator_id: "fence_limit_creator_auth",
        creator_email: "fence-limit-creator@test.com",
        target_member_id: "fence_limit_legacy_member",
        target_friend_id: targetFriendId,
        target_member_name: "Claimant",
        created_at: now,
        expires_at: now + 60_000
      });
      const jobId = await ctx.db.insert("orphan_cleanup_jobs", {
        email: "fence-limit-orphan@test.com",
        subject: "fence_limit_orphan_auth",
        member_ids: ["fence_limit_legacy_member"],
        mode: "hard",
        status: "complete",
        processed_count: 1,
        retry_count: 0,
        member_fence_complete: true,
        created_at: now,
        updated_at: now
      });
      const fenceId = await ctx.db.insert("orphan_cleanup_member_fences", {
        job_id: jobId,
        member_id: "fence_limit_legacy_member",
        generation: 0,
        created_at: now
      });
      const claimant = await ctx.db.get(claimantId);
      if (!claimant) throw new Error("Expected claimant");
      return { claimant, targetFriendId, fenceId };
    });
    const budget = createLinkingReadBudget();
    budget.estimatedWriteBytes = 12 * 1024 * 1024 - 1;

    await expect(
      t.run((ctx) =>
        prepareClaimForUser(
          ctx,
          fixture.claimant,
          {
            targetMemberId: "fence_limit_legacy_member",
            targetFriendId: fixture.targetFriendId,
            creatorEmail: "fence-limit-creator@test.com",
            creatorId: "fence_limit_creator_auth"
          },
          budget
        )
      )
    ).rejects.toThrow("Friend merge is too large to complete safely");

    const state = await t.run(async (ctx) => ({
      fence: await ctx.db.get(fixture.fenceId),
      token: await ctx.db
        .query("invite_tokens")
        .withIndex("by_client_id", (q) => q.eq("id", "fence_limit_invite"))
        .unique(),
      claimant: await ctx.db.get(fixture.claimant._id),
      targetFriend: await ctx.db.get(fixture.targetFriendId),
      aliases: await ctx.db.query("member_aliases").collect()
    }));
    expect(state.fence).not.toBeNull();
    expect(state.token?.claimed_by).toBeUndefined();
    expect(state.claimant?.alias_member_ids).toBeUndefined();
    expect(state.targetFriend).toMatchObject({ has_linked_account: false });
    expect(state.aliases).toEqual([]);
  });

  test("rejects two individually safe invite rewrites when their aggregate work is unsafe", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();

    await t.run(async (ctx) => {
      const creatorId = await ctx.db.insert("accounts", {
        id: "creator_auth",
        email: "creator@test.com",
        display_name: "Creator",
        created_at: now,
        member_id: "creator_member"
      });
      const claimerId = await ctx.db.insert("accounts", {
        id: "claimer_auth",
        email: "claimer@test.com",
        display_name: "Claimer",
        created_at: now,
        member_id: "claimer_member"
      });
      await insertBoundInvite(ctx, {
        id: "aggregate_two_rewrite_invite",
        creator_id: "creator_auth",
        creator_email: "creator@test.com",
        target_member_id: "claimer_legacy_member",
        target_member_name: "Claimer",
        created_at: now,
        expires_at: now + 60_000
      });
      await ctx.db.insert("account_friends", {
        account_email: "claimer@test.com",
        member_id: "creator_local_duplicate",
        name: "Creator duplicate",
        profile_avatar_color: "#444444",
        has_linked_account: false,
        link_state: "unlinked",
        status: "friend",
        updated_at: now
      });
      await insertLargeRewriteSurface(ctx, {
        ownerId: creatorId,
        ownerAuthId: "creator_auth",
        ownerEmail: "creator@test.com",
        ownerMemberId: "creator_member",
        sourceMemberId: "claimer_legacy_member",
        prefix: "creator_aggregate",
        payloadBytes: 360 * 1024,
        now
      });
      await insertLargeRewriteSurface(ctx, {
        ownerId: claimerId,
        ownerAuthId: "claimer_auth",
        ownerEmail: "claimer@test.com",
        ownerMemberId: "claimer_member",
        sourceMemberId: "creator_local_duplicate",
        prefix: "claimer_aggregate",
        payloadBytes: 360 * 1024,
        now
      });
    });

    const claimer = await withReadyIdentity(t, "claimer@test.com", "claimer_auth");
    await expect(
      claimer.mutation(api.inviteTokens.claim, {
        id: "aggregate_two_rewrite_invite",
        mergeLocalFriendMemberId: "creator_local_duplicate"
      })
    ).rejects.toThrow("Friend merge is too large to complete safely");

    const state = await t.run(async (ctx) => ({
      token: await ctx.db
        .query("invite_tokens")
        .withIndex("by_client_id", (q) => q.eq("id", "aggregate_two_rewrite_invite"))
        .unique(),
      localFriend: await ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q
            .eq("account_email", "claimer@test.com")
            .eq("member_id", "creator_local_duplicate")
        )
        .unique(),
      creatorGroup: await ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", "creator_aggregate_group"))
        .unique(),
      claimerGroup: await ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", "claimer_aggregate_group"))
        .unique(),
      creatorExpense: await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", "creator_aggregate_expense"))
        .unique(),
      claimerExpense: await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q) => q.eq("id", "claimer_aggregate_expense"))
        .unique(),
      claimant: await ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", "claimer_auth"))
        .unique(),
      aliases: await ctx.db.query("member_aliases").collect(),
      groupVisibility: await ctx.db.query("group_visibility").collect(),
      expenseVisibility: await ctx.db.query("user_expenses").collect(),
      syncStates: await ctx.db.query("account_sync_state").collect()
    }));
    expect(state.token?.claimed_by).toBeUndefined();
    expect(state.claimant?.alias_member_ids).toBeUndefined();
    expect(state.aliases).toEqual([]);
    expect(state.localFriend).not.toBeNull();
    expect(state.creatorGroup?.members.map((member) => member.id)).toContain(
      "claimer_legacy_member"
    );
    expect(state.claimerGroup?.members.map((member) => member.id)).toContain(
      "creator_local_duplicate"
    );
    expect(state.creatorExpense?.participant_member_ids).toContain("claimer_legacy_member");
    expect(state.claimerExpense?.participant_member_ids).toContain("creator_local_duplicate");
    expect(state.groupVisibility).toEqual([]);
    expect(state.expenseVisibility).toEqual([]);
    expect(state.syncStates).toEqual([]);
  }, 30_000);
});
