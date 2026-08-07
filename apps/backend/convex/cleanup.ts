import {
  mutation,
  internalAction,
  internalMutation,
  query,
  MutationCtx
} from "./_generated/server";
import { internal } from "./_generated/api";
import { v } from "convex/values";
import { Doc, Id } from "./_generated/dataModel";
import {
  ensureCleanupEmailMaterializationScheduled,
  isCleanupEmailMaterializationReady
} from "./cleanupEmailMaterialization";
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
  getCurrentUserOrThrow,
  resolveActiveExpenseParticipantAccounts,
  resolveConsistentExpenseParticipantAccount
} from "./helpers";
import {
  deleteGroupWithVisibility,
  GroupVisibilityWriteBatch,
  patchGroupWithVisibility
} from "./groupVisibility";
import {
  applyExpenseWriteBatch,
  type ExpenseWriteOperation,
  MAX_EXPENSE_VIEWERS,
  MAX_EXPENSE_WRITE_OPERATIONS
} from "./expenseWrites";
import { isSyncMaterializationReady } from "./syncState";
import { GROUP_VISIBILITY_MATERIALIZATION_KEY } from "./migrations/groupVisibility";

// Helper to get current user or throw
async function getCurrentUser(ctx: any) {
  return await getCurrentUserOrThrow(ctx);
}

function expenseDeleteOperations(expenses: Iterable<Doc<"expenses">>): ExpenseWriteOperation[] {
  return Array.from(expenses, (expense) => ({ kind: "delete" as const, expense }));
}

async function deleteAccountSyncState(ctx: MutationCtx, accountId: Id<"accounts">): Promise<void> {
  const states = await ctx.db
    .query("account_sync_state")
    .withIndex("by_account_id", (query) => query.eq("account_id", accountId))
    .take(2);
  if (states.length > 1) {
    throw new Error(`Sync maintenance required: duplicate account state ${String(accountId)}`);
  }
  if (states[0]) await ctx.db.delete(states[0]._id);
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
        .filter((q) => q.eq(q.field("group_ref"), undefined))
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

type PreparedRemovedFriendExpense =
  | { outcome: "unchanged"; expense: Doc<"expenses"> }
  | { outcome: "deleted"; expense: Doc<"expenses"> }
  | {
      outcome: "modified";
      expense: Doc<"expenses">;
      participantAccounts: Doc<"accounts">[];
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
    participantAccounts: activeParticipantAccounts,
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

function removedFriendExpenseOperation(
  plan: Exclude<PreparedRemovedFriendExpense, { outcome: "unchanged" }>
): ExpenseWriteOperation {
  if (plan.outcome === "deleted") return { kind: "delete", expense: plan.expense };
  return {
    kind: "patch",
    expense: plan.expense,
    patch: plan.patch,
    viewerAccountIds: plan.participantAccounts.map((account) => account._id)
  };
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
    linked_participants: undefined,
    updated_at: Date.now()
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
        .withIndex("by_account_email", (q) =>
          q.eq("account_email", user.email.trim().toLowerCase())
        )
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

    const progress = await beginHardDeleteAccount(ctx, user);
    return {
      success: true,
      message: "Hard deletion started",
      requestId: progress.request_id
    };
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

    const userAccount = user;

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
    reserveFriendCleanupWrites(aggregateBudget, expensesToDelete.size + 1);

    const groupVisibilityBatch = new GroupVisibilityWriteBatch(ctx, {
      budget: {
        chargeWrites: (count) => reserveFriendCleanupWrites(aggregateBudget, count)
      }
    });
    await applyExpenseWriteBatch(ctx, expenseDeleteOperations(expensesToDelete.values()));
    for (const group of groupsToDelete) await groupVisibilityBatch.delete(group._id);
    await groupVisibilityBatch.flush();
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
          : visibilityWriteCount(
              visibilityRows,
              plan.participantAccounts.map((account) => account.id)
            )
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
      expensesToDelete.size + preparedExpenseWriteCount + 1
    );

    const groupVisibilityBatch = new GroupVisibilityWriteBatch(ctx, {
      budget: {
        chargeWrites: (count) => reserveFriendCleanupWrites(aggregateBudget, count)
      }
    });
    for (const groupPlan of groupPlans) {
      if (groupPlan.shouldDelete) {
        await groupVisibilityBatch.delete(groupPlan.group._id);
      } else {
        await groupVisibilityBatch.patch(groupPlan.group._id, {
          owner_id: user._id,
          owner_account_id: user.id,
          owner_email: user.email.trim().toLowerCase(),
          members: groupPlan.remainingMembers,
          updated_at: Date.now()
        });
      }
    }
    await groupVisibilityBatch.flush();
    groupsModified = groupPlans.length;

    const expenseOperations = expenseDeleteOperations(expensesToDelete.values());
    expensesDeleted += expensesToDelete.size;
    for (const plan of preparedExpenses.values()) {
      if (plan.outcome === "unchanged") continue;
      expenseOperations.push(removedFriendExpenseOperation(plan));
      if (plan.outcome === "deleted") expensesDeleted += 1;
      if (plan.outcome === "modified") expensesModified += 1;
    }
    await applyExpenseWriteBatch(ctx, expenseOperations);

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

    const progress = await beginHardDeleteAccount(ctx, account);
    return {
      success: true,
      message: "Hard deletion started",
      requestId: progress.request_id
    };
  }
});

export const selfDeletionStatus = query({
  args: {},
  returns: v.object({
    completed: v.boolean(),
    inProgress: v.boolean(),
    phase: v.union(v.string(), v.null()),
    progressToken: v.union(v.string(), v.null())
  }),
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Unauthenticated");
    }

    const receipt = await ctx.db
      .query("account_deletion_receipts")
      .withIndex("by_auth_subject", (q) => q.eq("auth_subject", identity.subject))
      .unique();
    if (receipt) {
      return {
        completed: true,
        inProgress: false,
        phase: "complete",
        progressToken: `complete:${receipt.request_id}:${receipt.deleted_at}`
      };
    }
    const progress = await ctx.db
      .query("account_deletion_progress")
      .withIndex("by_auth_subject", (q) => q.eq("auth_subject", identity.subject))
      .unique();
    if (progress && progress.account_auth_id !== identity.subject) {
      throw new Error("Account deletion progress does not match the authenticated account");
    }
    return {
      completed: false,
      inProgress: progress !== null,
      phase: progress?.phase ?? null,
      progressToken: progress ? selfDeletionProgressToken(progress) : null
    };
  }
});

const SELF_DELETE_BATCH_SIZE = 4;
const SELF_DELETE_MAX_MEMBER_IDS_PER_RECORD = MAX_EXPENSE_VIEWERS;
const SELF_DELETE_MAX_VISIBILITY_ROWS_PER_EXPENSE = 128;

type SelfDeletionProgress = Doc<"account_deletion_progress">;
type SelfDeletionPhase = SelfDeletionProgress["phase"];

async function collectSelfDeletionMemberIds(
  ctx: MutationCtx,
  account: Doc<"accounts">
): Promise<string[]> {
  const canonicalId = await resolveCanonicalMemberIdInternal(
    ctx.db,
    account.member_id ?? account.id
  );
  const memberIds = Array.from(
    new Set(
      [
        canonicalId,
        ...(await getAllEquivalentMemberIds(ctx.db, canonicalId)),
        ...(account.alias_member_ids ?? [])
      ]
        .map(normalizeMemberId)
        .filter(Boolean)
    )
  );
  if (memberIds.length > MAX_LIVE_ACCOUNT_ALIASES + 1) {
    throw new Error("Identity maintenance required: too many aliases for account deletion");
  }
  return memberIds;
}

const selfDeletionResponseValidator = v.object({
  success: v.boolean(),
  inProgress: v.boolean(),
  state: v.union(v.literal("deleting"), v.literal("deleted"), v.literal("already_deleted")),
  requestId: v.string(),
  deletedAt: v.number(),
  friendshipsUnlinked: v.number(),
  expensesPreserved: v.boolean(),
  phase: v.string(),
  progressToken: v.string(),
  processedCount: v.number(),
  message: v.string()
});

function selfDeletionProgressToken(progress: SelfDeletionProgress) {
  return `${progress.request_id}:${progress.phase}:${progress.processed_count}:${progress.updated_at}`;
}

