import { query, mutation } from "./_generated/server";
import { v } from "convex/values";
import { getRandomAvatarColor } from "./utils";
import { findAccountByMemberId, normalizeMemberId, normalizeMemberIds } from "./identity";

export const list = query({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) return [];

    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", identity.email!))
      .unique();

    if (!user) return [];

    const friends = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email", (q) => q.eq("account_email", user.email))
      .collect();

    type LinkedIdentityContext = {
      account: Awaited<ReturnType<typeof findAccountByMemberId>> | null;
      aliasSet: Set<string>;
      memberIds: Set<string>;
    };

    // Build linked identity contexts keyed by linked account identity.
    // Each context tracks canonical + alias IDs and any member IDs currently
    // present in account_friends for this owner.
    const linkedIdentityContexts = new Map<string, LinkedIdentityContext>();
    const normalizedFriends = friends.map((friend) => ({
      ...friend,
      normalizedMemberId: normalizeMemberId(friend.member_id),
    }));

    const linkedFriends = normalizedFriends.filter((friend) => friend.has_linked_account);
    for (const friend of linkedFriends) {
      const identityKey =
        friend.linked_account_email?.trim().toLowerCase() ||
        friend.linked_account_id ||
        friend.linked_member_id;
      if (!identityKey) continue;

      let linkedAccount = null;
      if (friend.linked_account_email) {
        linkedAccount = await ctx.db
          .query("accounts")
          .withIndex("by_email", (q) => q.eq("email", friend.linked_account_email!))
          .unique();
      }
      if (!linkedAccount && friend.linked_member_id) {
        linkedAccount = await findAccountByMemberId(ctx.db, friend.linked_member_id);
      }

      const aliasSet = new Set<string>();
      if (linkedAccount?.member_id) {
        aliasSet.add(normalizeMemberId(linkedAccount.member_id));
      }
      for (const alias of linkedAccount?.alias_member_ids || []) {
        aliasSet.add(normalizeMemberId(alias));
      }

      linkedIdentityContexts.set(identityKey, {
        account: linkedAccount,
        aliasSet,
        memberIds: new Set<string>([friend.normalizedMemberId]),
      });
    }

    // Pull in stale unlinked rows that actually belong to the same linked identity,
    // by matching member_id against linked account canonical/alias set.
    for (const friend of normalizedFriends) {
      for (const [, context] of linkedIdentityContexts) {
        if (context.aliasSet.has(friend.normalizedMemberId)) {
          context.memberIds.add(friend.normalizedMemberId);
        }
      }
    }

    const validatedFriends = [];
    for (const friend of normalizedFriends) {
      if (friend.has_linked_account && friend.linked_account_email) {
        const identityKey =
          friend.linked_account_email?.trim().toLowerCase() ||
          friend.linked_account_id ||
          friend.linked_member_id;
        const context = identityKey ? linkedIdentityContexts.get(identityKey) : undefined;
        const linkedAccount = context?.account;

        if (!linkedAccount) {
          validatedFriends.push({
            ...friend,
            member_id: friend.normalizedMemberId,
            has_linked_account: false,
            linked_account_id: undefined,
            linked_account_email: undefined,
            linked_member_id: undefined,
            alias_member_ids: [],
          });
          continue;
        }
        
        // Enrich with aliases from the linked account
        const duplicateMemberIds = context ? Array.from(context.memberIds) : [];
        const enrichedAliases = normalizeMemberIds([
          ...(linkedAccount.alias_member_ids || []),
          ...duplicateMemberIds,
        ]);

        validatedFriends.push({
          ...friend,
          member_id: friend.normalizedMemberId,
          linked_member_id: linkedAccount.member_id
            ? normalizeMemberId(linkedAccount.member_id)
            : undefined,
          alias_member_ids: enrichedAliases,
        });
      }

      else if (friend.has_linked_account && friend.linked_member_id) {
        const identityKey =
          friend.linked_account_email?.trim().toLowerCase() ||
          friend.linked_account_id ||
          friend.linked_member_id;
        const context = identityKey ? linkedIdentityContexts.get(identityKey) : undefined;
        const linkedByMemberId = context?.account ?? await findAccountByMemberId(ctx.db, friend.linked_member_id);

        if (!linkedByMemberId) {
          validatedFriends.push({
            ...friend,
            member_id: friend.normalizedMemberId,
            has_linked_account: false,
            linked_account_id: undefined,
            linked_account_email: undefined,
            linked_member_id: undefined,
            alias_member_ids: [],
          });
          continue;
        }
        
        // Enrich with aliases from the linked account
        const duplicateMemberIds = context ? Array.from(context.memberIds) : [];
        const enrichedAliases = normalizeMemberIds([
          ...(linkedByMemberId.alias_member_ids || []),
          ...duplicateMemberIds,
        ]);

        validatedFriends.push({
          ...friend,
          member_id: friend.normalizedMemberId,
          linked_member_id: linkedByMemberId.member_id
            ? normalizeMemberId(linkedByMemberId.member_id)
            : undefined,
          alias_member_ids: enrichedAliases,
        });
      } else {
        validatedFriends.push({
            ...friend,
            member_id: friend.normalizedMemberId,
            alias_member_ids: [],
        });
      }
    }

    return validatedFriends;
  },
});

