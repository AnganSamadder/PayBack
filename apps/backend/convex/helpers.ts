import { MutationCtx, QueryCtx } from "./_generated/server";

export async function getCurrentUserOrThrow(ctx: QueryCtx | MutationCtx) {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) {
    throw new Error("Unauthenticated");
  }
  const user = await ctx.db
    .query("accounts")
    .withIndex("by_email", (q) => q.eq("email", identity.email!))
    .unique();

  if (!user) {
    throw new Error("User not found");
  }

  return { user, identity };
}

/**
 * Reconciles the `user_expenses` table for a given expense and its participants.
 * This ensures that every user who should see this expense has a corresponding
 * `user_expenses` row, and those who shouldn't have it removed.
 */
export async function reconcileUserExpenses(
  ctx: MutationCtx,
  expenseId: string,
  participantUserIds: string[]
) {
  const existingRows = await ctx.db
    .query("user_expenses")
    .withIndex("by_expense_id", (q) => q.eq("expense_id", expenseId))
    .collect();

  const existingUserIds = new Set(existingRows.map((r) => r.user_id));
  const targetUserIds = new Set(participantUserIds);

  const toAdd = participantUserIds.filter((id) => !existingUserIds.has(id));

  const toRemoveRows = existingRows.filter((r) => !targetUserIds.has(r.user_id));

  await Promise.all(
    toAdd.map((userId) =>
      ctx.db.insert("user_expenses", {
        user_id: userId,
        expense_id: expenseId,
        updated_at: Date.now()
      })
    )
  );

  await Promise.all(toRemoveRows.map((row) => ctx.db.delete(row._id)));
}

/**
 * Finds all expenses owned by the current user that involve a specific member ID,
 * and ensures the target user ID has visibility (user_expenses row) for them.
 */
export async function reconcileExpensesForMember(
  ctx: MutationCtx,
  ownerEmail: string,
  memberId: string,
  targetUserId: string
) {
  const expenses = await ctx.db
    .query("expenses")
    .withIndex("by_owner_email", (q) => q.eq("owner_email", ownerEmail))
    .collect();

  const relevantExpenses = expenses.filter(
    (e) => e.involved_member_ids.includes(memberId) || e.paid_by_member_id === memberId
  );

  await Promise.all(
    relevantExpenses.map(async (expense) => {
      const userExpenses = await ctx.db
        .query("user_expenses")
        .withIndex("by_expense_id", (q) => q.eq("expense_id", expense.id))
        .filter((q) => q.eq(q.field("user_id"), targetUserId))
        .first();

      if (!userExpenses) {
        await ctx.db.insert("user_expenses", {
          user_id: targetUserId,
          expense_id: expense.id,
          updated_at: Date.now()
        });
      }
    })
  );
}
