import { resolveRestoredHistoryAccess } from "./restoredHistory";
import { MeasuredBudgetError } from "./restoreContracts";
import {
  assertFinancialContract,
  assertMemberIdentityReady,
  assertHistoryProjectionReady,
  bindHistoryExpenseScope,
  type HistoryWorkerScope,
  FINANCIAL_CONTRACT_VERSION,
  resolveLiveAccountForMember,
  withIdentityReadBudget,
  type IdentityReadBudgetHooks
} from "./financialContract";
import { getOwnerLocalAliasMap } from "./aliases";
import { MutationCtx, QueryCtx } from "./_generated/server";
import { Doc, Id } from "./_generated/dataModel";
import { ConvexError, getConvexSize } from "convex/values";
import { findAccountByAuthIdOrDocId, normalizeMemberId } from "./identity";
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
  | "group_ref"
  | "context_kind"
  | "has_restored_history"
  | "restored_historical_member_ids"
  | "restored_history_context_member_ids"
> & { _id?: Id<"expenses"> };

type ExpenseParticipant = Doc<"expenses">["participants"][number];

export type ExpenseIdentityResolutionCache = {
  memberAccounts: Map<string, Promise<Doc<"accounts"> | null>>;
  linkedIdAccounts: Map<string, Promise<Doc<"accounts"> | null>>;
  emailAccounts: Map<string, Promise<Doc<"accounts"> | null>>;
  ownerAccounts: Map<string, Promise<Doc<"accounts"> | null>>;
  ownerLocalAliases: Map<string, Promise<Map<string, string>>>;
  ownerLocalAliasSeeds: Map<string, Set<string>>;
  ownerFinancialProjectionReady: Map<string, Promise<void>>;
  readyIdentityMembers: Set<string>;
  historyFriendLinks: Map<string, Promise<boolean>>;
  localAliasQueries: number;
  localAliasRows: number;
  localAliasBytes: number;
};

export function createExpenseIdentityResolutionCache(): ExpenseIdentityResolutionCache {
  return {
    memberAccounts: new Map(),
    linkedIdAccounts: new Map(),
    emailAccounts: new Map(),
    ownerAccounts: new Map(),
    ownerLocalAliases: new Map(),
    ownerLocalAliasSeeds: new Map(),
    ownerFinancialProjectionReady: new Map(),
    readyIdentityMembers: new Set(),
    historyFriendLinks: new Map(),
    localAliasQueries: 0,
    localAliasRows: 0,
    localAliasBytes: 0
  };
}

