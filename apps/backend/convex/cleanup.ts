import { mutation, internalMutation, query, MutationCtx } from "./_generated/server";
import { v } from "convex/values";
import { Doc } from "./_generated/dataModel";
import { getAllEquivalentMemberIds, resolveCanonicalMemberIdInternal } from "./aliases";
import {
  assertIdentityMaterializationReady,
  findAccountByMemberId,
  MAX_ALIAS_ROWS_PER_MEMBER_ID,
  MAX_LIVE_ACCOUNT_ALIASES,
  MAX_LIVE_ALIAS_DELTA,
  normalizeMemberId
} from "./identity";
import {
  collectActiveExpenseMemberIds,
  createExpenseIdentityResolutionCache,
  ExpenseIdentityResolutionCache,
  reconcileExpenseVisibility,
  reconcileUserExpenses,
  resolveActiveExpenseParticipantAccounts,
  resolveConsistentExpenseParticipantAccount
} from "./helpers";

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

function normalizeEmail(value: string | undefined | null): string | undefined {
  if (typeof value !== "string") return undefined;
  const normalized = value.trim().toLowerCase();
  return normalized.length > 0 ? normalized : undefined;
}

function matchesEquivalentMemberId(
  memberId: string,
  normalizedEquivalentIds: ReadonlySet<string>
): boolean {
  return normalizedEquivalentIds.has(normalizeMemberId(memberId));
}

function expenseReferencesEquivalentMember(
  expense: Doc<"expenses">,
  normalizedEquivalentIds: ReadonlySet<string>
): boolean {
  return (
    matchesEquivalentMemberId(expense.paid_by_member_id, normalizedEquivalentIds) ||
    expense.involved_member_ids.some((memberId) =>
      matchesEquivalentMemberId(memberId, normalizedEquivalentIds)
    ) ||
    expense.participant_member_ids.some((memberId) =>
      matchesEquivalentMemberId(memberId, normalizedEquivalentIds)
    ) ||
    expense.splits.some((split) =>
      matchesEquivalentMemberId(split.member_id, normalizedEquivalentIds)
    ) ||
    expense.participants.some((participant) =>
      matchesEquivalentMemberId(participant.member_id, normalizedEquivalentIds)
    )
  );
}

const FRIEND_CLEANUP_LIMITS = {
  groups: 256,
  expenses: 512,
  attachedExpenses: 512,
  readRows: 2048,
  queries: 512,
  estimatedReadBytes: 8 * 1024 * 1024,
  hardReadSafetyBytes: 10 * 1024 * 1024,
  maximumDocumentReservationBytes: 2 * 1024 * 1024,
  maximumPageRows: 5,
  participantIdentityKeys: 128,
  visibilityRows: 512,
  writes: 2048
} as const;

type FriendCleanupAggregateBudget = {
  attachedExpenseIds: Set<string>;
  identityResolutionKeys: Set<string>;
  readRows: number;
  queries: number;
  estimatedReadBytes: number;
  visibilityRows: number;
  writes: number;
};

function createFriendCleanupAggregateBudget(): FriendCleanupAggregateBudget {
  return {
    attachedExpenseIds: new Set(),
    identityResolutionKeys: new Set(),
    readRows: 0,
    queries: 0,
    estimatedReadBytes: 0,
    visibilityRows: 0,
    writes: 0
  };
}

function friendCleanupLimitError() {
  return new Error("Friend cleanup is too large to complete safely");
}

function accountFriendCleanupRows(budget: FriendCleanupAggregateBudget, rows: readonly unknown[]) {
  budget.readRows += rows.length;
  budget.estimatedReadBytes += rows.reduce<number>(
    (total, row) => total + new TextEncoder().encode(JSON.stringify(row) ?? "").length,
    0
  );
  if (
    budget.readRows > FRIEND_CLEANUP_LIMITS.readRows ||
    budget.estimatedReadBytes > FRIEND_CLEANUP_LIMITS.estimatedReadBytes
  ) {
    throw friendCleanupLimitError();
  }
}

function chargeFriendCleanupQueries(budget: FriendCleanupAggregateBudget, count: number) {
  budget.queries += count;
  if (budget.queries > FRIEND_CLEANUP_LIMITS.queries) {
    throw friendCleanupLimitError();
  }
}

async function resolveBudgetedFriendCleanupMemberAccount(
  ctx: MutationCtx,
  memberId: string,
  budget: FriendCleanupAggregateBudget
): Promise<Doc<"accounts"> | null> {
  let currentMemberId = normalizeMemberId(memberId);
  const visited = new Set<string>();

  for (let depth = 0; depth < 20; depth += 1) {
    if (!currentMemberId || visited.has(currentMemberId)) return null;
    visited.add(currentMemberId);

    // Cleanup asserts identity materialization once before planning. Read the normalized ready
    // indexes directly so each hop has exactly one account range and one alias range.
    chargeFriendCleanupQueries(budget, 1);
    const account = await ctx.db
      .query("accounts")
      .withIndex("by_member_id", (q) => q.eq("member_id", currentMemberId))
      .first();
    accountFriendCleanupRows(budget, account ? [account] : []);
    if (account) return account;

    chargeFriendCleanupQueries(budget, 1);
    const alias = await ctx.db
      .query("member_aliases")
      .withIndex("by_alias_member_id_and_source", (q) =>
        q.eq("alias_member_id", currentMemberId).eq("materialization_source", "account_alias")
      )
      .first();
    accountFriendCleanupRows(budget, alias ? [alias] : []);
    if (!alias) return null;
    currentMemberId = normalizeMemberId(alias.canonical_member_id);
  }

  return null;
}

async function prepareFriendCleanupIdentityReads(
  ctx: MutationCtx,
  budget: FriendCleanupAggregateBudget,
  expense: Doc<"expenses">,
  cache: ExpenseIdentityResolutionCache
) {
  const keys = new Set<string>();
  const addKey = (
    kind: "document" | "email" | "linked" | "member",
    value: string | undefined | null
  ) => {
    const trimmed = value?.trim();
    if (!trimmed) return;
    const normalized = kind === "email" || kind === "member" ? trimmed.toLowerCase() : trimmed;
    keys.add(`${kind}:${normalized}`);
  };

  for (const memberId of collectActiveExpenseMemberIds(expense)) {
    addKey("member", normalizeMemberId(memberId));
  }
  for (const memberId of expense.inactive_participant_member_ids ?? []) {
    addKey("member", normalizeMemberId(memberId));
  }
  for (const participant of expense.participants) {
    addKey("member", normalizeMemberId(participant.member_id));
    addKey("linked", participant.linked_account_id);
    addKey("email", participant.linked_account_email);
  }
  for (const email of expense.participant_emails) addKey("email", email);
  addKey("linked", expense.owner_account_id);
  addKey("email", expense.owner_email);
  // Owner document reads are not part of the shared helper cache, so reserve one per expense.
  if (expense.owner_id) addKey("document", `${expense._id}:${expense.owner_id}`);

  const memberIdsToResolve: string[] = [];
  for (const key of keys) {
    if (!budget.identityResolutionKeys.has(key)) {
      budget.identityResolutionKeys.add(key);
      if (key.startsWith("member:")) {
        memberIdsToResolve.push(key.slice("member:".length));
      } else if (key.startsWith("linked:")) {
        chargeFriendCleanupQueries(budget, 2);
      } else {
        chargeFriendCleanupQueries(budget, 1);
      }
    }
  }
  if (budget.identityResolutionKeys.size > FRIEND_CLEANUP_LIMITS.participantIdentityKeys) {
    throw friendCleanupLimitError();
  }

  for (const memberId of memberIdsToResolve.sort()) {
    if (cache.memberAccounts.has(memberId)) continue;
    const pendingAccount = resolveBudgetedFriendCleanupMemberAccount(ctx, memberId, budget);
    cache.memberAccounts.set(memberId, pendingAccount);
    await pendingAccount;
  }
}

