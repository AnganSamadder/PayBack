import { mutation, internalMutation } from "./_generated/server";
import { v } from "convex/values";
import { getAllEquivalentMemberIds } from "./aliases";

// Helper to get current user or throw
async function getCurrentUser(ctx: any) {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) {
    throw new Error("Unauthenticated");
  }
  const user = await ctx.db
    .query("accounts")
    .withIndex("by_email", (q: any) => q.eq("email", identity.email!))
    .unique();

  return { identity, user };
}

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

export const deleteLinkedFriend = mutation({
  args: {
    friendMemberId: v.string(),
    accountEmail: v.string(),
  },
  handler: async (ctx, args) => {
    const { friendMemberId, accountEmail } = args;

    const friend = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", accountEmail).eq("member_id", friendMemberId)
      )
      .unique();

    if (!friend) {
      return { success: false, message: "Friend not found" };
    }

    if (!friend.has_linked_account) {
      return {
        success: false,
        message: "Friend is not linked. Use deleteUnlinkedFriend instead.",
      };
    }

    const equivalentIds = await getAllEquivalentMemberIds(ctx.db, friendMemberId);

    const userAccount = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", accountEmail))
      .unique();

    if (!userAccount) {
      return { success: false, message: "Account not found" };
    }

    let directGroupDeleted = false;
    let expensesDeleted = 0;

    const ownedGroups = await ctx.db
      .query("groups")
      .withIndex("by_owner_email", (q) => q.eq("owner_email", accountEmail))
      .collect();

    for (const group of ownedGroups) {
      if (!group.is_direct) continue;

      const hasFriend = group.members.some((m) => equivalentIds.includes(m.id));
      if (!hasFriend) continue;

      const groupExpenses = await ctx.db
        .query("expenses")
        .withIndex("by_group_id", (q) => q.eq("group_id", group.id))
        .collect();

      for (const expense of groupExpenses) {
        await ctx.db.delete(expense._id);
        expensesDeleted++;
      }

      await ctx.db.delete(group._id);
      directGroupDeleted = true;
      break;
    }

    await ctx.db.delete(friend._id);

    return {
      success: true,
      message: "Linked friend removed",
      directGroupDeleted,
      expensesDeleted,
      linkedAccountPreserved: true,
    };
  },
});

export const deleteUnlinkedFriend = mutation({
  args: {
    friendMemberId: v.string(),
    accountEmail: v.string(),
  },
  handler: async (ctx, args) => {
    const { friendMemberId, accountEmail } = args;

    const friend = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", accountEmail).eq("member_id", friendMemberId)
      )
      .unique();

    if (!friend) {
      return { success: false, message: "Friend not found" };
    }

    if (friend.has_linked_account) {
      return {
        success: false,
        message: "Friend is linked. Use deleteLinkedFriend instead.",
      };
    }

    const equivalentIds = await getAllEquivalentMemberIds(ctx.db, friendMemberId);

    let groupsModified = 0;
    let expensesDeleted = 0;
    let expensesModified = 0;
    let aliasesDeleted = 0;

    const ownedGroups = await ctx.db
      .query("groups")
      .withIndex("by_owner_email", (q) => q.eq("owner_email", accountEmail))
      .collect();

    for (const group of ownedGroups) {
      const hasFriend = group.members.some((m) => equivalentIds.includes(m.id));
      if (!hasFriend) continue;

      const remainingMembers = group.members.filter(
        (m) => !equivalentIds.includes(m.id)
      );

      if (remainingMembers.length <= 1) {
        const groupExpenses = await ctx.db
          .query("expenses")
          .withIndex("by_group_id", (q) => q.eq("group_id", group.id))
          .collect();

        for (const expense of groupExpenses) {
          await ctx.db.delete(expense._id);
          expensesDeleted++;
        }

        await ctx.db.delete(group._id);
      } else {
        await ctx.db.patch(group._id, {
          members: remainingMembers,
          updated_at: Date.now(),
        });

        const groupExpenses = await ctx.db
          .query("expenses")
          .withIndex("by_group_id", (q) => q.eq("group_id", group.id))
          .collect();

        for (const expense of groupExpenses) {
          const involvesFriend =
            equivalentIds.includes(expense.paid_by_member_id) ||
            expense.involved_member_ids.some((id) => equivalentIds.includes(id));

          if (!involvesFriend) continue;

          const remainingParticipants = expense.participant_member_ids.filter(
            (id) => !equivalentIds.includes(id)
          );

          if (remainingParticipants.length <= 1) {
            await ctx.db.delete(expense._id);
            expensesDeleted++;
          } else {
            const newSplits = expense.splits.filter(
              (s) => !equivalentIds.includes(s.member_id)
            );
            const newParticipants = expense.participants.filter(
              (p) => !equivalentIds.includes(p.member_id)
            );
            const newInvolvedIds = expense.involved_member_ids.filter(
              (id) => !equivalentIds.includes(id)
            );

            await ctx.db.patch(expense._id, {
              splits: newSplits,
              participants: newParticipants,
              participant_member_ids: remainingParticipants,
              involved_member_ids: newInvolvedIds,
              updated_at: Date.now(),
            });
            expensesModified++;
          }
        }
      }
      groupsModified++;
    }

    for (const memberId of equivalentIds) {
      const aliasesAsCanonical = await ctx.db
        .query("member_aliases")
        .withIndex("by_canonical_member_id", (q) =>
          q.eq("canonical_member_id", memberId)
        )
        .collect();

      for (const alias of aliasesAsCanonical) {
        await ctx.db.delete(alias._id);
        aliasesDeleted++;
      }

      const aliasesAsAlias = await ctx.db
        .query("member_aliases")
        .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", memberId))
        .collect();

      for (const alias of aliasesAsAlias) {
        await ctx.db.delete(alias._id);
        aliasesDeleted++;
      }
    }

    await ctx.db.delete(friend._id);

    return {
      success: true,
      message: "Unlinked friend and all traces removed",
      groupsModified,
      expensesDeleted,
      expensesModified,
      aliasesDeleted,
    };
  },
});

