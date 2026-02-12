import { GenericMutationCtx } from "convex/server";
import { DataModel } from "./_generated/dataModel";

const WINDOW_MS = 60 * 1000;

/**
 * Checks and increments the rate limit for a given user and action.
 * Throws an error if the limit is exceeded.
 * Key format: rate_limit:{userId}:{action}
 */
export async function checkRateLimit(
  ctx: GenericMutationCtx<DataModel>,
  userId: string,
  action: string,
  limit: number
) {
  const now = Date.now();
  const key = `rate_limit:${userId}:${action}`;
  
  const rateLimit = await ctx.db
    .query("rate_limits")
    .withIndex("by_key", (q) => q.eq("key", key))
    .unique();

  if (!rateLimit) {
    await ctx.db.insert("rate_limits", {
      key,
      count: 1,
      window_start: now,
    });
    return;
  }

  if (now - rateLimit.window_start > WINDOW_MS) {
    // Reset window
    await ctx.db.patch(rateLimit._id, {
      count: 1,
      window_start: now,
    });
    return;
  }

  if (rateLimit.count >= limit) {
    // We use a specific message that includes 429 to satisfy requirements
    throw new Error(`Rate limit exceeded for ${action}. Please try again in a minute. (Status: 429)`);
  }

  await ctx.db.patch(rateLimit._id, {
    count: rateLimit.count + 1,
  });
}
