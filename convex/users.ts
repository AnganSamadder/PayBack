import { mutation, query } from "./_generated/server";
import { v } from "convex/values";

/**
 * Stores or updates the current user in the `accounts` table.
 * Should be called after authentication to ensure the user exists in our DB.
 */
export const store = mutation({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Called storeUser without authentication present");
    }

    // Check if we already have an account for this user
    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", identity.email!))
      .unique();

    if (user !== null) {
      // Update existing user if needed (e.g. name changed)
      // For now, we just return the existing user's ID
      // We could patch the display_name if it changed
      if (user.display_name !== identity.name && identity.name) {
          await ctx.db.patch(user._id, { display_name: identity.name, updated_at: Date.now() });
      }
      return user._id;
    }

    // Create new user
    const newUserId = await ctx.db.insert("accounts", {
        id: identity.subject, // Using Clerk ID as our specific ID field if useful, or just reliance on _id
        email: identity.email!,
        display_name: identity.name || identity.email!.split("@")[0] || "User",
        created_at: Date.now(),
        updated_at: Date.now(),
    });

    return newUserId;
  },
});

/**
 * Gets the current user's account information.
 */
export const viewer = query({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      return null;
    }

    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", identity.email!))
      .unique();

    return user;
  },
});

/**
 * Updates the linked_member_id for the current user.
 * This links the user's account to a member from another user's friend list.
 */
export const updateLinkedMemberId = mutation({
  args: { linked_member_id: v.string() },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Unauthenticated");
    }

    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", identity.email!))
      .unique();

    if (!user) {
      throw new Error("User not found");
    }

    await ctx.db.patch(user._id, {
      linked_member_id: args.linked_member_id,
      updated_at: Date.now(),
    });

    return user._id;
  },
});
