import { mutation } from "./_generated/server";
import { v } from "convex/values";
import { hardCleanupOrphanedAccount } from "./users";

async function requireAdmin(ctx: any) {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) {
    throw new Error("Unauthenticated");
  }

  const configured = [...(process.env.ADMIN_EMAILS ?? "").split(","), process.env.ADMIN_EMAIL ?? ""]
    .map((email) => email.trim().toLowerCase())
    .filter(Boolean);

  const callerEmail = identity.email?.trim().toLowerCase();
  if (!callerEmail || !configured.includes(callerEmail)) {
    throw new Error("Not authorized: Admin access required");
  }
}

export const hardDeleteUser = mutation({
  args: {
    email: v.string()
  },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);

    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", args.email))
      .unique();

    if (!user) {
      const scrubStats = await hardCleanupOrphanedAccount(ctx, {
        email: args.email
      });
      return { status: "not_found_but_scrubbed", email: args.email, stats: scrubStats };
    }

    const cleanupStats = await hardCleanupOrphanedAccount(ctx, {
      email: user.email
    });

    await ctx.db.delete(user._id);

    return {
      status: "deleted",
      email: user.email,
      stats: cleanupStats
    };
  }
});
