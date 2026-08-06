import { MutationCtx, QueryCtx } from "./_generated/server";
import { Doc, Id } from "./_generated/dataModel";
import { ConvexError } from "convex/values";
import { findAccountByAuthIdOrDocId, findAccountByMemberId, normalizeMemberId } from "./identity";
import {
  applyExpenseWriteBatch,
  type ExpenseWriteOperation,
  MAX_EXPENSE_VIEWERS,
  MAX_EXPENSE_WRITE_OPERATIONS
} from "./expenseWrites";

export async function resolveAuthenticatedAccount(ctx: QueryCtx | MutationCtx) {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) {
    throw new Error("Unauthenticated");
  }
  const users = await ctx.db
    .query("accounts")
    .withIndex("by_auth_id", (q) => q.eq("id", identity.subject))
    .take(2);

  if (users.length > 1) throw new Error("Authenticated account identity is ambiguous");
  const user = users[0];
  const identityEmail = identity.email?.trim().toLowerCase();
  if (!identityEmail || (user && user.email.trim().toLowerCase() !== identityEmail)) {
    throw new Error("Authenticated identity does not match the account email");
  }
  return { user: user ?? null, identity };
}

export async function getCurrentUserOrThrow(ctx: QueryCtx | MutationCtx) {
  const { user, identity } = await resolveAuthenticatedAccount(ctx);
  if (!user) throw new Error("User not found");
  assertAccountCanAcceptChanges(user);

  return { user, identity };
}

export function assertAccountCanAcceptChanges(account: { status?: string } | null | undefined) {
  if (account?.status === "deleting") {
    throw new Error("Account is being deleted and cannot accept new changes");
  }
  if (account?.status === "deleted") {
    throw new Error("Account has been deleted and cannot accept new changes");
  }
}

export function isAccountDeletionFenced(account: { status?: string } | null | undefined): boolean {
  return account?.status === "deleting" || account?.status === "deleted";
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
  if (participantUserIds.length > MAX_EXPENSE_VIEWERS) {
    throw new Error(`Expense visibility supports at most ${MAX_EXPENSE_VIEWERS} viewers`);
  }
  const uniqueUserIds = Array.from(new Set(participantUserIds));
  if (uniqueUserIds.length > MAX_EXPENSE_VIEWERS) {
    throw new Error(`Expense visibility supports at most ${MAX_EXPENSE_VIEWERS} viewers`);
  }
  const expenseMatches = await ctx.db
    .query("expenses")
    .withIndex("by_client_id", (query) => query.eq("id", expenseId))
    .take(2);
  if (expenseMatches.length > 1) throw new Error(`Expense ${expenseId} is not unique`);
  const expense = expenseMatches[0];
  if (!expense) throw new Error(`Expense ${expenseId} not found`);

  const viewerAccountIds: Id<"accounts">[] = [];
  for (const userId of uniqueUserIds) {
    const accounts = await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (query) => query.eq("id", userId))
      .take(2);
    if (accounts.length > 1) throw new Error(`Account auth ID ${userId} is not unique`);
    const account = accounts[0];
    if (isActiveAccount(account ?? null)) viewerAccountIds.push(account._id);
  }
  await applyExpenseWriteBatch(ctx, [{ kind: "visibility", expense, viewerAccountIds }]);
}

export type ExpenseVisibilitySource = Pick<
  Doc<"expenses">,
  | "id"
  | "owner_id"
  | "owner_account_id"
  | "owner_email"
  | "paid_by_member_id"
  | "participant_emails"
  | "participant_member_ids"
  | "inactive_participant_member_ids"
  | "involved_member_ids"
  | "participants"
  | "splits"
>;

type ExpenseParticipant = Doc<"expenses">["participants"][number];

export type ExpenseIdentityResolutionCache = {
  memberAccounts: Map<string, Promise<Doc<"accounts"> | null>>;
  linkedIdAccounts: Map<string, Promise<Doc<"accounts"> | null>>;
  emailAccounts: Map<string, Promise<Doc<"accounts"> | null>>;
};

