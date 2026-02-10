import { mutation } from "./_generated/server";

export const deleteSelfFriends = mutation({
  args: {},
  handler: async (ctx) => {
    // Admin mode: Clean for ALL users
    const users = await ctx.db.query("accounts").collect();
    console.log(`Analyzing ${users.length} users for self-friends...`);
    
    for (const user of users) {
        const friends = await ctx.db
          .query("account_friends")
          .withIndex("by_account_email", (q) => q.eq("account_email", user.email))
          .collect();
          
        let selfFriendsCount = 0;
        
        for (const friend of friends) {
            // Logic: A friend is a "self-friend" if:
            // 1. Their name matches the user's display name
            // 2. AND they are not linked (or linked to self, which is invalid anyway)
            // 3. AND/OR we deduce it from context (harder).
            
            // The screenshot showed duplicates of "Angan Samadder" with "unset" linked account.
            
            if (friend.name === user.display_name && !friend.has_linked_account) {
                 console.log(`Deleting self-friend for ${user.email}: ${friend.name} (${friend._id})`);
                 await ctx.db.delete(friend._id);
                 selfFriendsCount++;
            }
        }
        
        if (selfFriendsCount > 0) {
            console.log(`Cleaned ${selfFriendsCount} self-friends for ${user.email}`);
        }
    }
    
    return "Cleanup complete";
  }
});

import { v } from "convex/values";

export const deleteAccountByEmail = mutation({
  args: { email: v.string() },
  handler: async (ctx, args) => {
    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", args.email))
      .unique();

    if (!user) {
      return { success: false, message: "User not found" };
    }

    await ctx.db.delete(user._id);
    return { success: true, message: `Deleted user ${args.email}` };
  },
});

/**
 * Delete all data from the orphaned subexpenses table.
 * This table is no longer in the schema (subexpenses are embedded in expenses).
 */
export const deleteSubexpensesTable = mutation({
  args: {},
  handler: async (ctx) => {
    // Query the orphaned table using type assertion
    const allSubexpenses = await ctx.db.query("subexpenses" as any).collect();
    
    let deleted = 0;
    for (const sub of allSubexpenses) {
      await ctx.db.delete(sub._id);
      deleted++;
    }
    
    return { deleted, message: `Deleted ${deleted} rows from orphaned subexpenses table` };
  },
});