function expenseIdentityBudget(
  cache?: ExpenseIdentityResolutionCache
): IdentityReadBudgetHooks | undefined {
  if (!cache) return undefined;
  return {
    chargeQueries: (count) => {
      cache.localAliasQueries += count;
      if (cache.localAliasQueries > 2048)
        throw new MeasuredBudgetError("identity", "Expense identity query budget exceeded");
    },
    chargeRows: (rows) => {
      cache.localAliasRows += rows.length;
      cache.localAliasBytes += rows.reduce<number>((sum, row) => sum + getConvexSize(row), 0);
      if (cache.localAliasRows > 2048 || cache.localAliasBytes > 8 * 1024 * 1024)
        throw new MeasuredBudgetError("identity", "Expense identity read budget exceeded");
    }
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
  ctx: Pick<QueryCtx, "db">,
  expense: ExpenseOwnerSource,
  cache?: ExpenseIdentityResolutionCache
): Promise<Doc<"accounts"> | null> {
  if (cache) ctx = withIdentityReadBudget(ctx, expenseIdentityBudget(cache)!);
  const resolvedAccounts = new Map<string, Doc<"accounts">>();
  const addResolvedAccount = (account: Doc<"accounts"> | null) => {
    if (account) resolvedAccounts.set(account.id, account);
  };

  if (expense.owner_id)
    addResolvedAccount(
      await cachedAccountResolution(cache?.ownerAccounts, String(expense.owner_id), () =>
        ctx.db.get(expense.owner_id)
      )
    );
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
  ctx: Pick<QueryCtx, "db">,
  participant: ExpenseParticipant,
  cache?: ExpenseIdentityResolutionCache
): Promise<Doc<"accounts"> | null> {
  const normalizedMemberId = normalizeMemberId(participant.member_id);
  const memberAccount = await cachedAccountResolution(
    cache?.memberAccounts,
    normalizedMemberId,
    () => resolveLiveAccountForMember(ctx, normalizedMemberId, expenseIdentityBudget(cache))
  );
  if (memberAccount !== null) return isActiveAccount(memberAccount) ? memberAccount : null;

  // Client email/account metadata is descriptive, never evidence of identity ownership.
  return null;
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

async function resolveOwnerLocalExpenseAliases(
  ctx: Pick<QueryCtx, "db">,
  ownerAccount: Doc<"accounts">,
  memberIds: string[],
  cache: ExpenseIdentityResolutionCache
): Promise<Map<string, string>> {
  const loadedSeeds = cache.ownerLocalAliasSeeds.get(ownerAccount.email) ?? new Set<string>();
  const missingSeeds = memberIds.filter((member) => !loadedSeeds.has(member));
  for (const member of missingSeeds) loadedSeeds.add(member);
  cache.ownerLocalAliasSeeds.set(ownerAccount.email, loadedSeeds);
  if (missingSeeds.length) {
    const previous =
      cache.ownerLocalAliases.get(ownerAccount.email) ?? Promise.resolve(new Map<string, string>());
    cache.ownerLocalAliases.set(
      ownerAccount.email,
      previous.then(async (existing) => {
        const additions = await getOwnerLocalAliasMap(ctx, ownerAccount.email, {
          memberIds: missingSeeds,
          ...expenseIdentityBudget(cache)
        });
        for (const [source, target] of additions) {
          if (existing.has(source) && existing.get(source) !== target)
            throw new Error("Conflicting owner-local aliases");
          existing.set(source, target);
        }
        return existing;
      })
    );
  }
  return await (cache.ownerLocalAliases.get(ownerAccount.email) ??
    Promise.resolve(new Map<string, string>()));
}

/** Foreign viewers also wait for the owner's alias/deletion generation to finish. */
export async function resolveExpenseFinancialProjectionOwner(
  ctx: Pick<QueryCtx, "db">,
  expense: ExpenseOwnerSource,
  cache: ExpenseIdentityResolutionCache = createExpenseIdentityResolutionCache(),
  scope?: HistoryWorkerScope
): Promise<Doc<"accounts"> | null> {
  const owner = await resolveAuthoritativeExpenseOwnerAccount(ctx, expense, cache);
  if (owner) {
    const ownerKey = String(owner._id);
    if (!cache.ownerFinancialProjectionReady.has(ownerKey))
      cache.ownerFinancialProjectionReady.set(
        ownerKey,
        (async () => {
          if (scope) {
            await assertHistoryProjectionReady(
              withIdentityReadBudget(ctx, expenseIdentityBudget(cache)!),
              { ownerId: owner._id, memberIds: [], scope }
            );
            return;
          }
          if (owner.status === "deleting")
            throw new Error(
              "IDENTITY_OPERATION_PENDING: Expense owner identity is changing; retry after reconciliation"
            );
          await assertFinancialContract(
            withIdentityReadBudget(ctx, expenseIdentityBudget(cache)!),
            owner,
            FINANCIAL_CONTRACT_VERSION
          );
        })()
      );
    await cache.ownerFinancialProjectionReady.get(ownerKey)!;
  }
  return owner;
}

/** Derived response metadata only. Never persist or accept this map as write authority. */
export async function deriveExpenseFinancialIdentityMap(
  ctx: Pick<QueryCtx, "db">,
  expense: ExpenseVisibilitySource,
  cache: ExpenseIdentityResolutionCache = createExpenseIdentityResolutionCache(),
  scope?: HistoryWorkerScope
): Promise<Record<string, string>> {
  assertExpenseVisibilitySourceBounded(expense);
  const rawIds = [
    ...new Set(
      [
        expense.paid_by_member_id,
        ...expense.involved_member_ids,
        ...expense.participant_member_ids,
        ...expense.participants.map((row) => row.member_id),
        ...expense.splits.map((row) => row.member_id)
      ].map(normalizeMemberId)
    )
  ];
  const inactive = new Set((expense.inactive_participant_member_ids ?? []).map(normalizeMemberId));
  return deriveOwnerScopedFinancialIdentityMap(ctx, expense, rawIds, inactive, cache, scope);
}

export async function deriveOwnerScopedFinancialIdentityMap(
  ctx: Pick<QueryCtx, "db">,
  ownerSource: ExpenseOwnerSource,
  memberIds: readonly string[],
  inactive: ReadonlySet<string> = new Set(),
  cache: ExpenseIdentityResolutionCache = createExpenseIdentityResolutionCache(),
  scope?: HistoryWorkerScope
): Promise<Record<string, string>> {
  const rawIds = [...new Set(memberIds.map(normalizeMemberId))];
  if (rawIds.length > MAX_EXPENSE_VIEWERS)
    throw new Error("Financial identity projection exceeds supported participant bound");
  const owner = await resolveExpenseFinancialProjectionOwner(ctx, ownerSource, cache, scope);
  // A raw ID often is already its final canonical target. Check each distinct
  // identity once within this projection, while retaining the same owner and scope.
  const scopedReadyMembers = new Set<string>();
  const assertScopedMembersReady = async (ids: readonly string[]) => {
    const unchecked = [...new Set(ids.map(normalizeMemberId))].filter(
      (id) => !scopedReadyMembers.has(id)
    );
    if (!unchecked.length) return;
    await assertHistoryProjectionReady(withIdentityReadBudget(ctx, expenseIdentityBudget(cache)!), {
      ownerId: owner?._id,
      memberIds: unchecked,
      scope
    });
    for (const id of unchecked) scopedReadyMembers.add(id);
  };
  if (scope) await assertScopedMembersReady(rawIds);
  else
    await assertMemberIdentityReady(
      withIdentityReadBudget(ctx, expenseIdentityBudget(cache)!),
      rawIds,
      owner?._id,
      cache.readyIdentityMembers
    );
  const localAliases = owner
    ? await resolveOwnerLocalExpenseAliases(
        ctx,
        owner,
        rawIds.filter((id) => !inactive.has(id)),
        cache
      )
    : new Map<string, string>();
  if (scope) await assertScopedMembersReady([...localAliases.values()]);
  else
    await assertMemberIdentityReady(
      withIdentityReadBudget(ctx, expenseIdentityBudget(cache)!),
      [...localAliases.values()],
      owner?._id,
      cache.readyIdentityMembers
    );
  const result = new Map<string, string>();
  for (const raw of rawIds) {
    if (inactive.has(raw)) {
      result.set(raw, raw);
      continue;
    }
    const account = await cachedAccountResolution(cache.memberAccounts, raw, () =>
      resolveLiveAccountForMember(ctx, raw, expenseIdentityBudget(cache))
    );
    if (account?.member_id) {
      result.set(raw, normalizeMemberId(account.member_id));
      continue;
    }
    let target = localAliases.get(raw) ?? raw;
    const visited = new Set<string>([raw]);
    while (localAliases.has(target) && localAliases.get(target) !== target) {
      if (visited.has(target))
        throw new Error("Identity maintenance required: cyclic financial projection");
      visited.add(target);
      target = localAliases.get(target)!;
    }
    const linked =
      target === raw
        ? null
        : await cachedAccountResolution(cache.memberAccounts, target, () =>
            resolveLiveAccountForMember(ctx, target, expenseIdentityBudget(cache))
          );
    result.set(raw, linked?.member_id ? normalizeMemberId(linked.member_id) : target);
  }
  if (scope) await assertScopedMembersReady([...result.values()]);
  else
    await assertMemberIdentityReady(
      withIdentityReadBudget(ctx, expenseIdentityBudget(cache)!),
      [...result.values()],
      owner?._id,
      cache.readyIdentityMembers
    );
  return Object.fromEntries(result);
}

export async function resolveActiveExpenseParticipantAccounts(
  ctx: Pick<QueryCtx, "db">,
  expense: ExpenseVisibilitySource,
  excludedAccountIds: ReadonlySet<string> = new Set(),
  cache: ExpenseIdentityResolutionCache = createExpenseIdentityResolutionCache(),
  visibilityAccountId?: Id<"accounts">,
  historyScope?: HistoryWorkerScope
): Promise<Doc<"accounts">[]> {
  assertExpenseVisibilitySourceBounded(expense);
  const accounts = new Map<string, Doc<"accounts">>();
  const inactiveMemberIds = new Set(
    (expense.inactive_participant_member_ids ?? []).map(normalizeMemberId)
  );
  const inactiveAccountIds = new Set<string>();
  for (const memberId of inactiveMemberIds) {
    const account = await cachedAccountResolution(cache?.memberAccounts, memberId, () =>
      resolveLiveAccountForMember(ctx, memberId, expenseIdentityBudget(cache))
    );
    if (account) inactiveAccountIds.add(account.id);
  }
  for (const participant of expense.participants) {
    if (!inactiveMemberIds.has(normalizeMemberId(participant.member_id))) continue;

    if (participant.linked_account_id?.trim()) {
      const linkedAccountId = participant.linked_account_id.trim();
      const account = await cachedAccountResolution(cache?.linkedIdAccounts, linkedAccountId, () =>
        findAccountByAuthIdOrDocId(
          withIdentityReadBudget(ctx, expenseIdentityBudget(cache)!).db,
          linkedAccountId
        )
      );
      if (account) inactiveAccountIds.add(account.id);
    }
    if (participant.linked_account_email?.trim()) {
      const email = participant.linked_account_email.trim().toLowerCase();
      const account = await cachedAccountResolution(cache?.emailAccounts, email, () =>
        withIdentityReadBudget(ctx, expenseIdentityBudget(cache)!)
          .db.query("accounts")
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
  const ownerScopeAccount = await resolveAuthoritativeExpenseOwnerAccount(ctx, expense, cache);
  const ownerAccount = addAccount(ownerScopeAccount);
  if (ownerAccount) ownerAccountIds.add(ownerAccount.id);

  const activeMemberAccountIds = new Set<string>();
  const memberIds = collectActiveExpenseMemberIds(expense);
  for (const memberId of memberIds) {
    const account = addAccount(
      await cachedAccountResolution(cache?.memberAccounts, memberId, () =>
        resolveLiveAccountForMember(ctx, memberId, expenseIdentityBudget(cache))
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

  // Build one graph per owner for the complete query/batch, not once per expense.
  if (ownerScopeAccount && (isActiveAccount(ownerScopeAccount) || historyScope)) {
    const scopedDeletion = !isActiveAccount(ownerScopeAccount);
    if (scopedDeletion && !expense._id)
      throw new Error("Deleting owner identity requires a persisted expense binding");
    const boundScope = scopedDeletion
      ? await bindHistoryExpenseScope(ctx, historyScope, expense)
      : historyScope;
    // Deleting owners remain identity provenance only for their verified current
    // cleanup record. They never re-enter the active viewer set.
    const localAliases = scopedDeletion
      ? new Map(
          Object.entries(await deriveExpenseFinancialIdentityMap(ctx, expense, cache, boundScope))
        )
      : await resolveOwnerLocalExpenseAliases(ctx, ownerScopeAccount, memberIds, cache);
    for (const memberId of memberIds) {
      const target = localAliases.get(memberId);
      if (!target || target === memberId) continue;
      const account = await cachedAccountResolution(cache.memberAccounts, target, () =>
        resolveLiveAccountForMember(ctx, target, expenseIdentityBudget(cache))
      );
      if (account && !inactiveAccountIds.has(account.id)) addAccount(account);
    }
  }
  const historyAccess = await resolveRestoredHistoryAccess(ctx, expense, {
    cache,
    scope: historyScope
  });
  if (historyAccess)
    for (const [id, account] of accounts) {
      if (
        account._id !== expense.owner_id &&
        !historyAccess.eligibleFinancialAccountIds.has(account._id)
      )
        accounts.delete(id);
    }
  for (const account of accounts.values()) {
    if (visibilityAccountId && account._id !== visibilityAccountId) {
      accounts.delete(account.id);
      continue;
    }
    const suppressed = await ctx.db
      .query("expense_visibility_suppressions")
      .withIndex("by_account_expense", (q) =>
        q.eq("account_ref", account._id).eq("expense_id", expense.id)
      )
      .first();
    if (suppressed) accounts.delete(account.id);
  }

  return Array.from(accounts.values());
}
export async function resolveActiveExpenseParticipantUserIds(
  ctx: MutationCtx | QueryCtx,
  expense: ExpenseVisibilitySource,
  excludedAccountIds: ReadonlySet<string> = new Set()
): Promise<string[]> {
  const accounts = await resolveActiveExpenseParticipantAccounts(ctx, expense, excludedAccountIds);
  return accounts.map((account) => account.id);
}

export async function reconcileExpenseVisibility(
  ctx: MutationCtx,
  expense: ExpenseVisibilitySource,
  excludedAccountIds: ReadonlySet<string> = new Set(),
  options: {
    forceRevision?: boolean;
    historyScope?: HistoryWorkerScope;
    budget?: import("./expenseWrites").ExpenseWriteBatchBudgetHooks;
  } = {}
) {
  const readContext = options.budget
    ? withIdentityReadBudget(ctx, {
        chargeQueries: (count) => options.budget?.chargeQueries?.(count),
        chargeRows: (rows) => options.budget?.chargeRows?.(rows)
      })
    : ctx;
  const accounts = await resolveActiveExpenseParticipantAccounts(
    readContext,
    expense,
    excludedAccountIds,
    undefined,
    undefined,
    options.historyScope
  );
  const matches = await readContext.db
    .query("expenses")
    .withIndex("by_client_id", (query) => query.eq("id", expense.id))
    .take(2);
  if (matches.length > 1) throw new Error(`Expense ${expense.id} is not unique`);
  const storedExpense = matches[0];
  if (!storedExpense) throw new Error(`Expense ${expense.id} not found`);
  await applyExpenseWriteBatch(
    ctx,
    [
      {
        kind: "visibility",
        expense: storedExpense,
        viewerAccountIds: accounts.map((account) => account._id),
        forceRevision: options.forceRevision
      }
    ],
    { historyScope: options.historyScope, budget: options.budget }
  );
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