/**
 * Stores or updates a friend.
 */
export const upsert = mutation({
  args: {
    member_id: v.string(),
    name: v.string(),
    nickname: v.optional(v.string()),
    original_name: v.optional(v.string()),
    original_nickname: v.optional(v.string()),
    prefer_nickname: v.optional(v.boolean()),
    has_linked_account: v.boolean(),
    linked_account_id: v.optional(v.string()),
    linked_account_email: v.optional(v.string()),
    status: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");
    const normalizedMemberId = normalizeMemberId(args.member_id);

    // Ensure name is never empty
    const safeName = args.name?.trim() || "Unknown";

    let normalizedNickname = args.nickname;
    if (
      normalizedNickname &&
      normalizedNickname.trim().toLowerCase() === safeName.toLowerCase()
    ) {
      normalizedNickname = undefined;
    }

    const existing = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", identity.email!).eq("member_id", normalizedMemberId)
      )
      .unique();
    const existingLegacy =
      existing ??
      (await ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (q) => q.eq("account_email", identity.email!))
        .collect())
        .find((friend) => normalizeMemberId(friend.member_id) === normalizedMemberId);

    if (existingLegacy) {
      await ctx.db.patch(existingLegacy._id, {
        member_id: normalizedMemberId,
        name: safeName,
        nickname: normalizedNickname,
        original_name: args.original_name,
        original_nickname: args.original_nickname,
        prefer_nickname: args.prefer_nickname,
        has_linked_account: args.has_linked_account,
        linked_account_id: args.linked_account_id,
        linked_account_email: args.linked_account_email,
        status: args.status,
        updated_at: Date.now(),
      });
      return existingLegacy._id;
    } else {
      return await ctx.db.insert("account_friends", {
        account_email: identity.email!,
        member_id: normalizedMemberId,
        name: safeName,
        nickname: normalizedNickname,
        original_name: args.original_name,
        original_nickname: args.original_nickname,
        prefer_nickname: args.prefer_nickname,
        profile_avatar_color: getRandomAvatarColor(),
        has_linked_account: args.has_linked_account,
        linked_account_id: args.linked_account_id,
        linked_account_email: args.linked_account_email,
        status: args.status,
        updated_at: Date.now(),
      });
    }
  },
});

/**
 * Clears all friends for the current authenticated user.
 */
export const clearAllForUser = mutation({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const friends = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email", (q) => q.eq("account_email", identity.email!))
      .collect();

    for (const friend of friends) {
      await ctx.db.delete(friend._id);
    }
    return null;
  },
});
