import { query, mutation } from "./_generated/server";
import { v } from "convex/values";

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
    has_linked_account: v.boolean(),
    linked_account_id: v.optional(v.string()),
    linked_account_email: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const existing = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", identity.email!).eq("member_id", args.member_id)
      )
      .unique();

    if (existing) {
      await ctx.db.patch(existing._id, {
        name: args.name,
        nickname: args.nickname,
        has_linked_account: args.has_linked_account,
        linked_account_id: args.linked_account_id,
        linked_account_email: args.linked_account_email,
        updated_at: Date.now(),
      });
      return existing._id;
    } else {
      return await ctx.db.insert("account_friends", {
        account_email: identity.email!,
        member_id: args.member_id,
        name: args.name,
        nickname: args.nickname,
        has_linked_account: args.has_linked_account,
        linked_account_id: args.linked_account_id,
        linked_account_email: args.linked_account_email,
        updated_at: Date.now(),
      });
    }
  },
});