export function createExpenseIdentityResolutionCache(): ExpenseIdentityResolutionCache {
  return {
    memberAccounts: new Map(),
    linkedIdAccounts: new Map(),
    emailAccounts: new Map()
  };
}

function cachedAccountResolution(
  cache: Map<string, Promise<Doc<"accounts"> | null>> | undefined,
  key: string,
  resolve: () => Promise<Doc<"accounts"> | null>
) {
  if (!cache) return resolve();
  const existing = cache.get(key);
  if (existing) return existing;
  const pending = resolve();
  cache.set(key, pending);
  return pending;
}

function isActiveAccount(account: Doc<"accounts"> | null): account is Doc<"accounts"> {
  return account !== null && account.status !== "deleting" && account.status !== "deleted";
}

function assertExpenseVisibilitySourceBounded(expense: ExpenseVisibilitySource): void {
  const candidateMemberIds = collectActiveExpenseMemberIds(expense);
  const participantEmails = new Set(
    (expense.participant_emails ?? [])
      .filter((email): email is string => Boolean(email?.trim()))
      .map((email) => email.trim().toLowerCase())
  );
  if (
    expense.involved_member_ids.length > MAX_EXPENSE_VIEWERS ||
    expense.participant_member_ids.length > MAX_EXPENSE_VIEWERS ||
    expense.participants.length > MAX_EXPENSE_VIEWERS ||
    expense.splits.length > MAX_EXPENSE_VIEWERS ||
    (expense.inactive_participant_member_ids?.length ?? 0) > MAX_EXPENSE_VIEWERS ||
    (expense.participant_emails?.length ?? 0) > MAX_EXPENSE_VIEWERS ||
    candidateMemberIds.length > MAX_EXPENSE_VIEWERS ||
    participantEmails.size > MAX_EXPENSE_VIEWERS
  ) {
    throw new Error(`Expense visibility supports at most ${MAX_EXPENSE_VIEWERS} participants`);
  }
}

type ExpenseOwnerSource = Pick<Doc<"expenses">, "owner_id" | "owner_account_id" | "owner_email">;

const ownerIdentityMaintenanceError = () =>
  new ConvexError({
    code: "IDENTITY_MAINTENANCE_REQUIRED",
    message: "Expense owner identity is inconsistent"
  });

