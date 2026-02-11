import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import { reconcileUserExpenses } from "./helpers";
import { checkRateLimit } from "./rateLimit";
import { normalizeMemberId, normalizeMemberIds } from "./identity";
import { getAllEquivalentMemberIds } from "./aliases";

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

function isEligibleDirectFriendRecord(friend: any): boolean {
  const status = typeof friend.status === "string" ? friend.status.toLowerCase() : undefined;
  if (status === "rejected") return false;
  // Backward-compatible acceptance:
  // - explicit friend/accepted rows
  // - linked-account rows
  // - legacy rows without status
  return status === "friend" || status === "accepted" || friend.has_linked_account === true || !status;
}

function intersects(lhs: Set<string>, rhs: Set<string>): boolean {
  for (const value of lhs) {
    if (rhs.has(value)) return true;
  }
  return false;
}

export const create = mutation({
  args: {
    id: v.string(), // Client UUID
    group_id: v.string(),
    description: v.string(),
    date: v.number(),
    total_amount: v.number(),
    paid_by_member_id: v.string(),
    involved_member_ids: v.array(v.string()),
    splits: v.array(
      v.object({
        id: v.string(),
        member_id: v.string(),
        amount: v.number(),
        is_settled: v.boolean(),
      })
    ),
    is_settled: v.boolean(),
    owner_email: v.optional(v.string()), 
    owner_account_id: v.optional(v.string()), 
    participant_member_ids: v.array(v.string()),
    participants: v.array(
      v.object({
        member_id: v.string(),
        name: v.string(),
        linked_account_id: v.optional(v.string()),
        linked_account_email: v.optional(v.string()),
      })
    ),
    linked_participants: v.optional(v.any()),
    subexpenses: v.optional(v.array(
      v.object({
        id: v.string(),
        amount: v.number(),
      })
    )),
  },
  handler: async (ctx, args) => {
    const { identity, user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");

    await checkRateLimit(ctx, identity.subject, "expenses:create", 10);

    const normalizedPaidBy = normalizeMemberId(args.paid_by_member_id);
    const normalizedInvolved = normalizeMemberIds(args.involved_member_ids);
    const normalizedSplits = args.splits.map((split) => ({
      ...split,
      member_id: normalizeMemberId(split.member_id),
    }));
    const normalizedParticipantMemberIds = normalizeMemberIds(args.participant_member_ids);
    const normalizedParticipants = args.participants.map((participant) => ({
      ...participant,
      member_id: normalizeMemberId(participant.member_id),
    }));

    // Build participant_emails from linked participants
    const participantEmails: string[] = [user.email.toLowerCase()]; // Always include owner
    for (const p of normalizedParticipants) {
      if (p.linked_account_email && !participantEmails.includes(p.linked_account_email)) {
        participantEmails.push(p.linked_account_email.toLowerCase());
      }
    }

    // VALIDATION: Check Group & Friendship for Direct Expenses
    const group = await ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", args.group_id))
        .unique();

    if (!group) throw new Error("Group not found");

    if (group.is_direct) {
      const equivalentIdCache = new Map<string, Set<string>>();
      const linkedAccountCache = new Map<string, any | null>();
      const getEquivalentIdSet = async (memberId: string): Promise<Set<string>> => {
        const normalized = normalizeMemberId(memberId);
        const cached = equivalentIdCache.get(normalized);
        if (cached) return cached;

        const ids = await getAllEquivalentMemberIds(ctx.db, normalized);
        const set = new Set(ids.map((id) => normalizeMemberId(id)));
        set.add(normalized);
        equivalentIdCache.set(normalized, set);
        return set;
      };
      const getLinkedAccountForFriend = async (friend: any) => {
        const emailKey =
          typeof friend.linked_account_email === "string" &&
          friend.linked_account_email.trim().length > 0
            ? friend.linked_account_email.trim().toLowerCase()
            : undefined;
        const authKey =
          typeof friend.linked_account_id === "string" &&
          friend.linked_account_id.trim().length > 0
            ? friend.linked_account_id.trim()
            : undefined;

        const cacheKey = emailKey ? `email:${emailKey}` : authKey ? `auth:${authKey}` : undefined;
        if (!cacheKey) return null;
        if (linkedAccountCache.has(cacheKey)) {
          return linkedAccountCache.get(cacheKey) ?? null;
        }

        let linkedAccount = null;
        if (emailKey) {
          linkedAccount = await ctx.db
            .query("accounts")
            .withIndex("by_email", (q) => q.eq("email", emailKey))
            .unique();
        }
        if (!linkedAccount && authKey) {
          linkedAccount = await ctx.db
            .query("accounts")
            .withIndex("by_auth_id", (q) => q.eq("id", authKey))
            .unique();
        }

        linkedAccountCache.set(cacheKey, linkedAccount ?? null);
        return linkedAccount;
      };

      const currentUserEquivalentIds = new Set<string>();
      for (const selfId of [user.member_id, user.id]) {
        if (!selfId) continue;
        const selfEquivalentIds = await getEquivalentIdSet(selfId);
        for (const id of selfEquivalentIds) {
          currentUserEquivalentIds.add(id);
        }
      }

      const ownerFriendRows = await ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (q) => q.eq("account_email", user.email))
        .collect();

      const ownerFriendIdentityRows = [];
      for (const friend of ownerFriendRows) {
        const identityIds = new Set<string>();
        const friendIdentitySeeds = [friend.member_id, friend.linked_member_id].filter(
          (value): value is string => typeof value === "string" && value.length > 0
        );

        for (const seedId of friendIdentitySeeds) {
          const equivalentIds = await getEquivalentIdSet(seedId);
          for (const id of equivalentIds) {
            identityIds.add(id);
          }
        }
        const linkedAccount = await getLinkedAccountForFriend(friend);
        const linkedAccountSeeds = [
          linkedAccount?.member_id,
          ...(linkedAccount?.alias_member_ids || []),
        ].filter((value): value is string => typeof value === "string" && value.length > 0);
        for (const seedId of linkedAccountSeeds) {
          const equivalentIds = await getEquivalentIdSet(seedId);
          for (const id of equivalentIds) {
            identityIds.add(id);
          }
        }

        ownerFriendIdentityRows.push({ friend, identityIds });
      }

      for (const memberId of normalizedInvolved) {
        // Check if this member is the current user (group marker or equivalent ID).
        const groupMember = group.members.find((m) => normalizeMemberId(m.id) === memberId);
        if (groupMember?.is_current_user) {
          continue;
        }

        const memberEquivalentIds = await getEquivalentIdSet(memberId);
        if (intersects(memberEquivalentIds, currentUserEquivalentIds)) {
          continue;
        }

        // Must resolve to an existing friend identity (member_id, linked_member_id, or aliases).
        const matchingFriend = ownerFriendIdentityRows.find(
          ({ friend, identityIds }) =>
            isEligibleDirectFriendRecord(friend) &&
            intersects(identityIds, memberEquivalentIds)
        );

        if (!matchingFriend) {
          throw new Error(
            `Cannot create direct expense: Member ${groupMember?.name ?? memberId} is not a confirmed friend.`
          );
        }
      }
    }

    // Deduplication check: Check if expense with this ID already exists
    const existing = await ctx.db
      .query("expenses")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    if (existing) {
      // Update existing record
        await ctx.db.patch(existing._id, {
        description: args.description,
        date: args.date,
        total_amount: args.total_amount,
        paid_by_member_id: normalizedPaidBy,
        involved_member_ids: normalizedInvolved,
        splits: normalizedSplits,
        is_settled: args.is_settled,
        owner_id: user._id,
        group_ref: group._id,
        participants: normalizedParticipants,
        participant_member_ids: normalizedParticipantMemberIds,
        participant_emails: participantEmails,
        subexpenses: args.subexpenses,
        updated_at: Date.now(),
      });

      const participantUsers = await Promise.all(participantEmails.map(email => 
        ctx.db.query("accounts").withIndex("by_email", q => q.eq("email", email)).unique()
      ));
      const participantUserIds = participantUsers.filter(u => u !== null).map(u => u!.id);
      await reconcileUserExpenses(ctx, args.id, participantUserIds);

      return existing._id;
    }

    const expenseId = await ctx.db.insert("expenses", {
      id: args.id,
      group_id: args.group_id,
      group_ref: group._id,
      description: args.description,
      date: args.date,
      total_amount: args.total_amount,
      paid_by_member_id: normalizedPaidBy,
      involved_member_ids: normalizedInvolved,
      splits: normalizedSplits,
      is_settled: args.is_settled,
      owner_email: user.email,
      owner_account_id: user.id,
      owner_id: user._id,
      participant_member_ids: normalizedParticipantMemberIds,
      participants: normalizedParticipants,
      participant_emails: participantEmails,
      linked_participants: args.linked_participants,
      subexpenses: args.subexpenses,
      created_at: Date.now(),
      updated_at: Date.now(),
    });

    const participantUsers = await Promise.all(participantEmails.map(email => 
      ctx.db.query("accounts").withIndex("by_email", q => q.eq("email", email)).unique()
    ));
    const participantUserIds = participantUsers.filter(u => u !== null).map(u => u!.id);
    await reconcileUserExpenses(ctx, args.id, participantUserIds);
    
    return expenseId;
  },
});