function selfDeletionPendingResponse(progress: SelfDeletionProgress) {
  return {
    success: false,
    inProgress: true,
    state: "deleting" as const,
    requestId: progress.request_id,
    deletedAt: 0,
    friendshipsUnlinked: progress.friendships_unlinked,
    expensesPreserved: false,
    phase: progress.phase,
    progressToken: selfDeletionProgressToken(progress),
    processedCount: progress.processed_count,
    message: "Account deletion is still in progress"
  };
}

async function updateSelfDeletionProgress(
  ctx: MutationCtx,
  progress: SelfDeletionProgress,
  patch: Partial<
    Pick<
      SelfDeletionProgress,
      | "phase"
      | "cursor"
      | "next_cursor"
      | "member_index"
      | "friendships_unlinked"
      | "current_group_id"
      | "current_group_client_id"
      | "current_group_is_last"
      | "fence_activated"
      | "member_ids"
      | "group_visibility_ready_at_fence"
      | "shared_group_scan_completed"
    >
  >,
  processedUnits: number
): Promise<SelfDeletionProgress> {
  const updatedAt = Date.now();
  const next = {
    ...progress,
    ...patch,
    processed_count: progress.processed_count + processedUnits,
    updated_at: updatedAt
  };
  await ctx.db.patch(progress._id, {
    ...patch,
    processed_count: next.processed_count,
    updated_at: updatedAt
  });
  return next;
}

function assertSelfDeleteMemberBound(memberIds: Iterable<string>) {
  const uniqueIds = new Set(Array.from(memberIds, normalizeMemberId).filter(Boolean));
  if (uniqueIds.size > SELF_DELETE_MAX_MEMBER_IDS_PER_RECORD) {
    throw new Error("Account deletion record has too many member identities to process safely");
  }
}

function expenseStewardMemberIds(expense: Doc<"expenses">, deletedMemberIds: ReadonlySet<string>) {
  const memberIds = [
    ...expense.participant_member_ids,
    ...expense.involved_member_ids,
    ...expense.participants.map((participant) => participant.member_id)
  ].filter((memberId) => !deletedMemberIds.has(normalizeMemberId(memberId)));
  assertSelfDeleteMemberBound(memberIds);
  return memberIds;
}

async function prepareSelfDeletionMemberAccounts(
  ctx: MutationCtx,
  memberIds: Iterable<string>,
  budget: FriendCleanupAggregateBudget,
  cache: ExpenseIdentityResolutionCache
) {
  for (const memberId of new Set(Array.from(memberIds, normalizeMemberId).filter(Boolean))) {
    const key = `member:${memberId}`;
    if (!budget.identityResolutionKeys.has(key)) {
      budget.identityResolutionKeys.add(key);
      if (budget.identityResolutionKeys.size > FRIEND_CLEANUP_LIMITS.participantIdentityKeys) {
        throw friendCleanupLimitError();
      }
    }
    if (!cache.memberAccounts.has(memberId)) {
      const pendingAccount = resolveBudgetedFriendCleanupMemberAccount(ctx, memberId, budget);
      cache.memberAccounts.set(memberId, pendingAccount);
      await pendingAccount;
    }
  }
}

async function prepareSelfDeletionExpenseReads(
  ctx: MutationCtx,
  expenses: readonly Doc<"expenses">[],
  budget: FriendCleanupAggregateBudget,
  cache: ExpenseIdentityResolutionCache
) {
  accountFriendCleanupRows(budget, expenses);
  const expenseIds = new Set<string>();
  for (const expense of expenses) {
    expenseIds.add(expense.id);
    await prepareFriendCleanupIdentityReads(ctx, budget, expense, cache);
    const accounts = await resolveActiveExpenseParticipantAccounts(ctx, expense, new Set(), cache);
    accountFriendCleanupRows(budget, accounts);
  }
  await accountPreparedIdentityReads(budget, cache);
  const visibilityRows = await collectFriendCleanupVisibilityRows(ctx, expenseIds, budget);
  for (const expense of expenses) {
    const rows = visibilityRows.get(expense.id) ?? [];
    if (rows.length > SELF_DELETE_MAX_VISIBILITY_ROWS_PER_EXPENSE) {
      throw friendCleanupLimitError();
    }
    reserveFriendCleanupWrites(budget, rows.length + 1);
  }
  return visibilityRows;
}

async function findPreparedSelfDeletionSteward(
  memberIds: Iterable<string>,
  excludedAccountId: string,
  cache: ExpenseIdentityResolutionCache
) {
  const candidates = new Map<string, Doc<"accounts">>();
  for (const memberId of new Set(Array.from(memberIds, normalizeMemberId).filter(Boolean))) {
    const pendingAccount = cache.memberAccounts.get(memberId);
    if (!pendingAccount) throw new Error("Account deletion identity preflight is incomplete");
    const account = await pendingAccount;
    if (
      account &&
      account.id !== excludedAccountId &&
      account.status !== "deleting" &&
      account.status !== "deleted"
    ) {
      candidates.set(account.id, account);
    }
  }
  return (
    Array.from(candidates.values()).sort((left, right) => left.id.localeCompare(right.id))[0] ??
    null
  );
}

type PreparedSelfDeletionExpense = {
  expense: Doc<"expenses">;
  patch: ReturnType<typeof scrubDeletedAccountFromExpense> | null;
  participantAccounts: Doc<"accounts">[];
  visibilityRows: Doc<"user_expenses">[];
};

async function prepareSelfDeletionExpenseMutations(
  ctx: MutationCtx,
  expenses: readonly Doc<"expenses">[],
  account: Doc<"accounts">,
  progress: SelfDeletionProgress,
  deletedMemberIds: ReadonlySet<string>,
  excludedAccountIds: ReadonlySet<string>,
  budget: FriendCleanupAggregateBudget,
  cache: ExpenseIdentityResolutionCache
) {
  const visibilityRows = await prepareSelfDeletionExpenseReads(ctx, expenses, budget, cache);
  const plans: PreparedSelfDeletionExpense[] = [];
  for (const expense of expenses) {
    const ownerMatches =
      expense.owner_id === account._id ||
      expense.owner_account_id === account.id ||
      normalizeEmail(expense.owner_email) === normalizeEmail(progress.account_email);
    if (ownerMatches && !hasConsistentExpenseOwner(expense, account)) {
      throw new Error("Cannot delete records with a conflicting owner identity");
    }
    if (ownerMatches && progress.deletion_mode === "hard") {
      plans.push({
        expense,
        patch: null,
        participantAccounts: [],
        visibilityRows: visibilityRows.get(expense.id) ?? []
      });
      continue;
    }
    const stewardMemberIds = expenseStewardMemberIds(expense, deletedMemberIds);
    await prepareSelfDeletionMemberAccounts(ctx, stewardMemberIds, budget, cache);
    const steward = ownerMatches
      ? await findPreparedSelfDeletionSteward(stewardMemberIds, account.id, cache)
      : null;
    if (ownerMatches && !steward) {
      plans.push({
        expense,
        patch: null,
        participantAccounts: [],
        visibilityRows: visibilityRows.get(expense.id) ?? []
      });
      continue;
    }
    const patch = scrubDeletedAccountFromExpense(
      expense,
      deletedMemberIds,
      account.id,
      normalizeEmail(progress.account_email) ?? progress.account_email,
      steward
    );
    const patchedExpense = { ...expense, ...patch };
    await prepareFriendCleanupIdentityReads(ctx, budget, patchedExpense, cache);
    const participantAccounts = await resolveActiveExpenseParticipantAccounts(
      ctx,
      patchedExpense,
      excludedAccountIds,
      cache
    );
    accountFriendCleanupRows(budget, participantAccounts);
    const existingRows = visibilityRows.get(expense.id) ?? [];
    reserveFriendCleanupWrites(
      budget,
      visibilityWriteCount(
        existingRows,
        participantAccounts.map((participant) => participant.id)
      ) + 1
    );
    plans.push({ expense, patch, participantAccounts, visibilityRows: existingRows });
  }
  await accountPreparedIdentityReads(budget, cache);
  return plans;
}

function selfDeletionExpenseOperation(plan: PreparedSelfDeletionExpense): ExpenseWriteOperation {
  if (!plan.patch) return { kind: "delete", expense: plan.expense };
  return {
    kind: "patch",
    expense: plan.expense,
    patch: plan.patch,
    viewerAccountIds: plan.participantAccounts.map((account) => account._id)
  };
}

