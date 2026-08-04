import { MutationCtx, QueryCtx } from "./_generated/server";
import { Doc } from "./_generated/dataModel";
import { findAccountByAuthIdOrDocId, findAccountByMemberId } from "./identity";

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

type ExpenseVisibilitySource = Pick<
  Doc<"expenses">,
  | "id"
  | "owner_id"
  | "owner_account_id"
  | "owner_email"
  | "participant_emails"
  | "participant_member_ids"
  | "involved_member_ids"
  | "participants"
  | "splits"
>;

export async function resolveActiveExpenseParticipantUserIds(
  ctx: MutationCtx,
  expense: ExpenseVisibilitySource,
  excludedAccountIds: ReadonlySet<string> = new Set()
): Promise<string[]> {
  const accounts = new Map<string, Doc<"accounts">>();

  const addAccount = (account: Doc<"accounts"> | null) => {
    if (account && account.status !== "deleted" && excludedAccountIds.has(account.id) === false) {
      accounts.set(account.id, account);
    }
  };

  if (expense.owner_id) {
    addAccount(await ctx.db.get(expense.owner_id));
  }
  if (expense.owner_account_id) {
    addAccount(await findAccountByAuthIdOrDocId(ctx.db, expense.owner_account_id));
  }

  const emails = new Set(
    [expense.owner_email, ...(expense.participant_emails ?? [])]
      .filter((email): email is string => Boolean(email?.trim()))
      .map((email) => email.trim().toLowerCase())
  );
  for (const participant of expense.participants) {
    if (participant.linked_account_email?.trim()) {
      emails.add(participant.linked_account_email.trim().toLowerCase());
    }
    if (participant.linked_account_id?.trim()) {
      addAccount(await findAccountByAuthIdOrDocId(ctx.db, participant.linked_account_id));
    }
  }
  for (const email of emails) {
    addAccount(
      await ctx.db
        .query("accounts")
        .withIndex("by_email", (q) => q.eq("email", email))
        .unique()
    );
  }

  const memberIds = new Set([
    ...expense.participant_member_ids,
    ...expense.involved_member_ids,
    ...expense.participants.map((participant) => participant.member_id),
    ...expense.splits.map((split) => split.member_id)
  ]);
  for (const memberId of memberIds) {
    addAccount(await findAccountByMemberId(ctx.db, memberId));
  }

  return Array.from(accounts.keys());
}

export async function reconcileExpenseVisibility(
  ctx: MutationCtx,
  expense: ExpenseVisibilitySource,
  excludedAccountIds: ReadonlySet<string> = new Set()
) {
  const participantUserIds = await resolveActiveExpenseParticipantUserIds(
    ctx,
    expense,
    excludedAccountIds
  );
  await reconcileUserExpenses(ctx, expense.id, participantUserIds);
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