export const listByGroup = query({
  args: { group_id: v.string() },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUser(ctx);
    if (!user) return [];

    const expenses = await ctx.db
        .query("expenses")
        .withIndex("by_group_id", q => q.eq("group_id", args.group_id))
        .collect();
        
    return expenses;
  },
});

export const listByGroupPaginated = query({
  args: {
    groupId: v.id("groups"),
    cursor: v.optional(v.string()),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUser(ctx);
    if (!user) {
      return { items: [], nextCursor: null };
    }

    const result = await ctx.db
      .query("expenses")
      .withIndex("by_group_ref", (q) => q.eq("group_ref", args.groupId))
      .order("desc")
      .paginate({
        cursor: args.cursor ?? null,
        numItems: args.limit ?? 50,
      });

    return {
      items: result.page,
      nextCursor: result.isDone ? null : result.continueCursor,
    };
  },
});

export const list = query({
  args: {},
  handler: async (ctx) => {
    const { user } = await getCurrentUser(ctx);
    if (!user) return [];

    const userExpenses = await ctx.db
      .query("user_expenses")
      .withIndex("by_user_id_and_updated_at", q => q.eq("user_id", user.id))
      .order("desc")
      .collect();

    const expenses = await Promise.all(userExpenses.map(async (ue) => {
      return await ctx.db
        .query("expenses")
        .withIndex("by_client_id", q => q.eq("id", ue.expense_id))
        .unique();
    }));

    return expenses.filter(e => e !== null);
  },
});