async function advanceSelfDeletionPreflight(
  ctx: MutationCtx,
  progress: SelfDeletionProgress,
  rows: readonly (Doc<"groups"> | Doc<"expenses">)[],
  continueCursor: string,
  isDone: boolean,
  nextPhase: SelfDeletionPhase,
  budget: FriendCleanupAggregateBudget,
  cache: ExpenseIdentityResolutionCache
) {
  const account = await ctx.db.get(progress.account_id);
  if (!account) throw new Error("Account deletion account no longer exists");
  chargeFriendCleanupQueries(budget, 1);
  const expenses: Doc<"expenses">[] = [];
  const groups: Doc<"groups">[] = [];
  for (const row of rows) {
    if ("description" in row) {
      if (!hasConsistentExpenseOwner(row, account)) {
        throw new Error("Cannot delete records with a conflicting owner identity");
      }
      assertSelfDeleteMemberBound([
        ...row.participant_member_ids,
        ...row.involved_member_ids,
        ...row.participants.map((participant) => participant.member_id)
      ]);
      expenses.push(row);
    } else {
      if (!hasConsistentGroupOwner(row, account)) {
        throw new Error("Cannot delete records with a conflicting owner identity");
      }
      assertSelfDeleteMemberBound(row.members.map((member) => member.id));
      groups.push(row);
    }
  }
  if (expenses.length > 0) {
    await prepareSelfDeletionExpenseReads(ctx, expenses, budget, cache);
  }
  if (groups.length > 0) {
    accountFriendCleanupRows(budget, groups);
    await prepareSelfDeletionMemberAccounts(
      ctx,
      groups.flatMap((group) => group.members.map((member) => member.id)),
      budget,
      cache
    );
  }
  return await updateSelfDeletionProgress(
    ctx,
    progress,
    isDone ? { phase: nextPhase, cursor: undefined } : { cursor: continueCursor },
    rows.length + (isDone ? 1 : 0)
  );
}

async function finishOrContinueSelfDeletionBatch(
  ctx: MutationCtx,
  progress: SelfDeletionProgress,
  processedRows: number,
  nextPhase: SelfDeletionPhase,
  patch: Partial<Pick<SelfDeletionProgress, "friendships_unlinked" | "member_index">> = {}
) {
  return await updateSelfDeletionProgress(
    ctx,
    progress,
    processedRows === 0 ? { ...patch, phase: nextPhase, cursor: undefined } : patch,
    processedRows + (processedRows === 0 ? 1 : 0)
  );
}