function reserveFriendCleanupWrites(budget: FriendCleanupAggregateBudget, count: number) {
  budget.writes += count;
  if (budget.writes > FRIEND_CLEANUP_LIMITS.writes) {
    throw friendCleanupLimitError();
  }
}

async function collectSequentialFriendCleanupRows<T>(
  budget: FriendCleanupAggregateBudget,
  readPage: (
    cursor: string | null,
    limit: number
  ) => Promise<{ page: T[]; continueCursor: string; isDone: boolean }>,
  accountSecondaryRows?: (rows: readonly T[]) => void
): Promise<T[]> {
  const rows: T[] = [];
  let cursor: string | null = null;
  while (true) {
    const remainingRows = FRIEND_CLEANUP_LIMITS.readRows - budget.readRows + 1;
    const remainingHardBytes =
      FRIEND_CLEANUP_LIMITS.hardReadSafetyBytes - budget.estimatedReadBytes;
    const byteReservedRows = Math.floor(
      remainingHardBytes / FRIEND_CLEANUP_LIMITS.maximumDocumentReservationBytes
    );
    const pageSize = Math.min(
      FRIEND_CLEANUP_LIMITS.maximumPageRows,
      remainingRows,
      byteReservedRows
    );
    if (pageSize <= 0) throw friendCleanupLimitError();

    budget.queries += 1;
    if (budget.queries > FRIEND_CLEANUP_LIMITS.queries) {
      throw friendCleanupLimitError();
    }
    const result = await readPage(cursor, pageSize);
    accountFriendCleanupRows(budget, result.page);
    accountSecondaryRows?.(result.page);
    rows.push(...result.page);
    if (result.isDone) return rows;
    if (result.continueCursor === cursor) throw friendCleanupLimitError();
    cursor = result.continueCursor;
  }
}

function hasConsistentGroupOwner(group: Doc<"groups">, account: Doc<"accounts">) {
  const hasAccountId = Boolean(group.owner_account_id?.trim());
  const hasDocumentId = Boolean(group.owner_id);
  const ownerEmail = normalizeEmail(group.owner_email);
  return (
    (!hasAccountId || group.owner_account_id === account.id) &&
    (!hasDocumentId || group.owner_id === account._id) &&
    (ownerEmail === undefined || ownerEmail === normalizeEmail(account.email)) &&
    (hasAccountId || hasDocumentId || ownerEmail !== undefined)
  );
}

function hasConsistentExpenseOwner(expense: Doc<"expenses">, account: Doc<"accounts">) {
  const hasAccountId = Boolean(expense.owner_account_id?.trim());
  const hasDocumentId = Boolean(expense.owner_id);
  const ownerEmail = normalizeEmail(expense.owner_email);
  return (
    (!hasAccountId || expense.owner_account_id?.trim() === account.id) &&
    (!hasDocumentId || expense.owner_id === account._id) &&
    (ownerEmail === undefined || ownerEmail === normalizeEmail(account.email)) &&
    (hasAccountId || hasDocumentId || ownerEmail !== undefined)
  );
}

async function collectFriendCleanupGroups(
  ctx: MutationCtx,
  account: Doc<"accounts">,
  budget: FriendCleanupAggregateBudget
) {
  const pages = [
    await collectSequentialFriendCleanupRows(budget, async (cursor, limit) =>
      ctx.db
        .query("groups")
        .withIndex("by_owner_id", (q) => q.eq("owner_id", account._id))
        .order("asc")
        .paginate({ cursor, numItems: limit })
    ),
    await collectSequentialFriendCleanupRows(budget, async (cursor, limit) =>
      ctx.db
        .query("groups")
        .withIndex("by_owner_account_id", (q) => q.eq("owner_account_id", account.id))
        .order("asc")
        .paginate({ cursor, numItems: limit })
    ),
    await collectSequentialFriendCleanupRows(budget, async (cursor, limit) =>
      ctx.db
        .query("groups")
        .withIndex("by_owner_email", (q) => q.eq("owner_email", account.email))
        .order("asc")
        .paginate({ cursor, numItems: limit })
    )
  ];
  if (pages.some((page) => page.length > FRIEND_CLEANUP_LIMITS.groups)) {
    throw friendCleanupLimitError();
  }
  const groups = new Map<string, Doc<"groups">>();
  for (const group of pages.flat()) {
    if (!hasConsistentGroupOwner(group, account)) {
      throw new Error("Cannot clean records with a conflicting owner identity");
    }
    groups.set(String(group._id), group);
  }
  if (groups.size > FRIEND_CLEANUP_LIMITS.groups) throw friendCleanupLimitError();
  return groups;
}

async function collectFriendCleanupExpenses(
  ctx: MutationCtx,
  account: Doc<"accounts">,
  budget: FriendCleanupAggregateBudget
) {
  const pages = [
    await collectSequentialFriendCleanupRows(budget, async (cursor, limit) =>
      ctx.db
        .query("expenses")
        .withIndex("by_owner_id", (q) => q.eq("owner_id", account._id))
        .order("asc")
        .paginate({ cursor, numItems: limit })
    ),
    await collectSequentialFriendCleanupRows(budget, async (cursor, limit) =>
      ctx.db
        .query("expenses")
        .withIndex("by_owner_account_id", (q) => q.eq("owner_account_id", account.id))
        .order("asc")
        .paginate({ cursor, numItems: limit })
    ),
    await collectSequentialFriendCleanupRows(budget, async (cursor, limit) =>
      ctx.db
        .query("expenses")
        .withIndex("by_owner_email", (q) => q.eq("owner_email", account.email))
        .order("asc")
        .paginate({ cursor, numItems: limit })
    )
  ];
  if (pages.some((page) => page.length > FRIEND_CLEANUP_LIMITS.expenses)) {
    throw friendCleanupLimitError();
  }
  const expenses = new Map<string, Doc<"expenses">>();
  for (const expense of pages.flat()) {
    if (!hasConsistentExpenseOwner(expense, account)) {
      throw new Error("Expense owner identity is inconsistent");
    }
    expenses.set(String(expense._id), expense);
  }
  if (expenses.size > FRIEND_CLEANUP_LIMITS.expenses) throw friendCleanupLimitError();
  return expenses;
}