export async function resolveAuthoritativeExpenseOwnerAccount(
  ctx: MutationCtx,
  expense: ExpenseOwnerSource,
  cache?: ExpenseIdentityResolutionCache
): Promise<Doc<"accounts"> | null> {
  const resolvedAccounts = new Map<string, Doc<"accounts">>();
  const addResolvedAccount = (account: Doc<"accounts"> | null) => {
    if (account) resolvedAccounts.set(account.id, account);
  };

  if (expense.owner_id) addResolvedAccount(await ctx.db.get(expense.owner_id));
  if (expense.owner_account_id?.trim()) {
    const ownerAccountId = expense.owner_account_id.trim();
    addResolvedAccount(
      await cachedAccountResolution(cache?.linkedIdAccounts, ownerAccountId, () =>
        findAccountByAuthIdOrDocId(ctx.db, ownerAccountId)
      )
    );
  }
  if (expense.owner_email?.trim()) {
    const ownerEmail = expense.owner_email.trim().toLowerCase();
    addResolvedAccount(
      await cachedAccountResolution(cache?.emailAccounts, ownerEmail, () =>
        ctx.db
          .query("accounts")
          .withIndex("by_email", (q) => q.eq("email", ownerEmail))
          .unique()
      )
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

export async function resolveConsistentExpenseParticipantAccount(
  ctx: MutationCtx,
  participant: ExpenseParticipant,
  cache?: ExpenseIdentityResolutionCache
): Promise<Doc<"accounts"> | null> {
  const normalizedMemberId = normalizeMemberId(participant.member_id);
  const linkedAccountId = participant.linked_account_id?.trim();
  const linkedAccountEmail = participant.linked_account_email?.trim().toLowerCase();
  const [memberAccount, linkedIdAccount, linkedEmailAccount] = await Promise.all([
    cachedAccountResolution(cache?.memberAccounts, normalizedMemberId, () =>
      findAccountByMemberId(ctx.db, normalizedMemberId)
    ),
    linkedAccountId
      ? cachedAccountResolution(cache?.linkedIdAccounts, linkedAccountId, () =>
          findAccountByAuthIdOrDocId(ctx.db, linkedAccountId)
        )
      : null,
    linkedAccountEmail
      ? cachedAccountResolution(cache?.emailAccounts, linkedAccountEmail, () =>
          ctx.db
            .query("accounts")
            .withIndex("by_email", (q) => q.eq("email", linkedAccountEmail))
            .unique()
        )
      : null
  ]);

  if (memberAccount !== null) {
    return isActiveAccount(memberAccount) ? memberAccount : null;
  }

  if (linkedAccountId && !isActiveAccount(linkedIdAccount)) {
    return null;
  }
  if (linkedAccountEmail && !isActiveAccount(linkedEmailAccount)) {
    return null;
  }

  const linkedAccounts = [linkedIdAccount, linkedEmailAccount].filter(isActiveAccount);
  if (linkedAccounts.length === 0) {
    return null;
  }
  const provenAccount = linkedAccounts[0];
  return linkedAccounts.every((account) => account.id === provenAccount.id) ? provenAccount : null;
}

export async function canonicalizeExpenseParticipantLinks(
  ctx: MutationCtx,
  participants: ExpenseParticipant[],
  cache?: ExpenseIdentityResolutionCache
): Promise<ExpenseParticipant[]> {
  return await Promise.all(
    participants.map(async (participant) => {
      const account = await resolveConsistentExpenseParticipantAccount(ctx, participant, cache);
      const canonicalParticipant: ExpenseParticipant = {
        member_id: participant.member_id,
        name: participant.name
      };
      if (!account) {
        return canonicalParticipant;
      }
      return {
        ...canonicalParticipant,
        linked_account_id: account.id,
        linked_account_email: account.email.trim().toLowerCase()
      };
    })
  );
}

export async function resolveActiveExpenseParticipantAccounts(
  ctx: MutationCtx,
  expense: ExpenseVisibilitySource,
  excludedAccountIds: ReadonlySet<string> = new Set(),
  cache?: ExpenseIdentityResolutionCache
): Promise<Doc<"accounts">[]> {
  assertExpenseVisibilitySourceBounded(expense);
  const accounts = new Map<string, Doc<"accounts">>();
  const inactiveMemberIds = new Set(
    (expense.inactive_participant_member_ids ?? []).map(normalizeMemberId)
  );
  const inactiveAccountIds = new Set<string>();
  for (const memberId of inactiveMemberIds) {
    const account = await cachedAccountResolution(cache?.memberAccounts, memberId, () =>
      findAccountByMemberId(ctx.db, memberId)
    );
    if (account) inactiveAccountIds.add(account.id);
  }
  for (const participant of expense.participants) {
    if (!inactiveMemberIds.has(normalizeMemberId(participant.member_id))) continue;

    if (participant.linked_account_id?.trim()) {
      const linkedAccountId = participant.linked_account_id.trim();
      const account = await cachedAccountResolution(cache?.linkedIdAccounts, linkedAccountId, () =>
        findAccountByAuthIdOrDocId(ctx.db, linkedAccountId)
      );
      if (account) inactiveAccountIds.add(account.id);
    }
    if (participant.linked_account_email?.trim()) {
      const email = participant.linked_account_email.trim().toLowerCase();
      const account = await cachedAccountResolution(cache?.emailAccounts, email, () =>
        ctx.db
          .query("accounts")
          .withIndex("by_email", (q) => q.eq("email", email))
          .unique()
      );
      if (account) inactiveAccountIds.add(account.id);
    }
  }

  const addAccount = (account: Doc<"accounts"> | null) => {
    if (isActiveAccount(account) && excludedAccountIds.has(account.id) === false) {
      accounts.set(account.id, account);
      return account;
    }
    return null;
  };

  const ownerAccountIds = new Set<string>();
  const ownerAccount = addAccount(
    await resolveAuthoritativeExpenseOwnerAccount(ctx, expense, cache)
  );
  if (ownerAccount) ownerAccountIds.add(ownerAccount.id);

  const activeMemberAccountIds = new Set<string>();
  const memberIds = collectActiveExpenseMemberIds(expense);
  for (const memberId of memberIds) {
    const account = addAccount(
      await cachedAccountResolution(cache?.memberAccounts, memberId, () =>
        findAccountByMemberId(ctx.db, memberId)
      )
    );
    if (account) activeMemberAccountIds.add(account.id);
  }

  for (const participant of expense.participants) {
    if (inactiveMemberIds.has(normalizeMemberId(participant.member_id))) continue;
    const account = addAccount(
      await resolveConsistentExpenseParticipantAccount(ctx, participant, cache)
    );
    if (account) activeMemberAccountIds.add(account.id);
  }

  const participantEmails = new Set(
    (expense.participant_emails ?? [])
      .filter((email): email is string => Boolean(email?.trim()))
      .map((email) => email.trim().toLowerCase())
  );
  for (const email of participantEmails) {
    const account = await cachedAccountResolution(cache?.emailAccounts, email, () =>
      ctx.db
        .query("accounts")
        .withIndex("by_email", (q) => q.eq("email", email))
        .unique()
    );
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
  const accounts = await resolveActiveExpenseParticipantAccounts(ctx, expense, excludedAccountIds);
  const matches = await ctx.db
    .query("expenses")
    .withIndex("by_client_id", (query) => query.eq("id", expense.id))
    .take(2);
  if (matches.length > 1) throw new Error(`Expense ${expense.id} is not unique`);
  const storedExpense = matches[0];
  if (!storedExpense) throw new Error(`Expense ${expense.id} not found`);
  await applyExpenseWriteBatch(ctx, [
    {
      kind: "visibility",
      expense: storedExpense,
      viewerAccountIds: accounts.map((account) => account._id)
    }
  ]);
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
  const targetAccounts = await ctx.db
    .query("accounts")
    .withIndex("by_auth_id", (query) => query.eq("id", targetUserId))
    .take(2);
  if (targetAccounts.length > 1) throw new Error(`Account auth ID ${targetUserId} is not unique`);
  const targetAccount = targetAccounts[0];
  if (!isActiveAccount(targetAccount ?? null)) return;

  const expenses = await ctx.db
    .query("expenses")
    .withIndex("by_owner_email", (q) => q.eq("owner_email", ownerEmail))
    .take(MAX_EXPENSE_WRITE_OPERATIONS + 1);
  if (expenses.length > MAX_EXPENSE_WRITE_OPERATIONS) {
    throw new Error(
      `Expense reconciliation supports at most ${MAX_EXPENSE_WRITE_OPERATIONS} expenses`
    );
  }

  const relevantExpenses = expenses.filter(
    (e) => e.involved_member_ids.includes(memberId) || e.paid_by_member_id === memberId
  );

  const operations: ExpenseWriteOperation[] = [];
  for (const expense of relevantExpenses) {
    const viewerAccounts = await resolveActiveExpenseParticipantAccounts(ctx, expense);
    const viewerAccountIds = new Map(
      viewerAccounts.map((account) => [String(account._id), account._id])
    );
    viewerAccountIds.set(String(targetAccount._id), targetAccount._id);
    operations.push({
      kind: "visibility" as const,
      expense,
      viewerAccountIds: Array.from(viewerAccountIds.values())
    });
  }
  await applyExpenseWriteBatch(ctx, operations);
}