export const hardDeleteAccount = internalMutation({
  args: { accountId: v.id("accounts") },
  handler: async (ctx, args) => {
    const account = await ctx.db.get(args.accountId);
    if (!account) {
      return { success: false, message: "Account not found" };
    }

    const email = account.email;
    let friendsDeleted = 0;
    let groupsDeleted = 0;
    let expensesDeleted = 0;
    let aliasesDeleted = 0;

    const friends = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email", (q) => q.eq("account_email", email))
      .collect();

    for (const friend of friends) {
      await ctx.db.delete(friend._id);
      friendsDeleted++;
    }

    const ownedGroups = await ctx.db
      .query("groups")
      .withIndex("by_owner_email", (q) => q.eq("owner_email", email))
      .collect();

    for (const group of ownedGroups) {
      const groupExpenses = await ctx.db
        .query("expenses")
        .withIndex("by_group_id", (q) => q.eq("group_id", group.id))
        .collect();

      for (const expense of groupExpenses) {
        await ctx.db.delete(expense._id);
        expensesDeleted++;
      }

      await ctx.db.delete(group._id);
      groupsDeleted++;
    }

    const ownedExpenses = await ctx.db
      .query("expenses")
      .withIndex("by_owner_email", (q) => q.eq("owner_email", email))
      .collect();

    for (const expense of ownedExpenses) {
      await ctx.db.delete(expense._id);
      expensesDeleted++;
    }

    if (account.linked_member_id) {
      const aliasesAsCanonical = await ctx.db
        .query("member_aliases")
        .withIndex("by_canonical_member_id", (q) =>
          q.eq("canonical_member_id", account.linked_member_id!)
        )
        .collect();

      for (const alias of aliasesAsCanonical) {
        await ctx.db.delete(alias._id);
        aliasesDeleted++;
      }

      const aliasesAsAlias = await ctx.db
        .query("member_aliases")
        .withIndex("by_alias_member_id", (q) =>
          q.eq("alias_member_id", account.linked_member_id!)
        )
        .collect();

      for (const alias of aliasesAsAlias) {
        await ctx.db.delete(alias._id);
        aliasesDeleted++;
      }
    }

    await ctx.db.delete(args.accountId);

    return {
      success: true,
      message: `Hard deleted account ${email}`,
      friendsDeleted,
      groupsDeleted,
      expensesDeleted,
      aliasesDeleted,
    };
  },
});

export const selfDeleteAccount = mutation({
  args: { accountEmail: v.string() },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUser(ctx);
    if (!user || user.email !== args.accountEmail) {
      throw new Error("Can only delete your own account");
    }

    let friendshipsUnlinked = 0;

    if (user.linked_member_id) {
      const equivalentIds = await getAllEquivalentMemberIds(
        ctx.db,
        user.linked_member_id
      );

      const allFriends = await ctx.db.query("account_friends").collect();

      for (const friendRecord of allFriends) {
        if (friendRecord.account_email === args.accountEmail) continue;

        const pointsToMe =
          friendRecord.linked_account_email === args.accountEmail ||
          friendRecord.linked_account_id === user.id ||
          equivalentIds.includes(friendRecord.member_id);

        if (pointsToMe && friendRecord.has_linked_account) {
          await ctx.db.patch(friendRecord._id, {
            has_linked_account: false,
            linked_account_id: undefined,
            linked_account_email: undefined,
            updated_at: Date.now(),
          });
          friendshipsUnlinked++;
        }
      }
    }

    await ctx.db.delete(user._id);

    return {
      success: true,
      message: "Account deleted, friendships unlinked, expenses preserved",
      friendshipsUnlinked,
      expensesPreserved: true,
    };
  },
});