async function advanceSelfDeletion(
  ctx: MutationCtx,
  progress: SelfDeletionProgress,
  account: Doc<"accounts">
): Promise<SelfDeletionProgress | null> {
  const deletedMemberIds = new Set(progress.member_ids.map(normalizeMemberId));
  const excludedAccountIds = new Set([progress.account_auth_id]);
  const deletedAt = Date.now();
  const cursor = progress.cursor ?? null;
  const budget = createFriendCleanupAggregateBudget();
  const identityCache = createExpenseIdentityResolutionCache();

  switch (progress.phase) {
    case "preflight_groups_owner_id": {
      const result = await ctx.db
        .query("groups")
        .withIndex("by_owner_id", (q) => q.eq("owner_id", account._id))
        .order("asc")
        .paginate({ cursor, numItems: SELF_DELETE_BATCH_SIZE });
      return await advanceSelfDeletionPreflight(
        ctx,
        progress,
        result.page,
        result.continueCursor,
        result.isDone,
        "preflight_groups_account_id",
        budget,
        identityCache
      );
    }
    case "preflight_groups_account_id": {
      const result = await ctx.db
        .query("groups")
        .withIndex("by_owner_account_id", (q) => q.eq("owner_account_id", account.id))
        .order("asc")
        .paginate({ cursor, numItems: SELF_DELETE_BATCH_SIZE });
      return await advanceSelfDeletionPreflight(
        ctx,
        progress,
        result.page,
        result.continueCursor,
        result.isDone,
        "preflight_groups_email",
        budget,
        identityCache
      );
    }
    case "preflight_groups_email": {
      const result = await ctx.db
        .query("groups")
        .withIndex("by_owner_email", (q) => q.eq("owner_email", account.email))
        .order("asc")
        .paginate({ cursor, numItems: SELF_DELETE_BATCH_SIZE });
      return await advanceSelfDeletionPreflight(
        ctx,
        progress,
        result.page,
        result.continueCursor,
        result.isDone,
        "preflight_expenses_owner_id",
        budget,
        identityCache
      );
    }
    case "preflight_expenses_owner_id": {
      const result = await ctx.db
        .query("expenses")
        .withIndex("by_owner_id", (q) => q.eq("owner_id", account._id))
        .order("asc")
        .paginate({ cursor, numItems: SELF_DELETE_BATCH_SIZE });
      return await advanceSelfDeletionPreflight(
        ctx,
        progress,
        result.page,
        result.continueCursor,
        result.isDone,
        "preflight_expenses_account_id",
        budget,
        identityCache
      );
    }
    case "preflight_expenses_account_id": {
      const result = await ctx.db
        .query("expenses")
        .withIndex("by_owner_account_id", (q) => q.eq("owner_account_id", account.id))
        .order("asc")
        .paginate({ cursor, numItems: SELF_DELETE_BATCH_SIZE });
      return await advanceSelfDeletionPreflight(
        ctx,
        progress,
        result.page,
        result.continueCursor,
        result.isDone,
        "preflight_expenses_email",
        budget,
        identityCache
      );
    }
    case "preflight_expenses_email": {
      const result = await ctx.db
        .query("expenses")
        .withIndex("by_owner_email", (q) => q.eq("owner_email", account.email))
        .order("asc")
        .paginate({ cursor, numItems: SELF_DELETE_BATCH_SIZE });
      return await advanceSelfDeletionPreflight(
        ctx,
        progress,
        result.page,
        result.continueCursor,
        result.isDone,
        "preflight_visible_expenses",
        budget,
        identityCache
      );
    }
    case "preflight_visible_expenses": {
      chargeFriendCleanupQueries(budget, 1);
      const result = await ctx.db
        .query("user_expenses")
        .withIndex("by_user_id", (q) => q.eq("user_id", account.id))
        .order("asc")
        .paginate({ cursor, numItems: SELF_DELETE_BATCH_SIZE });
      accountFriendCleanupRows(budget, result.page);
      const expenses = new Map<string, Doc<"expenses">>();
      for (const row of result.page) {
        chargeFriendCleanupQueries(budget, 1);
        const expense = await ctx.db
          .query("expenses")
          .withIndex("by_client_id", (q) => q.eq("id", row.expense_id))
          .unique();
        if (expense) expenses.set(String(expense._id), expense);
      }
      if (expenses.size > 0) {
        await prepareSelfDeletionExpenseReads(
          ctx,
          Array.from(expenses.values()),
          budget,
          identityCache
        );
      }
      return await updateSelfDeletionProgress(
        ctx,
        progress,
        result.isDone
          ? { phase: "preflight_owned_group_select", cursor: undefined }
          : { cursor: result.continueCursor },
        result.page.length + (result.isDone ? 1 : 0)
      );
    }
    case "preflight_owned_group_select": {
      chargeFriendCleanupQueries(budget, 1);
      const result = await ctx.db
        .query("groups")
        .withIndex("by_owner_id", (q) => q.eq("owner_id", account._id))
        .order("asc")
        .paginate({ cursor, numItems: 1 });
      accountFriendCleanupRows(budget, result.page);
      const group = result.page[0];
      if (!group) {
        return await updateSelfDeletionProgress(
          ctx,
          progress,
          {
            phase: progress.fence_activated
              ? "unlink_friends_account_id"
              : "activate_deletion_fence",
            cursor: undefined
          },
          1
        );
      }
      if (!hasConsistentGroupOwner(group, account)) {
        throw new Error("Cannot delete records with a conflicting owner identity");
      }
      await prepareSelfDeletionMemberAccounts(
        ctx,
        group.members.map((member) => member.id),
        budget,
        identityCache
      );
      return await updateSelfDeletionProgress(
        ctx,
        progress,
        {
          phase: "preflight_owned_group_expenses_by_client_id",
          cursor: undefined,
          next_cursor: result.continueCursor,
          current_group_id: group._id,
          current_group_client_id: group.id,
          current_group_is_last: result.isDone
        },
        1
      );
    }
    case "preflight_owned_group_expenses_by_client_id":
    case "preflight_owned_group_expenses_by_reference": {
      if (!progress.current_group_id || !progress.current_group_client_id) {
        throw new Error("Account deletion group preflight state is incomplete");
      }
      chargeFriendCleanupQueries(budget, 1);
      const result =
        progress.phase === "preflight_owned_group_expenses_by_client_id"
          ? await ctx.db
              .query("expenses")
              .withIndex("by_group_id", (q) =>
                q.eq("group_id", progress.current_group_client_id as string)
              )
              .filter((q) => q.eq(q.field("group_ref"), undefined))
              .order("asc")
              .paginate({ cursor, numItems: SELF_DELETE_BATCH_SIZE })
          : await ctx.db
              .query("expenses")
              .withIndex("by_group_ref", (q) =>
                q.eq("group_ref", progress.current_group_id as Doc<"groups">["_id"])
              )
              .order("asc")
              .paginate({ cursor, numItems: SELF_DELETE_BATCH_SIZE });
      if (result.page.length > 0) {
        await prepareSelfDeletionExpenseReads(ctx, result.page, budget, identityCache);
      }
      if (!result.isDone) {
        return await updateSelfDeletionProgress(
          ctx,
          progress,
          { cursor: result.continueCursor },
          result.page.length
        );
      }
      if (progress.phase === "preflight_owned_group_expenses_by_client_id") {
        return await updateSelfDeletionProgress(
          ctx,
          progress,
          { phase: "preflight_owned_group_expenses_by_reference", cursor: undefined },
          result.page.length + 1
        );
      }
      return await updateSelfDeletionProgress(
        ctx,
        progress,
        progress.current_group_is_last
          ? {
              phase: progress.fence_activated
                ? "unlink_friends_account_id"
                : "activate_deletion_fence",
              cursor: undefined,
              next_cursor: undefined,
              current_group_id: undefined,
              current_group_client_id: undefined,
              current_group_is_last: undefined
            }
          : {
              phase: "preflight_owned_group_select",
              cursor: progress.next_cursor,
              next_cursor: undefined,
              current_group_id: undefined,
              current_group_client_id: undefined,
              current_group_is_last: undefined
            },
        result.page.length + 1
      );
    }
    case "activate_deletion_fence": {
      if (
        progress.fence_activated ||
        account.status === "deleting" ||
        account.status === "deleted" ||
        progress.account_id !== account._id ||
        progress.account_auth_id !== account.id ||
        normalizeEmail(progress.account_email) !== normalizeEmail(account.email)
      ) {
        throw new Error("Account deletion fence does not match the authenticated account");
      }
      const groupVisibilityReady = await isSyncMaterializationReady(
        ctx.db,
        GROUP_VISIBILITY_MATERIALIZATION_KEY
      );
      if (!groupVisibilityReady && progress.deletion_mode !== "hard") {
        throw new Error("Account deletion is temporarily unavailable while data is prepared");
      }
      const memberIds = await collectSelfDeletionMemberIds(ctx, account);
      const now = Date.now();
      await ctx.db.patch(account._id, { status: "deleting", updated_at: now });
      return await updateSelfDeletionProgress(
        ctx,
        progress,
        {
          phase: "preflight_groups_owner_id",
          cursor: undefined,
          next_cursor: undefined,
          member_index: undefined,
          current_group_id: undefined,
          current_group_client_id: undefined,
          current_group_is_last: undefined,
          fence_activated: true,
          member_ids: memberIds,
          group_visibility_ready_at_fence: groupVisibilityReady,
          shared_group_scan_completed: undefined
        },
        1
      );
    }
    case "unlink_friends_account_id":
    case "unlink_friends_email":
    case "unlink_friends_member_id": {
      const memberIndex = progress.member_index ?? 0;
      const rows =
        progress.phase === "unlink_friends_account_id"
          ? await ctx.db
              .query("account_friends")
              .withIndex("by_linked_account_id", (q) =>
                q.eq("linked_account_id", progress.account_auth_id)
              )
              .take(SELF_DELETE_BATCH_SIZE)
          : progress.phase === "unlink_friends_email"
            ? await ctx.db
                .query("account_friends")
                .withIndex("by_linked_account_email", (q) =>
                  q.eq("linked_account_email", progress.account_email)
                )
                .take(SELF_DELETE_BATCH_SIZE)
            : memberIndex < progress.member_ids.length
              ? await ctx.db
                  .query("account_friends")
                  .withIndex("by_linked_member_id", (q) =>
                    q.eq("linked_member_id", progress.member_ids[memberIndex])
                  )
                  .take(SELF_DELETE_BATCH_SIZE)
              : [];
      let newlyUnlinked = 0;
      for (const friend of rows) {
        if (normalizeEmail(friend.account_email) !== normalizeEmail(progress.account_email)) {
          newlyUnlinked += 1;
        }
        if (progress.deletion_mode === "hard") {
          await ctx.db.delete(friend._id);
        } else {
          await ctx.db.patch(friend._id, {
            has_linked_account: false,
            linked_account_id: undefined,
            linked_account_email: undefined,
            linked_member_id: undefined,
            link_state: "ghost",
            status: "ghost",
            updated_at: deletedAt
          });
        }
      }
      if (rows.length > 0) {
        return await updateSelfDeletionProgress(
          ctx,
          progress,
          { friendships_unlinked: progress.friendships_unlinked + newlyUnlinked },
          rows.length
        );
      }
      if (progress.phase === "unlink_friends_account_id") {
        return await updateSelfDeletionProgress(
          ctx,
          progress,
          { phase: "unlink_friends_email" },
          1
        );
      }
      if (progress.phase === "unlink_friends_email") {
        return await updateSelfDeletionProgress(
          ctx,
          progress,
          { phase: "unlink_friends_member_id", member_index: 0 },
          1
        );
      }
      if (memberIndex + 1 < progress.member_ids.length) {
        return await updateSelfDeletionProgress(
          ctx,
          progress,
          { member_index: memberIndex + 1 },
          1
        );
      }
      return await updateSelfDeletionProgress(
        ctx,
        progress,
        { phase: "owned_expenses", member_index: undefined },
        1
      );
    }
    case "owned_expenses": {
      chargeFriendCleanupQueries(budget, 1);
      const expenses = await ctx.db
        .query("expenses")
        .withIndex("by_owner_id", (q) => q.eq("owner_id", account._id))
        .take(SELF_DELETE_BATCH_SIZE);
      const plans = await prepareSelfDeletionExpenseMutations(
        ctx,
        expenses,
        account,
        progress,
        deletedMemberIds,
        excludedAccountIds,
        budget,
        identityCache
      );
      await applyExpenseWriteBatch(ctx, plans.map(selfDeletionExpenseOperation));
      return await finishOrContinueSelfDeletionBatch(
        ctx,
        progress,
        expenses.length,
        "visible_expenses"
      );
    }
    case "visible_expenses": {
      chargeFriendCleanupQueries(budget, 1);
      const visibilityRows = await ctx.db
        .query("user_expenses")
        .withIndex("by_user_id", (q) => q.eq("user_id", account.id))
        .take(SELF_DELETE_BATCH_SIZE);
      accountFriendCleanupRows(budget, visibilityRows);
      const expenseIds = new Set(visibilityRows.map((row) => row.expense_id));
      const expenses: Doc<"expenses">[] = [];
      for (const expenseId of expenseIds) {
        chargeFriendCleanupQueries(budget, 1);
        const expense = await ctx.db
          .query("expenses")
          .withIndex("by_client_id", (q) => q.eq("id", expenseId))
          .unique();
        if (expense) expenses.push(expense);
      }
      const plans = await prepareSelfDeletionExpenseMutations(
        ctx,
        expenses,
        account,
        progress,
        deletedMemberIds,
        excludedAccountIds,
        budget,
        identityCache
      );
      await applyExpenseWriteBatch(ctx, plans.map(selfDeletionExpenseOperation));
      const plannedExpenseIds = new Set(plans.map((plan) => plan.expense.id));
      for (const visibilityRow of visibilityRows) {
        if (!plannedExpenseIds.has(visibilityRow.expense_id))
          await ctx.db.delete(visibilityRow._id);
      }
      return await finishOrContinueSelfDeletionBatch(
        ctx,
        progress,
        visibilityRows.length,
        "owned_groups"
      );
    }
    case "owned_groups": {
      const groups = await ctx.db
        .query("groups")
        .withIndex("by_owner_id", (q) => q.eq("owner_id", account._id))
        .take(1);
      const group = groups[0];
      if (!group) {
        return await updateSelfDeletionProgress(
          ctx,
          progress,
          {
            phase: progress.group_visibility_ready_at_fence ? "shared_groups" : "shared_group_scan"
          },
          1
        );
      }
      if (!hasConsistentGroupOwner(group, account)) {
        throw new Error("Cannot delete records with a conflicting owner identity");
      }
      if (progress.deletion_mode === "hard" || group.deletion_token) {
        return await updateSelfDeletionProgress(
          ctx,
          progress,
          {
            phase: "owned_group_expenses_by_client_id",
            current_group_id: group._id,
            current_group_client_id: group.id
          },
          1
        );
      }
      const memberIds = group.members
        .map((member) => member.id)
        .filter((memberId) => !deletedMemberIds.has(normalizeMemberId(memberId)));
      assertSelfDeleteMemberBound(memberIds);
      chargeFriendCleanupQueries(budget, 1);
      accountFriendCleanupRows(budget, groups);
      await prepareSelfDeletionMemberAccounts(ctx, memberIds, budget, identityCache);
      const steward = await findPreparedSelfDeletionSteward(memberIds, account.id, identityCache);
      if (!steward) {
        return await updateSelfDeletionProgress(
          ctx,
          progress,
          {
            phase: "owned_group_expenses_by_client_id",
            current_group_id: group._id,
            current_group_client_id: group.id
          },
          1
        );
      }
      await patchGroupWithVisibility(ctx, group._id, {
        owner_id: steward._id,
        owner_account_id: steward.id,
        owner_email: steward.email.trim().toLowerCase(),
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
      return await updateSelfDeletionProgress(ctx, progress, {}, 1);
    }
    case "shared_groups": {
      chargeFriendCleanupQueries(budget, 1);
      const visibilityRows = await ctx.db
        .query("group_visibility")
        .withIndex("by_account_id_and_group_updated_at", (q) => q.eq("account_id", account._id))
        .take(1);
      accountFriendCleanupRows(budget, visibilityRows);
      const visibilityRow = visibilityRows[0];
      if (!visibilityRow) {
        return await updateSelfDeletionProgress(
          ctx,
          progress,
          { phase: "link_requests_requester_id" },
          1
        );
      }

      chargeFriendCleanupQueries(budget, 1);
      const group = await ctx.db.get(visibilityRow.group_id);
      accountFriendCleanupRows(budget, group ? [group] : []);
      if (!group) {
        await ctx.db.delete(visibilityRow._id);
        return await updateSelfDeletionProgress(ctx, progress, {}, 1);
      }
      if (hasConsistentGroupOwner(group, account)) {
        return await updateSelfDeletionProgress(ctx, progress, { phase: "owned_groups" }, 1);
      }

      await patchGroupWithVisibility(ctx, group._id, {
        members: group.members.map((member) =>
          deletedMemberIds.has(normalizeMemberId(member.id))
            ? { id: member.id, name: "Deleted User" }
            : member
        ),
        updated_at: deletedAt
      });
      return await updateSelfDeletionProgress(ctx, progress, {}, 1);
    }
    case "shared_group_scan": {
      chargeFriendCleanupQueries(budget, 1);
      const result = await ctx.db
        .query("groups")
        .order("asc")
        .paginate({ cursor, numItems: SELF_DELETE_BATCH_SIZE });
      accountFriendCleanupRows(budget, result.page);
      const matchingGroups = result.page.filter((group) =>
        group.members.some((member) => deletedMemberIds.has(normalizeMemberId(member.id)))
      );
      const ownedGroup = matchingGroups.find((group) => hasConsistentGroupOwner(group, account));
      if (ownedGroup) {
        return await updateSelfDeletionProgress(ctx, progress, { phase: "owned_groups" }, 1);
      }
      const groupVisibilityBatch = new GroupVisibilityWriteBatch(ctx);
      for (const group of matchingGroups) {
        await groupVisibilityBatch.patch(group._id, {
          members: group.members.map((member) =>
            deletedMemberIds.has(normalizeMemberId(member.id))
              ? { id: member.id, name: "Deleted User" }
              : member
          ),
          updated_at: deletedAt
        });
      }
      await groupVisibilityBatch.flush();
      return await updateSelfDeletionProgress(
        ctx,
        progress,
        result.isDone
          ? {
              phase: "link_requests_requester_id",
              cursor: undefined,
              shared_group_scan_completed: true
            }
          : { cursor: result.continueCursor },
        result.page.length + (result.isDone ? 1 : 0)
      );
    }
    case "owned_group_expenses_by_client_id":
    case "owned_group_expenses_by_reference": {
      if (!progress.current_group_id || !progress.current_group_client_id) {
        throw new Error("Account deletion group cascade state is incomplete");
      }
      const groupId = progress.current_group_id;
      const groupClientId = progress.current_group_client_id;
      chargeFriendCleanupQueries(budget, 1);
      const expenses =
        progress.phase === "owned_group_expenses_by_client_id"
          ? await ctx.db
              .query("expenses")
              .withIndex("by_group_id", (q) => q.eq("group_id", groupClientId))
              .filter((q) => q.eq(q.field("group_ref"), undefined))
              .take(SELF_DELETE_BATCH_SIZE)
          : await ctx.db
              .query("expenses")
              .withIndex("by_group_ref", (q) => q.eq("group_ref", groupId))
              .take(SELF_DELETE_BATCH_SIZE);
      accountFriendCleanupRows(budget, expenses);
      const visibilityRows = await collectFriendCleanupVisibilityRows(
        ctx,
        new Set(expenses.map((expense) => expense.id)),
        budget
      );
      for (const expense of expenses) {
        reserveFriendCleanupWrites(budget, (visibilityRows.get(expense.id)?.length ?? 0) + 1);
      }
      await applyExpenseWriteBatch(ctx, expenseDeleteOperations(expenses));
      return await finishOrContinueSelfDeletionBatch(
        ctx,
        progress,
        expenses.length,
        progress.phase === "owned_group_expenses_by_client_id"
          ? "owned_group_expenses_by_reference"
          : "finalize_owned_group"
      );
    }
    case "finalize_owned_group": {
      if (!progress.current_group_id || !progress.current_group_client_id) {
        throw new Error("Account deletion group cascade state is incomplete");
      }
      const groupId = progress.current_group_id;
      const groupClientId = progress.current_group_client_id;
      const group = await ctx.db.get(groupId);
      if (!group) {
        return await updateSelfDeletionProgress(
          ctx,
          progress,
          {
            phase: "owned_groups",
            current_group_id: undefined,
            current_group_client_id: undefined
          },
          1
        );
      }
      if (!hasConsistentGroupOwner(group, account)) {
        throw new Error("Cannot delete records with a conflicting owner identity");
      }
      const remainingByClientId = await ctx.db
        .query("expenses")
        .withIndex("by_group_id", (q) => q.eq("group_id", groupClientId))
        .filter((q) => q.eq(q.field("group_ref"), undefined))
        .first();
      if (remainingByClientId) {
        return await updateSelfDeletionProgress(
          ctx,
          progress,
          { phase: "owned_group_expenses_by_client_id" },
          1
        );
      }
      const remainingByReference = await ctx.db
        .query("expenses")
        .withIndex("by_group_ref", (q) => q.eq("group_ref", groupId))
        .first();
      if (remainingByReference) {
        return await updateSelfDeletionProgress(
          ctx,
          progress,
          { phase: "owned_group_expenses_by_reference" },
          1
        );
      }
      await deleteGroupWithVisibility(ctx, group._id);
      return await updateSelfDeletionProgress(
        ctx,
        progress,
        {
          phase: "owned_groups",
          current_group_id: undefined,
          current_group_client_id: undefined
        },
        1
      );
    }
    case "link_requests_requester_id":
    case "link_requests_recipient_email":
    case "link_requests_requester_email":
    case "invite_tokens_creator_id":
    case "invite_tokens_creator_email":
    case "friend_requests_sender_id":
    case "friend_requests_recipient_email": {
      const rows =
        progress.phase === "link_requests_requester_id"
          ? await ctx.db
              .query("link_requests")
              .withIndex("by_requester_id", (q) => q.eq("requester_id", account.id))
              .take(SELF_DELETE_BATCH_SIZE)
          : progress.phase === "link_requests_recipient_email"
            ? await ctx.db
                .query("link_requests")
                .withIndex("by_recipient_email", (q) =>
                  q.eq("recipient_email", progress.account_email)
                )
                .take(SELF_DELETE_BATCH_SIZE)
            : progress.phase === "link_requests_requester_email"
              ? await ctx.db
                  .query("link_requests")
                  .withIndex("by_requester_email", (q) =>
                    q.eq("requester_email", progress.account_email)
                  )
                  .take(SELF_DELETE_BATCH_SIZE)
              : progress.phase === "invite_tokens_creator_id"
                ? await ctx.db
                    .query("invite_tokens")
                    .withIndex("by_creator_id", (q) => q.eq("creator_id", account.id))
                    .take(SELF_DELETE_BATCH_SIZE)
                : progress.phase === "invite_tokens_creator_email"
                  ? await ctx.db
                      .query("invite_tokens")
                      .withIndex("by_creator_email", (q) =>
                        q.eq("creator_email", progress.account_email)
                      )
                      .take(SELF_DELETE_BATCH_SIZE)
                  : progress.phase === "friend_requests_sender_id"
                    ? await ctx.db
                        .query("friend_requests")
                        .withIndex("by_sender_id", (q) => q.eq("sender_id", account._id))
                        .take(SELF_DELETE_BATCH_SIZE)
                    : await ctx.db
                        .query("friend_requests")
                        .withIndex("by_recipient_email", (q) =>
                          q.eq("recipient_email", progress.account_email)
                        )
                        .take(SELF_DELETE_BATCH_SIZE);
      for (const row of rows) await ctx.db.delete(row._id);
      const nextPhaseByPhase: Record<typeof progress.phase, SelfDeletionPhase> = {
        link_requests_requester_id: "link_requests_recipient_email",
        link_requests_recipient_email: "link_requests_requester_email",
        link_requests_requester_email: "invite_tokens_creator_id",
        invite_tokens_creator_id: "invite_tokens_creator_email",
        invite_tokens_creator_email: "friend_requests_sender_id",
        friend_requests_sender_id: "friend_requests_recipient_email",
        friend_requests_recipient_email: "tombstone_aliases"
      };
      return await finishOrContinueSelfDeletionBatch(
        ctx,
        progress,
        rows.length,
        nextPhaseByPhase[progress.phase]
      );
    }
    case "tombstone_aliases": {
      if (progress.deletion_mode === "hard") {
        const provenanceAliases = await ctx.db
          .query("member_aliases")
          .withIndex("by_account_email", (q) => q.eq("account_email", progress.account_email))
          .take(SELF_DELETE_BATCH_SIZE);
        if (provenanceAliases.length > 0) {
          for (const alias of provenanceAliases) await ctx.db.delete(alias._id);
          return await updateSelfDeletionProgress(ctx, progress, {}, provenanceAliases.length);
        }

        const memberIndex = progress.member_index ?? 0;
        const memberId = progress.member_ids[memberIndex];
        if (memberId) {
          const aliasesById = new Map<string, Doc<"member_aliases">>();
          for (const alias of await ctx.db
            .query("member_aliases")
            .withIndex("by_canonical_member_id", (q) => q.eq("canonical_member_id", memberId))
            .take(SELF_DELETE_BATCH_SIZE)) {
            aliasesById.set(String(alias._id), alias);
          }
          for (const alias of await ctx.db
            .query("member_aliases")
            .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", memberId))
            .take(SELF_DELETE_BATCH_SIZE)) {
            aliasesById.set(String(alias._id), alias);
          }
          if (aliasesById.size > 0) {
            for (const alias of aliasesById.values()) await ctx.db.delete(alias._id);
            return await updateSelfDeletionProgress(ctx, progress, {}, aliasesById.size);
          }
          if (memberIndex + 1 < progress.member_ids.length) {
            return await updateSelfDeletionProgress(
              ctx,
              progress,
              { member_index: memberIndex + 1 },
              1
            );
          }
        }
        return await updateSelfDeletionProgress(
          ctx,
          progress,
          { phase: "delete_owned_friends", member_index: undefined },
          1
        );
      }
      const aliases = await ctx.db
        .query("member_aliases")
        .withIndex("by_account_email", (q) => q.eq("account_email", progress.account_email))
        .take(SELF_DELETE_BATCH_SIZE);
      for (const alias of aliases) {
        await ctx.db.patch(alias._id, { account_email: progress.tombstone_email });
      }
      return await finishOrContinueSelfDeletionBatch(
        ctx,
        progress,
        aliases.length,
        "delete_owned_friends"
      );
    }
    case "delete_owned_friends": {
      const friends = await ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (q) => q.eq("account_email", progress.account_email))
        .take(SELF_DELETE_BATCH_SIZE);
      for (const friend of friends) await ctx.db.delete(friend._id);
      return await finishOrContinueSelfDeletionBatch(
        ctx,
        progress,
        friends.length,
        "delete_visibility"
      );
    }
    case "delete_visibility": {
      const rows = await ctx.db
        .query("user_expenses")
        .withIndex("by_user_id", (q) => q.eq("user_id", account.id))
        .take(SELF_DELETE_BATCH_SIZE);
      for (const row of rows) await ctx.db.delete(row._id);
      return await finishOrContinueSelfDeletionBatch(ctx, progress, rows.length, "finalize");
    }
    case "finalize": {
      const remainingGroups = [
        await ctx.db
          .query("groups")
          .withIndex("by_owner_id", (q) => q.eq("owner_id", account._id))
          .first(),
        await ctx.db
          .query("groups")
          .withIndex("by_owner_account_id", (q) => q.eq("owner_account_id", account.id))
          .first(),
        await ctx.db
          .query("groups")
          .withIndex("by_owner_email", (q) => q.eq("owner_email", progress.account_email))
          .first()
      ].filter((group): group is Doc<"groups"> => group !== null);
      for (const group of remainingGroups) {
        if (!hasConsistentGroupOwner(group, account)) {
          throw new Error("Cannot delete records with a conflicting owner identity");
        }
      }
      if (remainingGroups.length > 0) {
        return await updateSelfDeletionProgress(ctx, progress, { phase: "owned_groups" }, 1);
      }

      if (
        progress.group_visibility_ready_at_fence === false &&
        !progress.shared_group_scan_completed
      ) {
        return await updateSelfDeletionProgress(ctx, progress, { phase: "shared_group_scan" }, 1);
      }
      if (progress.group_visibility_ready_at_fence) {
        const remainingSharedGroup = await ctx.db
          .query("group_visibility")
          .withIndex("by_account_id_and_group_updated_at", (q) => q.eq("account_id", account._id))
          .first();
        if (remainingSharedGroup) {
          return await updateSelfDeletionProgress(ctx, progress, { phase: "shared_groups" }, 1);
        }
      }

      const remainingExpenses = [
        await ctx.db
          .query("expenses")
          .withIndex("by_owner_id", (q) => q.eq("owner_id", account._id))
          .first(),
        await ctx.db
          .query("expenses")
          .withIndex("by_owner_account_id", (q) => q.eq("owner_account_id", account.id))
          .first(),
        await ctx.db
          .query("expenses")
          .withIndex("by_owner_email", (q) => q.eq("owner_email", progress.account_email))
          .first()
      ].filter((expense): expense is Doc<"expenses"> => expense !== null);
      for (const expense of remainingExpenses) {
        if (!hasConsistentExpenseOwner(expense, account)) {
          throw new Error("Cannot delete records with a conflicting owner identity");
        }
      }
      if (remainingExpenses.length > 0) {
        return await updateSelfDeletionProgress(ctx, progress, { phase: "owned_expenses" }, 1);
      }

      const remainingLinkedFriend =
        (await ctx.db
          .query("account_friends")
          .withIndex("by_linked_account_id", (q) => q.eq("linked_account_id", account.id))
          .first()) ??
        (await ctx.db
          .query("account_friends")
          .withIndex("by_linked_account_email", (q) =>
            q.eq("linked_account_email", progress.account_email)
          )
          .first());
      if (remainingLinkedFriend) {
        return await updateSelfDeletionProgress(
          ctx,
          progress,
          { phase: "unlink_friends_account_id", member_index: undefined },
          1
        );
      }
      for (let memberIndex = 0; memberIndex < progress.member_ids.length; memberIndex += 1) {
        const linkedByMember = await ctx.db
          .query("account_friends")
          .withIndex("by_linked_member_id", (q) =>
            q.eq("linked_member_id", progress.member_ids[memberIndex])
          )
          .first();
        if (linkedByMember) {
          return await updateSelfDeletionProgress(
            ctx,
            progress,
            { phase: "unlink_friends_member_id", member_index: memberIndex },
            1
          );
        }
      }

      const remainingVisibility = await ctx.db
        .query("user_expenses")
        .withIndex("by_user_id", (q) => q.eq("user_id", account.id))
        .first();
      if (remainingVisibility) {
        return await updateSelfDeletionProgress(ctx, progress, { phase: "visible_expenses" }, 1);
      }

      const remainingLinkRequest =
        (await ctx.db
          .query("link_requests")
          .withIndex("by_requester_id", (q) => q.eq("requester_id", account.id))
          .first()) ??
        (await ctx.db
          .query("link_requests")
          .withIndex("by_recipient_email", (q) => q.eq("recipient_email", progress.account_email))
          .first()) ??
        (await ctx.db
          .query("link_requests")
          .withIndex("by_requester_email", (q) => q.eq("requester_email", progress.account_email))
          .first());
      if (remainingLinkRequest) {
        return await updateSelfDeletionProgress(
          ctx,
          progress,
          { phase: "link_requests_requester_id" },
          1
        );
      }
      const remainingInvite =
        (await ctx.db
          .query("invite_tokens")
          .withIndex("by_creator_id", (q) => q.eq("creator_id", account.id))
          .first()) ??
        (await ctx.db
          .query("invite_tokens")
          .withIndex("by_creator_email", (q) => q.eq("creator_email", progress.account_email))
          .first());
      if (remainingInvite) {
        return await updateSelfDeletionProgress(
          ctx,
          progress,
          { phase: "invite_tokens_creator_id" },
          1
        );
      }
      const remainingFriendRequest =
        (await ctx.db
          .query("friend_requests")
          .withIndex("by_sender_id", (q) => q.eq("sender_id", account._id))
          .first()) ??
        (await ctx.db
          .query("friend_requests")
          .withIndex("by_recipient_email", (q) => q.eq("recipient_email", progress.account_email))
          .first());
      if (remainingFriendRequest) {
        return await updateSelfDeletionProgress(
          ctx,
          progress,
          { phase: "friend_requests_sender_id" },
          1
        );
      }
      const remainingAlias = await ctx.db
        .query("member_aliases")
        .withIndex("by_account_email", (q) => q.eq("account_email", progress.account_email))
        .first();
      if (remainingAlias) {
        return await updateSelfDeletionProgress(ctx, progress, { phase: "tombstone_aliases" }, 1);
      }
      const remainingOwnedFriend = await ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (q) => q.eq("account_email", progress.account_email))
        .first();
      if (remainingOwnedFriend) {
        return await updateSelfDeletionProgress(
          ctx,
          progress,
          { phase: "delete_owned_friends" },
          1
        );
      }

      const existingReceipt = await ctx.db
        .query("account_deletion_receipts")
        .withIndex("by_auth_subject", (q) => q.eq("auth_subject", progress.auth_subject))
        .unique();
      if (!existingReceipt) {
        await ctx.db.insert("account_deletion_receipts", {
          auth_subject: progress.auth_subject,
          account_id: account._id,
          account_email: progress.account_email,
          normalized_account_email: normalizeEmail(progress.account_email),
          request_id: progress.request_id,
          deleted_at: deletedAt,
          friendships_unlinked: progress.friendships_unlinked,
          expenses_preserved: progress.deletion_mode !== "hard"
        });
      } else if (progress.deletion_mode === "hard") {
        await ctx.db.patch(existingReceipt._id, {
          account_id: account._id,
          account_email: progress.account_email,
          normalized_account_email: normalizeEmail(progress.account_email),
          request_id: progress.request_id,
          deleted_at: deletedAt,
          friendships_unlinked: Math.max(
            existingReceipt.friendships_unlinked,
            progress.friendships_unlinked
          ),
          expenses_preserved: false
        });
      }
      if (progress.deletion_mode === "hard") {
        await deleteAccountSyncState(ctx, account._id);
        await ctx.db.delete(account._id);
      } else {
        await ctx.db.patch(account._id, {
          email: progress.tombstone_email,
          normalized_email: normalizeEmail(progress.tombstone_email),
          display_name: "Deleted User",
          first_name: undefined,
          last_name: undefined,
          profile_image_url: undefined,
          status: "deleted",
          deleted_at: deletedAt,
          updated_at: deletedAt
        });
      }
      await ctx.db.delete(progress._id);
      return null;
    }
  }
}

