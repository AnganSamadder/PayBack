import { mutation, query } from "./_generated/server";
import { v } from "convex/values";

// Helper to get current authenticated user
async function getCurrentUser(ctx: any) {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) {
    throw new Error("Unauthenticated");
  }
  const user = await ctx.db
    .query("accounts")
    .withIndex("by_email", (q) => q.eq("email", identity.email!))
    .unique();

  return { identity, user };
}

/**
 * Creates a new invite token for a target member.
 * The current user becomes the creator of the token.
 */
export const create = mutation({
  args: {
    id: v.string(), // Client-generated UUID for deduplication
    target_member_id: v.string(),
    target_member_name: v.string(),
  },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");

    // Deduplication check
    const existing = await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    if (existing) {
      return existing._id;
    }

    // Create token with 30-day expiry
    const now = Date.now();
    const expiresAt = now + 30 * 24 * 60 * 60 * 1000; // 30 days

    const tokenId = await ctx.db.insert("invite_tokens", {
      id: args.id,
      creator_id: user.id,
      creator_email: user.email,
      target_member_id: args.target_member_id,
      target_member_name: args.target_member_name,
      created_at: now,
      expires_at: expiresAt,
    });

    return tokenId;
  },
});

/**
 * Gets a single invite token by client ID.
 * Does NOT require authentication - used for validation before login.
 */
export const get = query({
  args: { id: v.string() },
  handler: async (ctx, args) => {
    const token = await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    return token;
  },
});

/**
 * Validates an invite token and returns its status.
 * Returns validation info including whether it's valid, expired, or already claimed.
 * Does NOT require authentication - used for preview before login.
 */
export const validate = query({
  args: { id: v.string() },
  handler: async (ctx, args) => {
    const token = await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    if (!token) {
      return {
        is_valid: false,
        error: "Token not found",
        token: null,
        expense_preview: null,
      };
    }

    const now = Date.now();

    if (token.expires_at < now) {
      return {
        is_valid: false,
        error: "Token has expired",
        token,
        expense_preview: null,
      };
    }

    if (token.claimed_by) {
      return {
        is_valid: false,
        error: "Token has already been claimed",
        token,
        expense_preview: null,
      };
    }

    // Generate expense preview - find all expenses involving this member
    const allExpenses = await ctx.db.query("expenses").collect();
    const memberExpenses = allExpenses.filter(
      (e) =>
        e.involved_member_ids.includes(token.target_member_id) ||
        e.paid_by_member_id === token.target_member_id
    );

    // Get group names
    const groupIds = [...new Set(memberExpenses.map((e) => e.group_id))];
    const groups = await Promise.all(
      groupIds.map(async (gid) => {
        const g = await ctx.db
          .query("groups")
          .withIndex("by_client_id", (q) => q.eq("id", gid))
          .first();
        return g;
      })
    );
    const groupNames = groups.filter((g) => g).map((g) => g!.name);

    // Calculate balance
    let totalBalance = 0;
    for (const expense of memberExpenses) {
      if (expense.paid_by_member_id === token.target_member_id) {
        // They paid, others owe them
        const othersOwe = expense.splits
          .filter((s) => s.member_id !== token.target_member_id)
          .reduce((sum, s) => sum + s.amount, 0);
        totalBalance += othersOwe;
      } else {
        // They owe someone
        const theirSplit = expense.splits.find(
          (s) => s.member_id === token.target_member_id
        );
        if (theirSplit) {
          totalBalance -= theirSplit.amount;
        }
      }
    }

    return {
      is_valid: true,
      error: null,
      token,
      expense_preview: {
        expense_count: memberExpenses.length,
        group_names: groupNames,
        total_balance: totalBalance,
      },
    };
  },
});

/**
 * Claims an invite token for the current user.
 * This links the current user's account to the target member.
 */
export const claim = mutation({
  args: { id: v.string() },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");

    const token = await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    if (!token) {
      throw new Error("Token not found");
    }

    const now = Date.now();

    if (token.expires_at < now) {
      throw new Error("Token has expired");
    }

    if (token.claimed_by) {
      throw new Error("Token has already been claimed");
    }

    // Mark token as claimed
    await ctx.db.patch(token._id, {
      claimed_by: user.id,
      claimed_at: now,
    });

    // Update the current user's linked_member_id
    await ctx.db.patch(user._id, {
      linked_member_id: token.target_member_id,
      updated_at: now,
    });

    // Update the friend record to mark as linked
    const friendRecord = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", token.creator_email).eq("member_id", token.target_member_id)
      )
      .unique();

    if (friendRecord) {
      await ctx.db.patch(friendRecord._id, {
        has_linked_account: true,
        linked_account_id: user.id,
        linked_account_email: user.email,
        updated_at: now,
      });
    }

    return {
      linked_member_id: token.target_member_id,
      linked_account_id: user.id,
      linked_account_email: user.email,
    };
  },
});

/**
 * Lists all active (unclaimed, unexpired) invite tokens created by the current user.
 */
export const listByCreator = query({
  args: {},
  handler: async (ctx) => {
    const { user } = await getCurrentUser(ctx);
    if (!user) return [];

    const now = Date.now();

    const tokens = await ctx.db
      .query("invite_tokens")
      .withIndex("by_creator_id", (q) => q.eq("creator_id", user.id))
      .collect();

    // Filter to active tokens only
    return tokens.filter((t) => !t.claimed_by && t.expires_at > now);
  },
});

/**
 * Revokes an invite token, preventing it from being claimed.
 */
export const revoke = mutation({
  args: { id: v.string() },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");

    const token = await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    if (!token) {
      throw new Error("Token not found");
    }

    // Only creator can revoke
    if (token.creator_id !== user.id) {
      throw new Error("Not authorized to revoke this token");
    }

    // Delete the token
    await ctx.db.delete(token._id);
  },
});