async function collectAttachedFriendCleanupExpenses(
  ctx: MutationCtx,
  group: Doc<"groups">,
  budget: FriendCleanupAggregateBudget
): Promise<Doc<"expenses">[]> {
  const pages = [
    await collectSequentialFriendCleanupRows(budget, async (cursor, limit) =>
      ctx.db
        .query("expenses")
        .withIndex("by_group_id", (q) => q.eq("group_id", group.id))
        .order("asc")
        .paginate({ cursor, numItems: limit })
    ),
    await collectSequentialFriendCleanupRows(budget, async (cursor, limit) =>
      ctx.db
        .query("expenses")
        .withIndex("by_group_ref", (q) => q.eq("group_ref", group._id))
        .order("asc")
        .paginate({ cursor, numItems: limit })
    )
  ];
  if (pages.some((page) => page.length > FRIEND_CLEANUP_LIMITS.expenses)) {
    throw friendCleanupLimitError();
  }
  const expenses = new Map<string, Doc<"expenses">>();
  for (const expense of pages.flat()) {
    const expenseId = String(expense._id);
    expenses.set(expenseId, expense);
    budget.attachedExpenseIds.add(expenseId);
  }
  if (budget.attachedExpenseIds.size > FRIEND_CLEANUP_LIMITS.attachedExpenses) {
    throw friendCleanupLimitError();
  }
  if (expenses.size > FRIEND_CLEANUP_LIMITS.expenses) throw friendCleanupLimitError();
  return Array.from(expenses.values());
}

async function collectFriendCleanupVisibilityRows(
  ctx: MutationCtx,
  expenseIds: ReadonlySet<string>,
  budget: FriendCleanupAggregateBudget
): Promise<Map<string, Doc<"user_expenses">[]>> {
  const rowsByExpenseId = new Map<string, Doc<"user_expenses">[]>();
  for (const expenseId of Array.from(expenseIds).sort()) {
    const rows = await collectSequentialFriendCleanupRows(
      budget,
      async (cursor, limit) =>
        ctx.db
          .query("user_expenses")
          .withIndex("by_expense_id", (q) => q.eq("expense_id", expenseId))
          .order("asc")
          .paginate({ cursor, numItems: limit }),
      (page) => {
        budget.visibilityRows += page.length;
        if (budget.visibilityRows > FRIEND_CLEANUP_LIMITS.visibilityRows) {
          throw friendCleanupLimitError();
        }
      }
    );
    rowsByExpenseId.set(expenseId, rows);
  }
  return rowsByExpenseId;
}

function visibilityWriteCount(
  existingRows: readonly Doc<"user_expenses">[],
  targetUserIds: readonly string[]
) {
  const existingUserIds = new Set(existingRows.map((row) => row.user_id));
  const targetUserIdSet = new Set(targetUserIds);
  const inserts = targetUserIds.filter((userId) => !existingUserIds.has(userId)).length;
  const deletes = existingRows.filter((row) => !targetUserIdSet.has(row.user_id)).length;
  return inserts + deletes;
}

async function deletePreloadedUserExpenses(
  ctx: MutationCtx,
  rows: readonly Doc<"user_expenses">[]
) {
  await Promise.all(rows.map((row) => ctx.db.delete(row._id)));
}

async function reconcilePreloadedUserExpenses(
  ctx: MutationCtx,
  expenseId: string,
  targetUserIds: readonly string[],
  existingRows: readonly Doc<"user_expenses">[]
) {
  const existingUserIds = new Set(existingRows.map((row) => row.user_id));
  const targetUserIdSet = new Set(targetUserIds);
  const userIdsToAdd = targetUserIds.filter((userId) => !existingUserIds.has(userId));
  const rowsToDelete = existingRows.filter((row) => !targetUserIdSet.has(row.user_id));

  await Promise.all([
    ...userIdsToAdd.map((userId) =>
      ctx.db.insert("user_expenses", {
        user_id: userId,
        expense_id: expenseId,
        updated_at: Date.now()
      })
    ),
    ...rowsToDelete.map((row) => ctx.db.delete(row._id))
  ]);
}

type PreparedRemovedFriendExpense =
  | { outcome: "unchanged"; expense: Doc<"expenses"> }
  | { outcome: "deleted"; expense: Doc<"expenses"> }
  | {
      outcome: "modified";
      expense: Doc<"expenses">;
      participantUserIds: string[];
      patch: Pick<
        Doc<"expenses">,
        | "participant_member_ids"
        | "inactive_participant_member_ids"
        | "involved_member_ids"
        | "participant_emails"
        | "updated_at"
      >;
    };

async function resolveActiveMemberAccount(
  ctx: MutationCtx,
  expense: Doc<"expenses">,
  normalizedMemberId: string,
  cache: ExpenseIdentityResolutionCache
): Promise<Doc<"accounts"> | null> {
  const participant = expense.participants.find(
    (candidate) => normalizeMemberId(candidate.member_id) === normalizedMemberId
  ) ?? { member_id: normalizedMemberId, name: "" };
  return await resolveConsistentExpenseParticipantAccount(ctx, participant, cache);
}

async function prepareEquivalentMemberRemovalFromExpense(
  ctx: any,
  expense: Doc<"expenses">,
  normalizedEquivalentIds: ReadonlySet<string>,
  budget: FriendCleanupAggregateBudget,
  cache: ExpenseIdentityResolutionCache,
  ownerAccount: Doc<"accounts">
): Promise<PreparedRemovedFriendExpense> {
  if (!expenseReferencesEquivalentMember(expense, normalizedEquivalentIds)) {
    return { outcome: "unchanged", expense };
  }

  const remainingParticipants = collectActiveExpenseMemberIds(expense, normalizedEquivalentIds);
  const removedFriendWasPayer = matchesEquivalentMemberId(
    expense.paid_by_member_id,
    normalizedEquivalentIds
  );

  if (removedFriendWasPayer) {
    return { outcome: "deleted", expense };
  }

  const inactiveParticipantMemberIds = Array.from(
    new Set([
      ...(expense.inactive_participant_member_ids ?? []).map(normalizeMemberId),
      ...normalizedEquivalentIds
    ])
  );
  const visibilityExpense: Doc<"expenses"> = {
    ...expense,
    participant_member_ids: remainingParticipants,
    involved_member_ids: remainingParticipants,
    inactive_participant_member_ids: inactiveParticipantMemberIds,
    participant_emails: []
  };
  // The shared identity cache does not cover resolveAuthoritativeExpenseOwnerAccount's
  // owner_id lookup, so account its returned row once for every prepared expense.
  if (visibilityExpense.owner_id) accountFriendCleanupRows(budget, [ownerAccount]);
  await prepareFriendCleanupIdentityReads(ctx, budget, visibilityExpense, cache);
  const activeParticipantAccounts = await resolveActiveExpenseParticipantAccounts(
    ctx,
    visibilityExpense,
    new Set(),
    cache
  );
  const participantEmails = Array.from(
    new Set(activeParticipantAccounts.map((account) => account.email.trim().toLowerCase()))
  );
  const activePartyKeys = new Set(
    activeParticipantAccounts.map((account) => `account:${account.id}`)
  );
  for (const memberId of remainingParticipants) {
    const account = await resolveActiveMemberAccount(ctx, visibilityExpense, memberId, cache);
    activePartyKeys.add(account ? `account:${account.id}` : `member:${memberId}`);
  }
  if (activePartyKeys.size <= 1) {
    return { outcome: "deleted", expense };
  }

  return {
    outcome: "modified",
    expense,
    participantUserIds: activeParticipantAccounts.map((account) => account.id),
    patch: {
      participant_member_ids: remainingParticipants,
      inactive_participant_member_ids: inactiveParticipantMemberIds,
      involved_member_ids: remainingParticipants,
      participant_emails: participantEmails,
      updated_at: Date.now()
    }
  };
}