export const selfDeleteAccount = mutation({
  args: {
    accountEmail: v.optional(v.string()),
    clientCapability: v.optional(v.literal("bounded_progress_v1"))
  },
  returns: selfDeletionResponseValidator,
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");
    if (args.clientCapability !== "bounded_progress_v1") {
      throw new Error("Please update PayBack before deleting your account");
    }
    const priorReceipt = await ctx.db
      .query("account_deletion_receipts")
      .withIndex("by_auth_subject", (q) => q.eq("auth_subject", identity.subject))
      .unique();
    if (priorReceipt) {
      return {
        success: true,
        inProgress: false,
        state: "already_deleted" as const,
        requestId: priorReceipt.request_id,
        deletedAt: priorReceipt.deleted_at,
        friendshipsUnlinked: priorReceipt.friendships_unlinked,
        expensesPreserved: priorReceipt.expenses_preserved,
        phase: "complete",
        progressToken: `complete:${priorReceipt.request_id}:${priorReceipt.deleted_at}`,
        processedCount: 0,
        message: "Account was already deleted"
      };
    }
    if (!(await isCleanupEmailMaterializationReady(ctx))) {
      await ensureCleanupEmailMaterializationScheduled(ctx);
      return {
        success: false,
        inProgress: true,
        state: "deleting" as const,
        requestId: `maintenance:${identity.subject}`,
        deletedAt: 0,
        friendshipsUnlinked: 0,
        expensesPreserved: false,
        phase: "prepare_cleanup_email",
        progressToken: `maintenance:${identity.subject}`,
        processedCount: 0,
        message: "Account maintenance is in progress; deletion will resume shortly"
      };
    }
    let progress = await ctx.db
      .query("account_deletion_progress")
      .withIndex("by_auth_subject", (q) => q.eq("auth_subject", identity.subject))
      .unique();
    let user: Doc<"accounts"> | null;
    if (progress) {
      user = await ctx.db.get(progress.account_id);
    } else {
      const identityEmail = normalizeEmail(identity.email);
      if (!identityEmail) {
        throw new Error("Authenticated identity email is invalid");
      }
      const subjectUsers = await ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", identity.subject))
        .take(2);
      if (subjectUsers.length > 1) {
        throw new Error("Authenticated account identity is ambiguous");
      }
      user = subjectUsers[0] ?? null;
      if (user && normalizeEmail(user.email) !== identityEmail) {
        throw new Error("Authenticated identity does not match the account email");
      }
    }
    if (!user || user.status === "deleted") throw new Error("User not found");
    if (user.id !== identity.subject) {
      throw new Error("Authenticated identity does not own this account");
    }

    const normalizedAccountEmail = normalizeEmail(user.email);
    if (!normalizedAccountEmail) throw new Error("User email is invalid");
    if (args.accountEmail && normalizeEmail(args.accountEmail) !== normalizedAccountEmail) {
      throw new Error("Can only delete your own account");
    }

    if (progress) {
      if (
        progress.account_id !== user._id ||
        progress.account_auth_id !== user.id ||
        normalizeEmail(progress.account_email) !== normalizedAccountEmail
      ) {
        throw new Error("Account deletion progress does not match the authenticated account");
      }
      if (progress.account_email !== normalizedAccountEmail) {
        await ctx.db.patch(progress._id, {
          account_email: normalizedAccountEmail,
          updated_at: Date.now()
        });
        progress = (await ctx.db.get(progress._id)) ?? progress;
      }
      if (
        (progress.fence_activated && user.status !== "deleting") ||
        (!progress.fence_activated && user.status === "deleting")
      ) {
        throw new Error("Account deletion fence does not match the authenticated account");
      }
      if (progress.fence_activated === undefined) {
        progress = await updateSelfDeletionProgress(
          ctx,
          progress,
          {
            phase: "preflight_groups_owner_id",
            cursor: undefined,
            next_cursor: undefined,
            member_index: undefined,
            current_group_id: undefined,
            current_group_client_id: undefined,
            current_group_is_last: undefined,
            fence_activated: false
          },
          1
        );
        return selfDeletionPendingResponse(progress);
      }
      if (progress.fence_activated && progress.group_visibility_ready_at_fence === undefined) {
        progress = await updateSelfDeletionProgress(
          ctx,
          progress,
          {
            member_ids: await collectSelfDeletionMemberIds(ctx, user),
            group_visibility_ready_at_fence: false,
            shared_group_scan_completed: false
          },
          1
        );
      }
    } else {
      if (user.status === "deleting") {
        throw new Error("Account deletion progress is missing for a fenced account");
      }
      const memberIds = await collectSelfDeletionMemberIds(ctx, user);
      const now = Date.now();
      const progressId = await ctx.db.insert("account_deletion_progress", {
        auth_subject: identity.subject,
        account_id: user._id,
        account_auth_id: user.id,
        account_email: normalizedAccountEmail,
        member_ids: memberIds,
        request_id: user.id,
        tombstone_email: `deleted+${user._id}@payback.invalid`,
        deletion_mode: "soft",
        phase: "preflight_groups_owner_id",
        fence_activated: false,
        friendships_unlinked: 0,
        processed_count: 0,
        started_at: now,
        updated_at: now
      });
      progress = await ctx.db.get(progressId);
      if (!progress) throw new Error("Unable to initialize account deletion");
    }

    const next = await advanceSelfDeletion(ctx, progress, user);
    if (next) return selfDeletionPendingResponse(next);

    const receipt = await ctx.db
      .query("account_deletion_receipts")
      .withIndex("by_auth_subject", (q) => q.eq("auth_subject", identity.subject))
      .unique();
    if (!receipt) throw new Error("Account deletion did not produce a final receipt");
    return {
      success: true,
      inProgress: false,
      state: "deleted" as const,
      requestId: receipt.request_id,
      deletedAt: receipt.deleted_at,
      friendshipsUnlinked: receipt.friendships_unlinked,
      expensesPreserved: receipt.expenses_preserved,
      phase: "complete",
      progressToken: `complete:${receipt.request_id}:${receipt.deleted_at}`,
      processedCount: progress.processed_count + 1,
      message: "Account deletion completed"
    };
  }
});