// Delete a single expense by client UUID
export const deleteExpense = mutation({
    args: { id: v.string() },
    handler: async (ctx, args) => {
        const { user } = await getCurrentUser(ctx);
        if (!user) throw new Error("User not found");
        
        const expense = await ctx.db
            .query("expenses")
            .withIndex("by_client_id", (q) => q.eq("id", args.id))
            .unique();
            
        if (!expense) return;
        
        // Auth check - only owner can delete
        if (expense.owner_id !== user._id && expense.owner_email !== user.email) {
            throw new Error("Not authorized to delete this expense");
        }
        
        await reconcileUserExpenses(ctx, args.id, []);
        await ctx.db.delete(expense._id);
    }
});

// Delete multiple expenses by client UUIDs
export const deleteExpenses = mutation({
    args: { ids: v.array(v.string()) },
    handler: async (ctx, args) => {
        const { user } = await getCurrentUser(ctx);
        if (!user) throw new Error("User not found");
        
        for (const id of args.ids) {
            const expense = await ctx.db
                .query("expenses")
                .withIndex("by_client_id", (q) => q.eq("id", id))
                .unique();
                
            if (!expense) continue;
            
            // Auth check - only owner can delete
            if (expense.owner_id !== user._id && expense.owner_email !== user.email) {
                continue;
            }
            
            await reconcileUserExpenses(ctx, id, []);
            await ctx.db.delete(expense._id);
        }
    }
});

// Clear ALL expenses for the current user
export const clearAllForUser = mutation({
    args: {},
    handler: async (ctx) => {
        const { user } = await getCurrentUser(ctx);
        if (!user) throw new Error("User not found");
        
        // Get all expenses owned by this user
        const ownedExpenses = await ctx.db
            .query("expenses")
            .withIndex("by_owner_id", (q) => q.eq("owner_id", user._id))
            .collect();
            
        const byEmail = await ctx.db
            .query("expenses")
            .withIndex("by_owner_email", (q) => q.eq("owner_email", user.email))
            .collect();
            
        // Merge and dedupe by client UUID so we can reconcile user_expenses correctly.
        const ownedExpenseByClientId = new Map<string, any>();
        ownedExpenses.forEach((expense) => ownedExpenseByClientId.set(expense.id, expense));
        byEmail.forEach((expense) => ownedExpenseByClientId.set(expense.id, expense));

        // Delete all owned expenses and fully reconcile fan-out rows.
        for (const expense of ownedExpenseByClientId.values()) {
            await reconcileUserExpenses(ctx, expense.id, []);
            await ctx.db.delete(expense._id);
        }

        // Also remove this user from user_expenses visibility rows for shared expenses.
        const viewerExpenseRows = await ctx.db
          .query("user_expenses")
          .withIndex("by_user_id", (q) => q.eq("user_id", user.id))
          .collect();
        for (const row of viewerExpenseRows) {
          await ctx.db.delete(row._id);
        }

        return {
          deleted_owned_expenses: ownedExpenseByClientId.size,
          removed_viewer_visibility_rows: viewerExpenseRows.length,
        };
    }
});
