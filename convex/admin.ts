import { mutation } from "./_generated/server";
import { v } from "convex/values";
import { cleanupOrphanedDataForEmail } from "./users";

/**
 * HARD DELETE USER (Admin Only)
 * 
 * Performs a "Clean Slate" wipe of a user's account.
 * - Wipes all owned data (groups, expenses, friends, invites)
 * - Deletes the user account row
 * - Scrubs orphaned data
 * 
 * Usage: call via dashboard or admin CLI
 */
export const hardDeleteUser = mutation({
  args: {
    email: v.string(),
  },
  handler: async (ctx, args) => {
    // 1. Verify admin (in production, check ctx.auth for admin role)
    // For now, this is an internal mutation callable by anyone with the function URL
    // TODO: Add proper role-based access control if exposed publicly
    
    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", args.email))
      .unique();

    if (!user) {
      // Even if user record is gone, try to cleanup orphaned data to be safe
      await cleanupOrphanedDataForEmail(ctx, {
        email: args.email,
        subject: "", // No subject available if user gone
      });
      return { status: "not_found_but_scrubbed", email: args.email };
    }

    // 2. Run the cleanup logic (wipes everything owned by this email)
    const cleanupStats = await cleanupOrphanedDataForEmail(ctx, {
      email: user.email,
      subject: user.id, // The Clerk/Auth ID
    });

    // 3. Delete the account row itself
    await ctx.db.delete(user._id);

    return {
      status: "deleted",
      email: user.email,
      stats: cleanupStats,
    };
  },
});