export async function beginHardDeleteAccount(ctx: MutationCtx, account: Doc<"accounts">) {
  const [progressByAccount, progressBySubject] = await Promise.all([
    ctx.db
      .query("account_deletion_progress")
      .withIndex("by_account_id", (query) => query.eq("account_id", account._id))
      .unique(),
    ctx.db
      .query("account_deletion_progress")
      .withIndex("by_auth_subject", (query) => query.eq("auth_subject", account.id))
      .unique()
  ]);
  if (progressByAccount && progressBySubject && progressByAccount._id !== progressBySubject._id) {
    throw new Error("Conflicting account deletion progress requires maintenance");
  }
  const existing = progressByAccount ?? progressBySubject;
  if (existing) {
    const accountEmail = normalizeEmail(account.email);
    if (
      existing.account_id !== account._id ||
      existing.account_auth_id !== account.id ||
      existing.auth_subject !== account.id
    ) {
      throw new Error("Hard deletion progress does not match the account identity");
    }
    if (normalizeEmail(existing.account_email) !== normalizeEmail(accountEmail)) {
      throw new Error("Hard deletion progress does not match the account email");
    }
    if (existing.account_email !== accountEmail) {
      await ctx.db.patch(existing._id, { account_email: accountEmail, updated_at: Date.now() });
    }
    if (existing.deletion_mode !== "hard") {
      const canPromoteWithoutReconciliation =
        existing.phase.startsWith("preflight_") || existing.phase === "activate_deletion_fence";
      if (!canPromoteWithoutReconciliation) {
        throw new Error(
          "Soft deletion is already applying changes and cannot be promoted without reconciliation"
        );
      }
      const isAlreadyFenced = existing.fence_activated === true || account.status === "deleting";
      await ctx.db.patch(existing._id, {
        deletion_mode: "hard",
        phase: "preflight_groups_owner_id",
        cursor: undefined,
        next_cursor: undefined,
        member_index: undefined,
        current_group_id: undefined,
        current_group_client_id: undefined,
        current_group_is_last: undefined,
        fence_activated: isAlreadyFenced,
        group_visibility_ready_at_fence: isAlreadyFenced
          ? existing.group_visibility_ready_at_fence
          : undefined,
        shared_group_scan_completed: undefined,
        hard_delete_status: "pending",
        hard_delete_retry_count: 0,
        hard_delete_last_error: undefined,
        updated_at: Date.now()
      });
    } else if (existing.hard_delete_status === "failed") {
      await ctx.db.patch(existing._id, {
        hard_delete_status: "pending",
        hard_delete_retry_count: 0,
        hard_delete_last_error: undefined,
        updated_at: Date.now()
      });
    }
    await ctx.scheduler.runAfter(0, internal.cleanup.advanceHardDeleteAccount, {
      progressId: existing._id
    });
    return (await ctx.db.get(existing._id)) ?? existing;
  }
  if (account.status === "deleting") {
    throw new Error("Account deletion progress is missing for a fenced account");
  }

  const memberIds = await collectSelfDeletionMemberIds(ctx, account);
  const accountEmail = normalizeEmail(account.email);
  if (!accountEmail) throw new Error("Hard deletion account email is invalid");
  const now = Date.now();
  const progressId = await ctx.db.insert("account_deletion_progress", {
    auth_subject: account.id,
    account_id: account._id,
    account_auth_id: account.id,
    account_email: accountEmail,
    member_ids: memberIds,
    request_id: `admin:${crypto.randomUUID()}`,
    tombstone_email: `deleted+${account._id}@payback.invalid`,
    deletion_mode: "hard",
    hard_delete_status: "pending",
    hard_delete_retry_count: 0,
    phase: "preflight_groups_owner_id",
    fence_activated: account.status === "deleted",
    group_visibility_ready_at_fence: account.status === "deleted" ? false : undefined,
    shared_group_scan_completed: account.status === "deleted" ? false : undefined,
    friendships_unlinked: 0,
    processed_count: 0,
    started_at: now,
    updated_at: now
  });
  const progress = await ctx.db.get(progressId);
  if (!progress) throw new Error("Unable to initialize hard deletion");
  await ctx.scheduler.runAfter(0, internal.cleanup.advanceHardDeleteAccount, { progressId });
  return progress;
}

