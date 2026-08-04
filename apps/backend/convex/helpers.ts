import { MutationCtx, QueryCtx } from "./_generated/server";
import { Doc } from "./_generated/dataModel";
import { ConvexError } from "convex/values";
import { findAccountByAuthIdOrDocId, findAccountByMemberId, normalizeMemberId } from "./identity";

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

export type ExpenseVisibilitySource = Pick<
  Doc<"expenses">,
  | "id"
  | "owner_id"
  | "owner_account_id"
  | "owner_email"
  | "participant_emails"
  | "paid_by_member_id"
  | "participant_member_ids"
  | "inactive_participant_member_ids"
  | "involved_member_ids"
  | "participants"
  | "splits"
>;

type ExpenseOwnerSource = Pick<Doc<"expenses">, "owner_id" | "owner_account_id" | "owner_email">;

const ownerIdentityMaintenanceError = () =>
  new ConvexError({
    code: "IDENTITY_MAINTENANCE_REQUIRED",
    message: "Expense owner identity is inconsistent"
  });

export async function resolveAuthoritativeExpenseOwnerAccount(
  ctx: MutationCtx,
  expense: ExpenseOwnerSource
): Promise<Doc<"accounts"> | null> {
  const resolvedAccounts = new Map<string, Doc<"accounts">>();
  const addResolvedAccount = (account: Doc<"accounts"> | null) => {
    if (account) resolvedAccounts.set(account.id, account);
  };

  if (expense.owner_id) addResolvedAccount(await ctx.db.get(expense.owner_id));
  if (expense.owner_account_id?.trim()) {
    addResolvedAccount(await findAccountByAuthIdOrDocId(ctx.db, expense.owner_account_id.trim()));
  }
  if (expense.owner_email?.trim()) {
    addResolvedAccount(
      await ctx.db
        .query("accounts")
        .withIndex("by_email", (q) => q.eq("email", expense.owner_email.trim().toLowerCase()))
        .unique()
    );
  }

  if (resolvedAccounts.size > 1) throw ownerIdentityMaintenanceError();
  const ownerAccount = resolvedAccounts.values().next().value ?? null;
  if (!ownerAccount) return null;

  const ownerIdConflicts =
    expense.owner_id !== undefined && String(expense.owner_id) !== String(ownerAccount._id);
  const ownerAccountId = expense.owner_account_id?.trim();
  const ownerAccountIdConflicts =
    Boolean(ownerAccountId) &&
    ownerAccountId !== ownerAccount.id &&
    ownerAccountId !== String(ownerAccount._id);
  const ownerEmailConflicts =
    Boolean(expense.owner_email?.trim()) &&
    expense.owner_email.trim().toLowerCase() !== ownerAccount.email.trim().toLowerCase();
  if (ownerIdConflicts || ownerAccountIdConflicts || ownerEmailConflicts) {
    throw ownerIdentityMaintenanceError();
  }
  return ownerAccount;
}

export function collectActiveExpenseMemberIds(
  expense: ExpenseVisibilitySource,
  excludedMemberIds: ReadonlySet<string> = new Set()
): string[] {
  const inactiveMemberIds = new Set([
    ...(expense.inactive_participant_member_ids ?? []).map(normalizeMemberId),
    ...Array.from(excludedMemberIds, normalizeMemberId)
  ]);
  const candidateMemberIds = [
    expense.paid_by_member_id,
    ...expense.participant_member_ids,
    ...expense.involved_member_ids,
    ...expense.participants.map((participant) => participant.member_id),
    ...expense.splits.map((split) => split.member_id)
  ];
  return Array.from(
    new Set(
      candidateMemberIds
        .map(normalizeMemberId)
        .filter((memberId) => memberId.length > 0 && !inactiveMemberIds.has(memberId))
    )
  );
}

export async function resolveActiveExpenseParticipantAccounts(
  ctx: MutationCtx,
  expense: ExpenseVisibilitySource,
  excludedAccountIds: ReadonlySet<string> = new Set()
): Promise<Doc<"accounts">[]> {
  const accounts = new Map<string, Doc<"accounts">>();
  const inactiveMemberIds = new Set(
    (expense.inactive_participant_member_ids ?? []).map(normalizeMemberId)
  );
  const inactiveAccountIds = new Set<string>();
  for (const memberId of inactiveMemberIds) {
    const account = await findAccountByMemberId(ctx.db, memberId);
    if (account) inactiveAccountIds.add(account.id);
  }
  for (const participant of expense.participants) {
    if (!inactiveMemberIds.has(normalizeMemberId(participant.member_id))) continue;

    if (participant.linked_account_id?.trim()) {
      const account = await findAccountByAuthIdOrDocId(ctx.db, participant.linked_account_id);
      if (account) inactiveAccountIds.add(account.id);
    }
    if (participant.linked_account_email?.trim()) {
      const email = participant.linked_account_email.trim().toLowerCase();
      const account = await ctx.db
        .query("accounts")
        .withIndex("by_email", (q) => q.eq("email", email))
        .unique();
      if (account) inactiveAccountIds.add(account.id);
    }
  }

  const addAccount = (account: Doc<"accounts"> | null) => {
    if (account && account.status !== "deleted" && excludedAccountIds.has(account.id) === false) {
      accounts.set(account.id, account);
      return account;
    }
    return null;
  };

  const ownerAccountIds = new Set<string>();
  const ownerAccount = addAccount(await resolveAuthoritativeExpenseOwnerAccount(ctx, expense));
  if (ownerAccount) ownerAccountIds.add(ownerAccount.id);

  const activeMemberAccountIds = new Set<string>();
  const memberIds = collectActiveExpenseMemberIds(expense);
  for (const memberId of memberIds) {
    const account = addAccount(await findAccountByMemberId(ctx.db, memberId));
    if (account) activeMemberAccountIds.add(account.id);
  }

  for (const participant of expense.participants) {
    if (inactiveMemberIds.has(normalizeMemberId(participant.member_id))) continue;

    if (participant.linked_account_id?.trim()) {
      const account = addAccount(
        await findAccountByAuthIdOrDocId(ctx.db, participant.linked_account_id)
      );
      if (account) activeMemberAccountIds.add(account.id);
    }
    if (participant.linked_account_email?.trim()) {
      const email = participant.linked_account_email.trim().toLowerCase();
      const account = addAccount(
        await ctx.db
          .query("accounts")
          .withIndex("by_email", (q) => q.eq("email", email))
          .unique()
      );
      if (account) activeMemberAccountIds.add(account.id);
    }
  }

  const participantEmails = new Set(
    (expense.participant_emails ?? [])
      .filter((email): email is string => Boolean(email?.trim()))
      .map((email) => email.trim().toLowerCase())
  );
  for (const email of participantEmails) {
    const account = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", email))
      .unique();
    if (
      account &&
      inactiveAccountIds.has(account.id) &&
      !ownerAccountIds.has(account.id) &&
      !activeMemberAccountIds.has(account.id)
    ) {
      continue;
    }
    addAccount(account);
  }

  return Array.from(accounts.values());
}

export async function resolveActiveExpenseParticipantUserIds(
  ctx: MutationCtx,
  expense: ExpenseVisibilitySource,
  excludedAccountIds: ReadonlySet<string> = new Set()
): Promise<string[]> {
  const accounts = await resolveActiveExpenseParticipantAccounts(ctx, expense, excludedAccountIds);
  return accounts.map((account) => account.id);
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