async function accountPreparedIdentityReads(
  budget: FriendCleanupAggregateBudget,
  cache: ExpenseIdentityResolutionCache
) {
  const pendingAccounts = new Set<Promise<Doc<"accounts"> | null>>([
    ...cache.linkedIdAccounts.values(),
    ...cache.emailAccounts.values()
  ]);
  const accounts = (await Promise.all(pendingAccounts)).filter(
    (account): account is Doc<"accounts"> => account !== null
  );
  accountFriendCleanupRows(budget, accounts);
}

async function applyPreparedRemovedFriendExpense(
  ctx: MutationCtx,
  plan: Exclude<PreparedRemovedFriendExpense, { outcome: "unchanged" }>,
  visibilityRows: readonly Doc<"user_expenses">[]
) {
  if (plan.outcome === "deleted") {
    await deletePreloadedUserExpenses(ctx, visibilityRows);
    await ctx.db.delete(plan.expense._id);
    return;
  }

  await ctx.db.patch(plan.expense._id, plan.patch);
  await reconcilePreloadedUserExpenses(
    ctx,
    plan.expense.id,
    plan.participantUserIds,
    visibilityRows
  );
}

type PreparedAliasPrune = {
  accountId: Doc<"accounts">["_id"];
  nextAliasIds: string[];
  rowsToDelete: Doc<"member_aliases">[];
};

async function prepareAliasMemberIdPrune(
  ctx: MutationCtx,
  account: Doc<"accounts">,
  memberIdsToRemove: string[],
  budget: FriendCleanupAggregateBudget
): Promise<PreparedAliasPrune | null> {
  if (!Array.isArray(account.alias_member_ids)) return null;
  const removeSet = new Set(memberIdsToRemove.map((id) => normalizeMemberId(id)));
  const hasAliasToRemove = account.alias_member_ids.some((memberId: string) =>
    removeSet.has(normalizeMemberId(memberId))
  );
  if (!hasAliasToRemove) return null;
  if (account.alias_member_ids.length > MAX_LIVE_ACCOUNT_ALIASES) {
    throw new Error("Identity maintenance required: account alias cleanup must be migrated");
  }
  if (removeSet.size > MAX_LIVE_ALIAS_DELTA) {
    throw new Error("Identity maintenance required: alias cleanup delta is too large");
  }
  const nextAliasIds = account.alias_member_ids.filter(
    (memberId: string) => !removeSet.has(normalizeMemberId(memberId))
  );
  const rowsById = new Map<string, Doc<"member_aliases">>();
  for (const memberId of Array.from(removeSet).sort()) {
    chargeFriendCleanupQueries(budget, 1);
    const rows = await ctx.db
      .query("member_aliases")
      .withIndex("by_source_account_and_alias", (q) =>
        q.eq("source_account_id", account.id).eq("alias_member_id", memberId)
      )
      .take(MAX_ALIAS_ROWS_PER_MEMBER_ID + 1);
    accountFriendCleanupRows(budget, rows);
    if (rows.length > MAX_ALIAS_ROWS_PER_MEMBER_ID) {
      throw friendCleanupLimitError();
    }
    for (const row of rows) rowsById.set(String(row._id), row);
  }
  const rowsToDelete = Array.from(rowsById.values());
  reserveFriendCleanupWrites(budget, rowsToDelete.length + 1);
  return { accountId: account._id, nextAliasIds, rowsToDelete };
}

async function applyPreparedAliasPrune(
  ctx: MutationCtx,
  plan: PreparedAliasPrune | null
): Promise<number> {
  if (!plan) return 0;
  await Promise.all(plan.rowsToDelete.map((row) => ctx.db.delete(row._id)));
  await ctx.db.patch(plan.accountId, {
    alias_member_ids: plan.nextAliasIds,
    updated_at: Date.now()
  });
  return plan.rowsToDelete.length;
}

async function findDeterministicSteward(
  ctx: any,
  memberIds: Iterable<string>,
  excludedAccountId: string
): Promise<Doc<"accounts"> | null> {
  const candidates = new Map<string, Doc<"accounts">>();
  for (const memberId of memberIds) {
    const account = await findAccountByMemberId(ctx.db, memberId);
    if (account && account.id !== excludedAccountId && account.status !== "deleted") {
      candidates.set(account.id, account);
    }
  }
  return (
    Array.from(candidates.values()).sort((left, right) => left.id.localeCompare(right.id))[0] ??
    null
  );
}

