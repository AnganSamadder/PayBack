import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import { reconcileUserExpenses } from "./helpers";

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
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");

    // Build participant_emails from linked participants
    const participantEmails: string[] = [user.email]; // Always include owner
    for (const p of args.participants) {
      if (p.linked_account_email && !participantEmails.includes(p.linked_account_email)) {
        participantEmails.push(p.linked_account_email);
      }
    }

    // VALIDATION: Check Group & Friendship for Direct Expenses
    const group = await ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", args.group_id))
        .unique();

    if (!group) throw new Error("Group not found");

    if (group.is_direct) {
        for (const memberId of args.involved_member_ids) {
            // Check if this member is the current user (based on group definition)
            const groupMember = group.members.find(m => m.id === memberId);
            if (groupMember?.is_current_user) {
                continue; // It's me, skip
            }

            // Must be a confirmed friend
            const friend = await ctx.db
                .query("account_friends")
                .withIndex("by_account_email_and_member_id", (q) => 
                    q.eq("account_email", user.email).eq("member_id", memberId)
                )
                .unique();

            if (!friend || friend.status !== "friend") {
                throw new Error(`Cannot create direct expense: Member ${groupMember?.name ?? memberId} is not a confirmed friend.`);
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
        paid_by_member_id: args.paid_by_member_id,
        involved_member_ids: args.involved_member_ids,
        splits: args.splits,
        is_settled: args.is_settled,
        participants: args.participants,
        participant_member_ids: args.participant_member_ids,
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
      description: args.description,
      date: args.date,
      total_amount: args.total_amount,
      paid_by_member_id: args.paid_by_member_id,
      involved_member_ids: args.involved_member_ids,
      splits: args.splits,
      is_settled: args.is_settled,
      owner_email: user.email,
      owner_account_id: user.id,
      participant_member_ids: args.participant_member_ids,
      participants: args.participants,
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
        if (expense.owner_account_id !== user.id && expense.owner_email !== user.email) {
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
            if (expense.owner_account_id !== user.id && expense.owner_email !== user.email) {
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
            .withIndex("by_owner_account_id", (q) => q.eq("owner_account_id", user.id))
            .collect();
            
        const byEmail = await ctx.db
            .query("expenses")
            .withIndex("by_owner_email", (q) => q.eq("owner_email", user.email))
            .collect();
            
        // Merge and dedupe
        const allExpenseIds = new Set<string>();
        ownedExpenses.forEach(e => { allExpenseIds.add(e._id); });
        byEmail.forEach(e => { allExpenseIds.add(e._id); });
        
        // Delete all
        for (const _id of allExpenseIds) {
            await ctx.db.delete(_id as any);
        }
        
        return null;
    }
});