export const advanceHardDeleteAccountStep = internalMutation({
  args: { progressId: v.id("account_deletion_progress") },
  handler: async (ctx, args) => {
    const progress = await ctx.db.get(args.progressId);
    if (!progress) return null;
    if (progress.hard_delete_status === "failed") return null;
    if (progress.deletion_mode !== "hard") {
      throw new Error("Hard deletion worker received a soft deletion request");
    }
    if (!(await isCleanupEmailMaterializationReady(ctx))) {
      await ensureCleanupEmailMaterializationScheduled(ctx);
      await ctx.scheduler.runAfter(2_000, internal.cleanup.advanceHardDeleteAccount, {
        progressId: progress._id
      });
      return null;
    }
    const account = await ctx.db.get(progress.account_id);
    if (!account) throw new Error("Hard deletion account no longer exists");
    const next = await advanceSelfDeletion(ctx, progress, account);
    if (next) {
      await ctx.scheduler.runAfter(0, internal.cleanup.advanceHardDeleteAccount, {
        progressId: next._id
      });
    }
    return null;
  }
});

export const recordHardDeleteFailure = internalMutation({
  args: { progressId: v.id("account_deletion_progress"), error: v.string() },
  handler: async (ctx, args) => {
    const progress = await ctx.db.get(args.progressId);
    if (!progress || progress.deletion_mode !== "hard") return null;
    const retryCount = (progress.hard_delete_retry_count ?? 0) + 1;
    if (retryCount < 3) {
      await ctx.db.patch(progress._id, {
        hard_delete_status: "pending",
        hard_delete_retry_count: retryCount,
        hard_delete_last_error: args.error.slice(0, 256),
        updated_at: Date.now()
      });
      await ctx.scheduler.runAfter(0, internal.cleanup.advanceHardDeleteAccount, {
        progressId: progress._id
      });
    } else {
      await ctx.db.patch(progress._id, {
        hard_delete_status: "failed",
        hard_delete_retry_count: retryCount,
        hard_delete_last_error: args.error.slice(0, 256),
        updated_at: Date.now()
      });
    }
    return null;
  }
});

export const advanceHardDeleteAccount = internalAction({
  args: { progressId: v.id("account_deletion_progress") },
  handler: async (ctx, args) => {
    try {
      await ctx.runMutation(internal.cleanup.advanceHardDeleteAccountStep, args);
    } catch (error) {
      await ctx.runMutation(internal.cleanup.recordHardDeleteFailure, {
        progressId: args.progressId,
        error: String(error)
      });
    }
    return null;
  }
});
