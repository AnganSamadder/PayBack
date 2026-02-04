import { query, mutation } from "./_generated/server";
import { v } from "convex/values";
import { getRandomAvatarColor } from "./utils";

/**
 * Lists all friends for the current authenticated user.
 */
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

    return friends;
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

    let normalizedNickname = args.nickname;
    if (
      normalizedNickname &&
      normalizedNickname.trim().toLowerCase() === args.name.trim().toLowerCase()
    ) {
      normalizedNickname = undefined;
    }

    const existing = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", identity.email!).eq("member_id", args.member_id)
      )
      .unique();

    if (existing) {
      await ctx.db.patch(existing._id, {
        name: args.name,
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
      return existing._id;
    } else {
      return await ctx.db.insert("account_friends", {
        account_email: identity.email!,
        member_id: args.member_id,
        name: args.name,
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