function scrubDeletedAccountFromExpense(
  expense: Doc<"expenses">,
  deletedMemberIds: ReadonlySet<string>,
  deletedAccountId: string,
  deletedEmail: string,
  steward: Doc<"accounts"> | null
) {
  const normalizedDeletedEmail = deletedEmail.toLowerCase().trim();
  const ownedByDeletedAccount =
    expense.owner_account_id === deletedAccountId ||
    expense.owner_email.toLowerCase().trim() === normalizedDeletedEmail;

  return {
    owner_id: ownedByDeletedAccount && steward ? steward._id : expense.owner_id,
    owner_account_id: ownedByDeletedAccount && steward ? steward.id : expense.owner_account_id,
    owner_email: ownedByDeletedAccount && steward ? steward.email : expense.owner_email,
    participant_emails: expense.participant_emails.filter(
      (email) => email.toLowerCase().trim() !== normalizedDeletedEmail
    ),
    participants: expense.participants.map((participant) => {
      const isDeletedParticipant =
        deletedMemberIds.has(normalizeMemberId(participant.member_id)) ||
        participant.linked_account_id === deletedAccountId ||
        participant.linked_account_email?.toLowerCase().trim() === normalizedDeletedEmail;
      if (!isDeletedParticipant) return participant;
      return {
        ...participant,
        name: "Deleted User",
        linked_account_id: undefined,
        linked_account_email: undefined
      };
    }),
    updated_at: Date.now()
  };
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
  },
  step: string,
  data: Record<string, unknown>
) => {
  console.log(
    JSON.stringify({
      scope: "cleanup.hard_delete",
      ...base,
      step,
      ...data
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
    memberId: account.member_id
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
    sampleIds: sampleIds(friendIds)
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
    .withIndex("by_owner_account_id", (q: any) => q.eq("owner_account_id", account.id))
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
    sampleIds: sampleIds(groupIds)
  });
  logHardDelete(baseLog, "delete_group_expenses", {
    deletedCount: groupExpenseIds.length,
    sampleIds: sampleIds(groupExpenseIds)
  });

  const expensesByEmail = await ctx.db
    .query("expenses")
    .withIndex("by_owner_email", (q: any) => q.eq("owner_email", account.email))
    .collect();
  const expensesByAccountId = await ctx.db
    .query("expenses")
    .withIndex("by_owner_account_id", (q: any) => q.eq("owner_account_id", account.id))
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
    sampleIds: sampleIds(ownedExpenseIds)
  });

  const deletedFriendRecordIds: string[] = [];

  const linkedById = await ctx.db
    .query("account_friends")
    .withIndex("by_linked_account_id", (q: any) => q.eq("linked_account_id", account.id))
    .collect();
  for (const fr of linkedById) {
    await ctx.db.delete(fr._id);
    deletedFriendRecordIds.push(fr._id);
  }

  const linkedByEmail = await ctx.db
    .query("account_friends")
    .withIndex("by_linked_account_email", (q: any) => q.eq("linked_account_email", account.email))
    .collect();
  for (const fr of linkedByEmail) {
    if (deletedFriendRecordIds.includes(fr._id)) continue;
    await ctx.db.delete(fr._id);
    deletedFriendRecordIds.push(fr._id);
  }

  if (account.member_id) {
    const linkedByMemberId = await ctx.db
      .query("account_friends")
      .withIndex("by_linked_member_id", (q: any) => q.eq("linked_member_id", account.member_id))
      .collect();
    for (const fr of linkedByMemberId) {
      if (deletedFriendRecordIds.includes(fr._id)) continue;
      await ctx.db.delete(fr._id);
      deletedFriendRecordIds.push(fr._id);
    }
  }

  logHardDelete(baseLog, "delete_linked_friend_records", {
    deletedCount: deletedFriendRecordIds.length,
    sampleIds: sampleIds(deletedFriendRecordIds)
  });

  const incomingRequests = await ctx.db
    .query("link_requests")
    .withIndex("by_recipient_email", (q: any) => q.eq("recipient_email", account.email))
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
    sampleIds: sampleIds(requestIds)
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
    sampleIds: sampleIds(inviteIds)
  });

  let aliasesDeleted = 0;
  const aliasIds: string[] = [];
  if (account.member_id) {
    const aliasesAsCanonical = await ctx.db
      .query("member_aliases")
      .withIndex("by_canonical_member_id", (q: any) =>
        q.eq("canonical_member_id", account.member_id!)
      )
      .collect();

    for (const alias of aliasesAsCanonical) {
      await ctx.db.delete(alias._id);
      aliasesDeleted++;
      aliasIds.push(alias._id);
    }

    const aliasesAsAlias = await ctx.db
      .query("member_aliases")
      .withIndex("by_alias_member_id", (q: any) => q.eq("alias_member_id", account.member_id!))
      .collect();

    for (const alias of aliasesAsAlias) {
      await ctx.db.delete(alias._id);
      aliasesDeleted++;
      aliasIds.push(alias._id);
    }
  }
  logHardDelete(baseLog, "delete_member_aliases", {
    deletedCount: aliasesDeleted,
    sampleIds: sampleIds(aliasIds)
  });

  await ctx.db.delete(account._id);
  logHardDelete(baseLog, "complete", {
    friendsDeleted: friendIds.length,
    groupsDeleted: groupIds.length,
    groupExpensesDeleted: groupExpenseIds.length,
    expensesDeleted: ownedExpenseIds.length,
    linkedFriendRecordsDeleted: deletedFriendRecordIds.length,
    linkRequestsDeleted: deletedRequests,
    invitesDeleted: inviteIds.length,
    aliasesDeleted
  });

  return {
    success: true,
    message: `Hard deleted account ${account.email}`,
    friendsDeleted: friendIds.length,
    groupsDeleted: groupIds.length,
    expensesDeleted: ownedExpenseIds.length + groupExpenseIds.length,
    linkedFriendRecordsDeleted: deletedFriendRecordIds.length,
    aliasesDeleted
  };
}

export const deleteSelfFriends = internalMutation({
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
  }
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
  }
});

/**
 * Delete all data from the orphaned subexpenses table.
 * This table is no longer in the schema (subexpenses are embedded in expenses).
 */
export const deleteSubexpensesTable = internalMutation({
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
  }
});

export const removeLegacyFields = internalMutation({
  args: {},
  handler: async (ctx) => {
    const accounts = await ctx.db.query("accounts").collect();
    const patched = 0;
    for (const acc of accounts) {
      if ((acc as any).equivalent_member_ids !== undefined) {
        // Since equivalent_member_ids is not in the schema, we can't patch it to undefined.
        // If it exists in the document, it's already legacy data that Schema validation ignores or rejects on write.
        // We can't actually remove it via patch if the schema doesn't know about it.
        // The previous attempt to patch it failed typecheck.
        // We will just skip it.
        continue;
      }
    }
    return { patched, total: accounts.length };
  }
});

