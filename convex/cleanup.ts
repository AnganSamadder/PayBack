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

async function deleteUserExpensesForExpense(ctx: any, expenseId: string) {
  const rows = await ctx.db
    .query("user_expenses")
    .withIndex("by_expense_id", (q: any) => q.eq("expense_id", expenseId))
    .collect();
  for (const row of rows) await ctx.db.delete(row._id);
}

const MAX_SAMPLE_IDS = 10;
const sampleIds = (ids: string[]) => ids.slice(0, MAX_SAMPLE_IDS);

const logHardDelete = (
  base: {
    operationId: string;
    source: string;
    email: string;
    subject: string;
    accountId: string;
    linkedMemberId?: string;
  },
  step: string,
  data: Record<string, unknown>
) => {
  console.log(
    JSON.stringify({
      scope: "cleanup.hard_delete",
      ...base,
      step,
      ...data,
    })
  );
};

async function performHardDelete(ctx: any, account: any, source: string) {
  const operationId = crypto.randomUUID();
  const baseLog = {
    operationId,
    source,
    email: account.email,
    subject: account.id,
    accountId: account._id,
    linkedMemberId: account.linked_member_id,
  };

  logHardDelete(baseLog, "start", { message: "Starting hard delete" });

  const friends = await ctx.db
    .query("account_friends")
    .withIndex("by_account_email", (q: any) => q.eq("account_email", account.email))
    .collect();
  const friendIds: string[] = [];
  for (const friend of friends) {
    await ctx.db.delete(friend._id);
    friendIds.push(friend._id);
  }
  logHardDelete(baseLog, "delete_account_friends", {
    deletedCount: friendIds.length,
    sampleIds: sampleIds(friendIds),
  });

  // Delete user_expenses view for this account (user_id is Clerk id)
  const myUserExpenses = await ctx.db
    .query("user_expenses")
    .withIndex("by_user_id", (q: any) => q.eq("user_id", account.id))
    .collect();
  for (const ue of myUserExpenses) await ctx.db.delete(ue._id);

  const groupsByEmail = await ctx.db
    .query("groups")
    .withIndex("by_owner_email", (q: any) => q.eq("owner_email", account.email))
    .collect();
  const groupsByAccountId = await ctx.db
    .query("groups")
    .withIndex("by_owner_account_id", (q: any) =>
      q.eq("owner_account_id", account.id)
    )
    .collect();
  const groupsById = new Map<string, any>();
  for (const group of groupsByEmail) {
    groupsById.set(group._id, group);
  }
  for (const group of groupsByAccountId) {
    groupsById.set(group._id, group);
  }

  const groupIds: string[] = [];
  const groupExpenseIds: string[] = [];
  const deletedExpenseIds = new Set<string>();
  for (const group of groupsById.values()) {
    const groupExpenses = await ctx.db
      .query("expenses")
      .withIndex("by_group_id", (q: any) => q.eq("group_id", group.id))
      .collect();
    for (const expense of groupExpenses) {
      if (deletedExpenseIds.has(expense._id)) continue;
      deleteUserExpensesForExpense(ctx, expense.id);
      await ctx.db.delete(expense._id);
      deletedExpenseIds.add(expense._id);
      groupExpenseIds.push(expense._id);
    }
    await ctx.db.delete(group._id);
    groupIds.push(group._id);
  }
  logHardDelete(baseLog, "delete_groups", {
    deletedCount: groupIds.length,
    sampleIds: sampleIds(groupIds),
  });
  logHardDelete(baseLog, "delete_group_expenses", {
    deletedCount: groupExpenseIds.length,
    sampleIds: sampleIds(groupExpenseIds),
  });

  const expensesByEmail = await ctx.db
    .query("expenses")
    .withIndex("by_owner_email", (q: any) => q.eq("owner_email", account.email))
    .collect();
  const expensesByAccountId = await ctx.db
    .query("expenses")
    .withIndex("by_owner_account_id", (q: any) =>
      q.eq("owner_account_id", account.id)
    )
    .collect();
  const expenseById = new Map<string, any>();
  for (const expense of expensesByEmail) {
    expenseById.set(expense._id, expense);
  }
  for (const expense of expensesByAccountId) {
    expenseById.set(expense._id, expense);
  }
  const ownedExpenseIds: string[] = [];
  for (const expense of expenseById.values()) {
    if (deletedExpenseIds.has(expense._id)) continue;
    deleteUserExpensesForExpense(ctx, expense.id);
    await ctx.db.delete(expense._id);
    deletedExpenseIds.add(expense._id);
    ownedExpenseIds.push(expense._id);
  }
  logHardDelete(baseLog, "delete_owned_expenses", {
    deletedCount: ownedExpenseIds.length,
    sampleIds: sampleIds(ownedExpenseIds),
  });

  const linkedInOthersLists = await ctx.db
    .query("account_friends")
    .withIndex("by_linked_account_id", (q: any) =>
      q.eq("linked_account_id", account.id)
    )
    .collect();
  const unlinkedIds: string[] = [];
  const unlinkedSet = new Set<string>();
  for (const friendRecord of linkedInOthersLists) {
    await ctx.db.patch(friendRecord._id, {
      has_linked_account: false,
      linked_account_id: undefined,
      linked_account_email: undefined,
      updated_at: Date.now(),
    });
    unlinkedIds.push(friendRecord._id);
    unlinkedSet.add(friendRecord._id);
  }

  const potentialZombies = await ctx.db.query("account_friends").collect();
  for (const z of potentialZombies) {
    if (z.account_email === account.email) continue;

    const isZombie =
      z.linked_account_email === account.email ||
      z.linked_account_id === account.id ||
      (account.linked_member_id &&
        z.linked_account_id === account.linked_member_id);

    if (isZombie && z.has_linked_account && !unlinkedSet.has(z._id)) {
      await ctx.db.patch(z._id, {
        has_linked_account: false,
        linked_account_id: undefined,
        linked_account_email: undefined,
        updated_at: Date.now(),
      });
      unlinkedIds.push(z._id);
      unlinkedSet.add(z._id);
    }
  }
  logHardDelete(baseLog, "unlink_from_others", {
    unlinkedCount: unlinkedIds.length,
    sampleIds: sampleIds(unlinkedIds),
    scanUsed: true,
    scanReason: "linked_account_email has no index",
  });

  const incomingRequests = await ctx.db
    .query("link_requests")
    .withIndex("by_recipient_email", (q: any) =>
      q.eq("recipient_email", account.email)
    )
    .collect();
  let deletedRequests = 0;
  const requestIds: string[] = [];
  for (const req of incomingRequests) {
    await ctx.db.delete(req._id);
    deletedRequests++;
    requestIds.push(req._id);
  }

  const outgoingRequests = await ctx.db
    .query("link_requests")
    .withIndex("by_requester_id", (q: any) => q.eq("requester_id", account.id))
    .collect();

  for (const req of outgoingRequests) {
    await ctx.db.delete(req._id);
    deletedRequests++;
    requestIds.push(req._id);
  }
  logHardDelete(baseLog, "delete_link_requests", {
    deletedCount: deletedRequests,
    sampleIds: sampleIds(requestIds),
  });

  const invites = await ctx.db
    .query("invite_tokens")
    .withIndex("by_creator_id", (q: any) => q.eq("creator_id", account.id))
    .collect();
  const inviteIds: string[] = [];
  for (const invite of invites) {
    await ctx.db.delete(invite._id);
    inviteIds.push(invite._id);
  }
  logHardDelete(baseLog, "delete_invite_tokens", {
    deletedCount: inviteIds.length,
    sampleIds: sampleIds(inviteIds),
  });

  let aliasesDeleted = 0;
  const aliasIds: string[] = [];
  if (account.linked_member_id) {
    const aliasesAsCanonical = await ctx.db
      .query("member_aliases")
      .withIndex("by_canonical_member_id", (q: any) =>
        q.eq("canonical_member_id", account.linked_member_id!)
      )
      .collect();

    for (const alias of aliasesAsCanonical) {
      await ctx.db.delete(alias._id);
      aliasesDeleted++;
      aliasIds.push(alias._id);
    }

    const aliasesAsAlias = await ctx.db
      .query("member_aliases")
      .withIndex("by_alias_member_id", (q: any) =>
        q.eq("alias_member_id", account.linked_member_id!)
      )
      .collect();

    for (const alias of aliasesAsAlias) {
      await ctx.db.delete(alias._id);
      aliasesDeleted++;
      aliasIds.push(alias._id);
    }
  }
  logHardDelete(baseLog, "delete_member_aliases", {
    deletedCount: aliasesDeleted,
    sampleIds: sampleIds(aliasIds),
  });

  await ctx.db.delete(account._id);
  logHardDelete(baseLog, "complete", {
    friendsDeleted: friendIds.length,
    groupsDeleted: groupIds.length,
    groupExpensesDeleted: groupExpenseIds.length,
    expensesDeleted: ownedExpenseIds.length,
    unlinkedFriends: unlinkedIds.length,
    linkRequestsDeleted: deletedRequests,
    invitesDeleted: inviteIds.length,
    aliasesDeleted,
  });

  return {
    success: true,
    message: `Hard deleted account ${account.email}`,
    friendsDeleted: friendIds.length,
    groupsDeleted: groupIds.length,
    expensesDeleted: ownedExpenseIds.length + groupExpenseIds.length,
    aliasesDeleted,
  };
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
            
  // The screenshot showed duplicates of "Example Person" with "unset" linked account.
            
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

/**
 * One-time cleanup: deletes all account_friends for the given email.
 * Use from dashboard or CLI to remove ghost friends when the account already exists.
 */
export const clearFriendsForEmail = internalMutation({
  args: { email: v.string() },
  handler: async (ctx, args) => {
    const friends = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email", (q: any) => q.eq("account_email", args.email))
      .collect();
    for (const friend of friends) {
      await ctx.db.delete(friend._id);
    }
    return { deleted: friends.length, email: args.email };
  },
});

export const deleteAccountByEmail = internalMutation({
  args: { email: v.string() },
  handler: async (ctx, args) => {
    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", args.email))
      .unique();

    if (!user) {
      return { success: false, message: "User not found" };
    }

    return await performHardDelete(ctx, user, "deleteAccountByEmail");
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
        await deleteUserExpensesForExpense(ctx, expense.id);
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
          await deleteUserExpensesForExpense(ctx, expense.id);
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
            await deleteUserExpensesForExpense(ctx, expense.id);
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

    return await performHardDelete(ctx, account, "hardDeleteAccount");
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

    const myFriends = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email", (q) => q.eq("account_email", args.accountEmail))
      .collect();

    // FAN-OUT CLEANUP: Delete my user_expenses view
    const myUserExpenses = await ctx.db
      .query("user_expenses")
      .withIndex("by_user_id", (q: any) => q.eq("user_id", user.id))
      .collect();
    for (const ue of myUserExpenses) {
      await ctx.db.delete(ue._id);
    }

    for (const friend of myFriends) {
      await ctx.db.delete(friend._id);
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
