import { mutation } from "./_generated/server";
import { v } from "convex/values";
import { hardCleanupOrphanedAccount } from "./users";

export const hardDeleteUser = mutation({
  args: {
    email: v.string(),
  },
  handler: async (ctx, args) => {
    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", args.email))
      .unique();

    if (!user) {
      const scrubStats = await hardCleanupOrphanedAccount(ctx, {
        email: args.email,
      });
      return { status: "not_found_but_scrubbed", email: args.email, stats: scrubStats };
    }

    const cleanupStats = await hardCleanupOrphanedAccount(ctx, {
      email: user.email,
    });

    await ctx.db.delete(user._id);

    return {
      status: "deleted",
      email: user.email,
      stats: cleanupStats,
    };
  },
});