export const deleteLinkedFriend = mutation({
  args: {
    friendMemberId: v.optional(v.string()),
    // Backward-compatible alias for older clients.
    memberId: v.optional(v.string()),
    // Deprecated: ignored, account email is derived from auth context.
    accountEmail: v.optional(v.string())
  },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");
    const accountEmail = user.email.toLowerCase().trim();
    const rawMemberId = args.friendMemberId ?? args.memberId;
    if (!rawMemberId) {
      throw new Error("friendMemberId is required");
    }
    const friendMemberId = normalizeMemberId(rawMemberId);

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
        message: "Friend is not linked. Use deleteUnlinkedFriend instead."
      };
    }

    await assertIdentityMaterializationReady(ctx.db);
    const equivalentIds = await getAllEquivalentMemberIds(ctx.db, friendMemberId);
    const normalizedEquivalentIds = new Set(
      [...equivalentIds, ...(friend.local_alias_member_ids ?? [])].map(normalizeMemberId)
    );

    const userAccount = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", accountEmail))
      .unique();

    if (!userAccount) {
      return { success: false, message: "Account not found" };
    }

    let directGroupDeleted = false;
    let expensesDeleted = 0;

    const aggregateBudget = createFriendCleanupAggregateBudget();
    const ownedGroups = await collectFriendCleanupGroups(ctx, userAccount, aggregateBudget);
    const ownedExpenses = await collectFriendCleanupExpenses(ctx, userAccount, aggregateBudget);
    const handledExpenseIds = new Set<string>();
    const attachedExpensesByGroup = new Map<string, Doc<"expenses">[]>();

    for (const group of ownedGroups.values()) {
      if (
        group.is_direct &&
        group.members.some((member) =>
          matchesEquivalentMemberId(member.id, normalizedEquivalentIds)
        )
      ) {
        attachedExpensesByGroup.set(
          String(group._id),
          await collectAttachedFriendCleanupExpenses(ctx, group, aggregateBudget)
        );
      }
    }

    const groupsToDelete: Doc<"groups">[] = [];
    const expensesToDelete = new Map<string, Doc<"expenses">>();
    for (const group of ownedGroups.values()) {
      if (!group.is_direct) continue;

      const hasFriend = group.members.some((member) =>
        matchesEquivalentMemberId(member.id, normalizedEquivalentIds)
      );
      if (!hasFriend) continue;

      const attachedExpenses = attachedExpensesByGroup.get(String(group._id)) ?? [];
      if (attachedExpenses.some((expense) => !hasConsistentExpenseOwner(expense, userAccount))) {
        throw new Error("Cannot clean a group with foreign-owned expenses");
      }
      groupsToDelete.push(group);
      for (const expense of attachedExpenses) {
        expensesToDelete.set(String(expense._id), expense);
        handledExpenseIds.add(String(expense._id));
      }
    }

    const knownGroupIds = new Set(Array.from(ownedGroups.values()).map((group) => group.id));
    const knownGroupRefs = new Set(ownedGroups.keys());
    for (const expense of ownedExpenses.values()) {
      if (handledExpenseIds.has(String(expense._id))) continue;
      const hasKnownGroup =
        knownGroupIds.has(expense.group_id) ||
        (expense.group_ref !== undefined && knownGroupRefs.has(String(expense.group_ref)));
      if (!hasKnownGroup && expenseReferencesEquivalentMember(expense, normalizedEquivalentIds)) {
        expensesToDelete.set(String(expense._id), expense);
      }
    }

    const visibilityRowsByExpenseId = await collectFriendCleanupVisibilityRows(
      ctx,
      new Set(Array.from(expensesToDelete.values()).map((expense) => expense.id)),
      aggregateBudget
    );
    for (const expense of expensesToDelete.values()) {
      reserveFriendCleanupWrites(
        aggregateBudget,
        visibilityRowsByExpenseId.get(expense.id)?.length ?? 0
      );
    }
    const aliasPrunePlan = await prepareAliasMemberIdPrune(
      ctx,
      userAccount,
      equivalentIds,
      aggregateBudget
    );
    reserveFriendCleanupWrites(aggregateBudget, expensesToDelete.size + groupsToDelete.length + 1);

    for (const expense of expensesToDelete.values()) {
      await deletePreloadedUserExpenses(ctx, visibilityRowsByExpenseId.get(expense.id) ?? []);
      await ctx.db.delete(expense._id);
    }
    for (const group of groupsToDelete) await ctx.db.delete(group._id);
    directGroupDeleted = groupsToDelete.length > 0;
    expensesDeleted = expensesToDelete.size;

    const aliasesDeleted = await applyPreparedAliasPrune(ctx, aliasPrunePlan);

    await ctx.db.delete(friend._id);

    return {
      success: true,
      message: "Linked friend removed",
      directGroupDeleted,
      expensesDeleted,
      aliasesDeleted,
      linkedAccountPreserved: true
    };
  }
});

export const deleteUnlinkedFriend = mutation({
  args: {
    friendMemberId: v.optional(v.string()),
    // Backward-compatible alias for older clients.
    memberId: v.optional(v.string()),
    // Deprecated: ignored, account email is derived from auth context.
    accountEmail: v.optional(v.string())
  },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");
    const accountEmail = user.email.toLowerCase().trim();
    const rawMemberId = args.friendMemberId ?? args.memberId;
    if (!rawMemberId) {
      throw new Error("friendMemberId is required");
    }
    const friendMemberId = normalizeMemberId(rawMemberId);

    const friend = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", accountEmail).eq("member_id", friendMemberId)
      )
      .unique();

    if (!friend) {
      throw new Error("Friend not found");
    }

    if (friend.has_linked_account) {
      throw new Error("Friend is linked. Use deleteLinkedFriend instead.");
    }

    await assertIdentityMaterializationReady(ctx.db);
    const equivalentIds = await getAllEquivalentMemberIds(ctx.db, friendMemberId);
    const normalizedEquivalentIds = new Set(
      [...equivalentIds, ...(friend.local_alias_member_ids ?? [])].map(normalizeMemberId)
    );

    let groupsModified = 0;
    let expensesDeleted = 0;
    let expensesModified = 0;
    let aliasesDeleted = 0;

    const aggregateBudget = createFriendCleanupAggregateBudget();
    const ownedGroups = await collectFriendCleanupGroups(ctx, user, aggregateBudget);
    const ownedExpenses = await collectFriendCleanupExpenses(ctx, user, aggregateBudget);
    const handledExpenseIds = new Set<string>();
    const attachedExpensesByGroup = new Map<string, Doc<"expenses">[]>();

    for (const group of ownedGroups.values()) {
      if (
        group.members.some((member) =>
          matchesEquivalentMemberId(member.id, normalizedEquivalentIds)
        )
      ) {
        attachedExpensesByGroup.set(
          String(group._id),
          await collectAttachedFriendCleanupExpenses(ctx, group, aggregateBudget)
        );
      }
    }

    const groupPlans: Array<{
      group: Doc<"groups">;
      remainingMembers: Doc<"groups">["members"];
      shouldDelete: boolean;
    }> = [];
    const expensesToDelete = new Map<string, Doc<"expenses">>();
    const expensesToPrepare = new Map<string, Doc<"expenses">>();
    for (const group of ownedGroups.values()) {
      const hasFriend = group.members.some((member) =>
        matchesEquivalentMemberId(member.id, normalizedEquivalentIds)
      );
      if (!hasFriend) continue;

      const remainingMembers = group.members.filter(
        (member) => !matchesEquivalentMemberId(member.id, normalizedEquivalentIds)
      );
      const attachedExpenses = attachedExpensesByGroup.get(String(group._id)) ?? [];
      const foreignAttachedExpense = attachedExpenses.find(
        (expense) =>
          !hasConsistentExpenseOwner(expense, user) &&
          (remainingMembers.length <= 1 ||
            expenseReferencesEquivalentMember(expense, normalizedEquivalentIds))
      );
      if (foreignAttachedExpense) {
        throw new Error("Cannot clean a group with foreign-owned expenses");
      }
      const groupExpenses = attachedExpenses.filter((expense) =>
        hasConsistentExpenseOwner(expense, user)
      );

      groupPlans.push({
        group,
        remainingMembers,
        shouldDelete: remainingMembers.length <= 1
      });
      if (remainingMembers.length <= 1) {
        for (const expense of groupExpenses) {
          expensesToDelete.set(String(expense._id), expense);
          handledExpenseIds.add(String(expense._id));
        }
      } else {
        for (const expense of groupExpenses) {
          expensesToPrepare.set(String(expense._id), expense);
          handledExpenseIds.add(String(expense._id));
        }
      }
    }

    for (const expense of ownedExpenses.values()) {
      if (
        handledExpenseIds.has(String(expense._id)) ||
        !expenseReferencesEquivalentMember(expense, normalizedEquivalentIds)
      ) {
        continue;
      }
      expensesToPrepare.set(String(expense._id), expense);
    }

    const identityCache = createExpenseIdentityResolutionCache();
    const preparedExpenses = new Map<string, PreparedRemovedFriendExpense>();
    for (const [expenseDocumentId, expense] of expensesToPrepare) {
      if (expensesToDelete.has(expenseDocumentId)) continue;
      preparedExpenses.set(
        expenseDocumentId,
        await prepareEquivalentMemberRemovalFromExpense(
          ctx,
          expense,
          normalizedEquivalentIds,
          aggregateBudget,
          identityCache,
          user
        )
      );
    }
    await accountPreparedIdentityReads(aggregateBudget, identityCache);

    const visibilityExpenseIds = new Set(
      Array.from(expensesToDelete.values()).map((expense) => expense.id)
    );
    for (const plan of preparedExpenses.values()) {
      if (plan.outcome !== "unchanged") visibilityExpenseIds.add(plan.expense.id);
    }
    const visibilityRowsByExpenseId = await collectFriendCleanupVisibilityRows(
      ctx,
      visibilityExpenseIds,
      aggregateBudget
    );
    for (const expense of expensesToDelete.values()) {
      reserveFriendCleanupWrites(
        aggregateBudget,
        visibilityRowsByExpenseId.get(expense.id)?.length ?? 0
      );
    }
    for (const plan of preparedExpenses.values()) {
      if (plan.outcome === "unchanged") continue;
      const visibilityRows = visibilityRowsByExpenseId.get(plan.expense.id) ?? [];
      reserveFriendCleanupWrites(
        aggregateBudget,
        plan.outcome === "deleted"
          ? visibilityRows.length
          : visibilityWriteCount(visibilityRows, plan.participantUserIds)
      );
    }
    const aliasPrunePlan = await prepareAliasMemberIdPrune(
      ctx,
      user,
      equivalentIds,
      aggregateBudget
    );
    const preparedExpenseWriteCount = Array.from(preparedExpenses.values()).filter(
      (plan) => plan.outcome !== "unchanged"
    ).length;
    reserveFriendCleanupWrites(
      aggregateBudget,
      groupPlans.length + expensesToDelete.size + preparedExpenseWriteCount + 1
    );

    for (const groupPlan of groupPlans) {
      if (groupPlan.shouldDelete) {
        await ctx.db.delete(groupPlan.group._id);
      } else {
        await ctx.db.patch(groupPlan.group._id, {
          owner_id: user._id,
          owner_account_id: user.id,
          owner_email: user.email,
          members: groupPlan.remainingMembers,
          updated_at: Date.now()
        });
      }
    }
    groupsModified = groupPlans.length;

    for (const expense of expensesToDelete.values()) {
      await deletePreloadedUserExpenses(ctx, visibilityRowsByExpenseId.get(expense.id) ?? []);
      await ctx.db.delete(expense._id);
      expensesDeleted += 1;
    }
    for (const plan of preparedExpenses.values()) {
      if (plan.outcome === "unchanged") continue;
      await applyPreparedRemovedFriendExpense(
        ctx,
        plan,
        visibilityRowsByExpenseId.get(plan.expense.id) ?? []
      );
      if (plan.outcome === "deleted") expensesDeleted += 1;
      if (plan.outcome === "modified") expensesModified += 1;
    }

    aliasesDeleted = await applyPreparedAliasPrune(ctx, aliasPrunePlan);

    await ctx.db.delete(friend._id);

    return {
      success: true,
      message: "Unlinked friend and all traces removed",
      groupsModified,
      expensesDeleted,
      expensesModified,
      aliasesDeleted
    };
  }
});

