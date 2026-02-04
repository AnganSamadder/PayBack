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
    
  const existingUserIds = new Set(existingRows.map(r => r.user_id));
  const targetUserIds = new Set(participantUserIds);
  
  const toAdd = participantUserIds.filter(id => !existingUserIds.has(id));
  
  const toRemoveRows = existingRows.filter(r => !targetUserIds.has(r.user_id));
  
  await Promise.all(toAdd.map(userId => 
    ctx.db.insert("user_expenses", {
      user_id: userId,
      expense_id: expenseId,
      updated_at: Date.now(),
    })
  ));
  
  await Promise.all(toRemoveRows.map(row => 
    ctx.db.delete(row._id)
  ));
}
