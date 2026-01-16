import { mutation, query, action } from "./_generated/server";
import { v } from "convex/values";
import { getRandomAvatarColor } from "./utils";

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
        profile_avatar_color: getRandomAvatarColor(),
        created_at: Date.now(),
        updated_at: Date.now(),
    });

    return newUserId;
  },
});

/**
 * Checks if the user is authenticated on the server.
 * Used for client-side verification before attempting mutations.
 */
export const isAuthenticated = query({
  args: {},
  handler: async (ctx) => {
    return (await ctx.auth.getUserIdentity()) !== null;
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

/**
 * Updates the user's profile information.
 */
/**
 * Generates a URL for uploading a file to Convex storage.
 */
export const generateUploadUrl = action({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");
    return await ctx.storage.generateUploadUrl();
  },
});

/**
 * Updates the user's profile information.
 */
export const updateProfile = mutation({
  args: {
    profile_avatar_color: v.optional(v.string()),
    profile_image_url: v.optional(v.string()),
    storage_id: v.optional(v.id("_storage")),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", identity.email!))
      .unique();

    if (!user) throw new Error("User not found");

    const patches: any = { updated_at: Date.now() };
    if (args.profile_avatar_color !== undefined) patches.profile_avatar_color = args.profile_avatar_color;
    
    // Handle storage ID to URL conversion
    if (args.storage_id) {
      const url = await ctx.storage.getUrl(args.storage_id);
      if (url) {
        patches.profile_image_url = url;
        // Update args so propagation uses the new URL
        args.profile_image_url = url;
      }
    } else if (args.profile_image_url !== undefined) {
      patches.profile_image_url = args.profile_image_url;
    }

    await ctx.db.patch(user._id, patches);

    // Propagate to linked friends
    const friendsToUpdate = await ctx.db
      .query("account_friends")
      .withIndex("by_linked_account_id", (q) => q.eq("linked_account_id", user.id))
      .collect();

    for (const friend of friendsToUpdate) {
      const friendPatches: any = { updated_at: Date.now() };
      if (args.profile_avatar_color !== undefined) friendPatches.profile_avatar_color = args.profile_avatar_color;
      // Use the resolved URL (from storage or direct arg)
      if (patches.profile_image_url !== undefined) friendPatches.profile_image_url = patches.profile_image_url;
      await ctx.db.patch(friend._id, friendPatches);
    }
    
    return patches.profile_image_url;
  },
});