export const hardDeleteAccount = internalMutation({
  args: { accountId: v.id("accounts") },
  handler: async (ctx, args) => {
    const account = await ctx.db.get(args.accountId);
    if (!account) {
      return { success: false, message: "Account not found" };
    }

    return await performHardDelete(ctx, account, "hardDeleteAccount");
  }
});

export const selfDeletionStatus = query({
  args: {},
  returns: v.object({ completed: v.boolean() }),
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Unauthenticated");
    }

    const receipt = await ctx.db
      .query("account_deletion_receipts")
      .withIndex("by_auth_subject", (q) => q.eq("auth_subject", identity.subject))
      .unique();
    return { completed: receipt !== null };
  }
});

export const selfDeleteAccount = mutation({
  args: { accountEmail: v.optional(v.string()) },
  returns: v.object({
    success: v.boolean(),
    state: v.union(v.literal("deleted"), v.literal("already_deleted")),
    requestId: v.string(),
    deletedAt: v.number(),
    friendshipsUnlinked: v.number(),
    expensesPreserved: v.boolean()
  }),
  handler: async (ctx, args) => {
    const { identity, user } = await getCurrentUser(ctx);
    const priorReceipt = await ctx.db
      .query("account_deletion_receipts")
      .withIndex("by_auth_subject", (q: any) => q.eq("auth_subject", identity.subject))
      .unique();
    if (priorReceipt) {
      return {
        success: true,
        state: "already_deleted" as const,
        requestId: priorReceipt.request_id,
        deletedAt: priorReceipt.deleted_at,
        friendshipsUnlinked: priorReceipt.friendships_unlinked,
        expensesPreserved: priorReceipt.expenses_preserved
      };
    }
    if (!user) {
      throw new Error("User not found");
    }

    const accountEmail = user.email.toLowerCase().trim();
    if (args.accountEmail && args.accountEmail.toLowerCase().trim() !== accountEmail) {
      throw new Error("Can only delete your own account");
    }

    const canonicalId = await resolveCanonicalMemberIdInternal(ctx.db, user.member_id ?? user.id);
    const equivalentIds = await getAllEquivalentMemberIds(ctx.db, canonicalId);
    const linkedRows = new Map<string, any>();
    const rowsByAccountId = await ctx.db
      .query("account_friends")
      .withIndex("by_linked_account_id", (q: any) => q.eq("linked_account_id", user.id))
      .collect();
    const rowsByEmail = await ctx.db
      .query("account_friends")
      .withIndex("by_linked_account_email", (q: any) => q.eq("linked_account_email", accountEmail))
      .collect();
    for (const row of [...rowsByAccountId, ...rowsByEmail]) {
      linkedRows.set(row._id, row);
    }
    for (const memberId of new Set([
      canonicalId,
      ...equivalentIds,
      ...(user.alias_member_ids ?? [])
    ])) {
      const rows = await ctx.db
        .query("account_friends")
        .withIndex("by_linked_member_id", (q: any) =>
          q.eq("linked_member_id", normalizeMemberId(memberId))
        )
        .collect();
      for (const row of rows) linkedRows.set(row._id, row);
    }

    let friendshipsUnlinked = 0;
    const deletedAt = Date.now();
    for (const friendRecord of linkedRows.values()) {
      if (friendRecord.account_email === accountEmail) continue;
      await ctx.db.patch(friendRecord._id, {
        has_linked_account: false,
        linked_account_id: undefined,
        linked_account_email: undefined,
        link_state: "ghost",
        status: "ghost",
        updated_at: deletedAt
      });
      friendshipsUnlinked++;
    }

    const deletedMemberIds = new Set(
      [canonicalId, ...equivalentIds, ...(user.alias_member_ids ?? [])].map(normalizeMemberId)
    );
    const excludedAccountIds = new Set([user.id]);
    const handledExpenseIds = new Set<string>();

    const myUserExpenses = await ctx.db
      .query("user_expenses")
      .withIndex("by_user_id", (q: any) => q.eq("user_id", user.id))
      .collect();

    const ownedGroups = new Map<string, Doc<"groups">>();
    for (const group of await ctx.db
      .query("groups")
      .withIndex("by_owner_id", (q: any) => q.eq("owner_id", user._id))
      .collect()) {
      ownedGroups.set(group._id, group);
    }
    for (const group of await ctx.db
      .query("groups")
      .withIndex("by_owner_account_id", (q: any) => q.eq("owner_account_id", user.id))
      .collect()) {
      ownedGroups.set(group._id, group);
    }
    for (const group of await ctx.db
      .query("groups")
      .withIndex("by_owner_email", (q: any) => q.eq("owner_email", accountEmail))
      .collect()) {
      ownedGroups.set(group._id, group);
    }

    for (const group of ownedGroups.values()) {
      const steward = await findDeterministicSteward(
        ctx,
        group.members
          .map((member) => member.id)
          .filter((memberId) => !deletedMemberIds.has(normalizeMemberId(memberId))),
        user.id
      );
      const groupExpensesByClientId = await ctx.db
        .query("expenses")
        .withIndex("by_group_id", (q: any) => q.eq("group_id", group.id))
        .collect();
      const groupExpensesByReference = await ctx.db
        .query("expenses")
        .withIndex("by_group_ref", (q: any) => q.eq("group_ref", group._id))
        .collect();
      const groupExpenses = Array.from(
        new Map(
          [...groupExpensesByClientId, ...groupExpensesByReference].map((expense) => [
            expense._id,
            expense
          ])
        ).values()
      );

      if (!steward) {
        for (const expense of groupExpenses) {
          await reconcileUserExpenses(ctx, expense.id, []);
          await ctx.db.delete(expense._id);
          handledExpenseIds.add(expense.id);
        }
        await ctx.db.delete(group._id);
        continue;
      }

      await ctx.db.patch(group._id, {
        owner_id: steward._id,
        owner_account_id: steward.id,
        owner_email: steward.email,
        members: group.members.map((member) =>
          deletedMemberIds.has(normalizeMemberId(member.id))
            ? {
                ...member,
                name: "Deleted User",
                profile_image_url: undefined,
                profile_avatar_color: undefined,
                is_current_user: undefined
              }
            : member
        ),
        updated_at: deletedAt
      });

      for (const expense of groupExpenses) {
        const patch = scrubDeletedAccountFromExpense(
          expense,
          deletedMemberIds,
          user.id,
          accountEmail,
          steward
        );
        await ctx.db.patch(expense._id, patch);
        await reconcileExpenseVisibility(ctx, { ...expense, ...patch }, excludedAccountIds);
        handledExpenseIds.add(expense.id);
      }
    }

    for (const visibilityRow of myUserExpenses) {
      if (handledExpenseIds.has(visibilityRow.expense_id)) continue;
      const expense = await ctx.db
        .query("expenses")
        .withIndex("by_client_id", (q: any) => q.eq("id", visibilityRow.expense_id))
        .unique();
      if (!expense) continue;

      const ownedByDeletedAccount =
        expense.owner_id === user._id ||
        expense.owner_account_id === user.id ||
        expense.owner_email.toLowerCase().trim() === accountEmail;
      const steward = ownedByDeletedAccount
        ? await findDeterministicSteward(
            ctx,
            [
              ...expense.participant_member_ids,
              ...expense.involved_member_ids,
              ...expense.participants.map((participant) => participant.member_id)
            ].filter((memberId) => !deletedMemberIds.has(normalizeMemberId(memberId))),
            user.id
          )
        : null;

      if (ownedByDeletedAccount && !steward) {
        await reconcileUserExpenses(ctx, expense.id, []);
        await ctx.db.delete(expense._id);
        continue;
      }

      const patch = scrubDeletedAccountFromExpense(
        expense,
        deletedMemberIds,
        user.id,
        accountEmail,
        steward
      );
      await ctx.db.patch(expense._id, patch);
      await reconcileExpenseVisibility(ctx, { ...expense, ...patch }, excludedAccountIds);
    }

    const ephemeralRows = new Map<string, { _id: any }>();
    for (const request of await ctx.db
      .query("link_requests")
      .withIndex("by_requester_id", (q: any) => q.eq("requester_id", user.id))
      .collect()) {
      ephemeralRows.set(request._id, request);
    }
    for (const request of await ctx.db
      .query("link_requests")
      .withIndex("by_recipient_email", (q: any) => q.eq("recipient_email", accountEmail))
      .collect()) {
      ephemeralRows.set(request._id, request);
    }
    for (const request of await ctx.db
      .query("link_requests")
      .withIndex("by_requester_email", (q: any) => q.eq("requester_email", accountEmail))
      .collect()) {
      ephemeralRows.set(request._id, request);
    }
    for (const invite of await ctx.db
      .query("invite_tokens")
      .withIndex("by_creator_id", (q: any) => q.eq("creator_id", user.id))
      .collect()) {
      ephemeralRows.set(invite._id, invite);
    }
    for (const invite of await ctx.db
      .query("invite_tokens")
      .withIndex("by_creator_email", (q: any) => q.eq("creator_email", accountEmail))
      .collect()) {
      ephemeralRows.set(invite._id, invite);
    }
    for (const request of await ctx.db
      .query("friend_requests")
      .withIndex("by_sender_id", (q: any) => q.eq("sender_id", user._id))
      .collect()) {
      ephemeralRows.set(request._id, request);
    }
    for (const request of await ctx.db
      .query("friend_requests")
      .withIndex("by_recipient_email", (q: any) => q.eq("recipient_email", accountEmail))
      .collect()) {
      ephemeralRows.set(request._id, request);
    }
    for (const row of ephemeralRows.values()) await ctx.db.delete(row._id);

    const tombstoneEmail = `deleted+${user._id}@payback.invalid`;
    const ownedAliases = await ctx.db
      .query("member_aliases")
      .withIndex("by_account_email", (q: any) => q.eq("account_email", accountEmail))
      .collect();
    for (const alias of ownedAliases) {
      await ctx.db.patch(alias._id, { account_email: tombstoneEmail });
    }

    const myFriends = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email", (q) => q.eq("account_email", accountEmail))
      .collect();
    for (const friend of myFriends) await ctx.db.delete(friend._id);

    for (const ue of myUserExpenses) await ctx.db.delete(ue._id);

    await ctx.db.insert("account_deletion_receipts", {
      auth_subject: identity.subject,
      request_id: user.id,
      deleted_at: deletedAt,
      friendships_unlinked: friendshipsUnlinked,
      expenses_preserved: true
    });
    await ctx.db.patch(user._id, {
      email: tombstoneEmail,
      display_name: "Deleted User",
      first_name: undefined,
      last_name: undefined,
      profile_image_url: undefined,
      status: "deleted",
      deleted_at: deletedAt,
      updated_at: deletedAt
    });

    return {
      success: true,
      state: "deleted" as const,
      requestId: user.id,
      deletedAt,
      friendshipsUnlinked,
      expensesPreserved: true
    };
  }
});
