import { query, internalQuery, mutation, DatabaseReader, MutationCtx } from "./_generated/server";
import { Doc, Id } from "./_generated/dataModel";
import { getConvexSize, type Value, v } from "convex/values";
import {
  assertIdentityMaterializationReady,
  findAccountByMemberId,
  findAliasByAliasMemberId,
  getEquivalentAliasMemberIds,
  IDENTITY_MATERIALIZATION_KEY,
  normalizeMemberId,
  normalizeMemberIds
} from "./identity";
import {
  canonicalizeExpenseParticipantLinks,
  createExpenseIdentityResolutionCache,
  getCurrentUserOrThrow,
  resolveActiveExpenseParticipantAccounts
} from "./helpers";
import {
  isGhostFriendIdentity,
  provenFriendLinkQueryWork,
  resolveProvenFriendLink
} from "./friendLinkProvenance";
import { GroupVisibilityWriteBatch } from "./groupVisibility";
import { applyExpenseWriteBatch, type ExpenseWriteOperation } from "./expenseWrites";

/**
 * Internal helper for transitive alias resolution.
 * Follows the alias chain until we find the canonical member ID.
 *
 * If A→B and B→C, then resolving A returns C.
 * If no alias exists, returns the input ID unchanged.
 * Includes cycle protection via visited set.
 */
export async function resolveCanonicalMemberIdInternal(
  db: DatabaseReader,
  memberId: string,
  visited: Set<string> = new Set()
): Promise<string> {
  const normalizedMemberId = normalizeMemberId(memberId);

  // Cycle protection: if we've seen this ID, return it to break the cycle
  if (visited.has(normalizedMemberId)) {
    return normalizedMemberId;
  }
  visited.add(normalizedMemberId);

  const account = await findAccountByMemberId(db, memberId);
  if (account?.member_id) {
    return normalizeMemberId(account.member_id);
  }

  // Look up if this memberId is an alias pointing to something else
  const alias = await findAliasByAliasMemberId(db, memberId);

  if (!alias) {
    // No alias exists - this is either the canonical ID or an unlinked member
    return normalizedMemberId;
  }

  // Recursively resolve the canonical_member_id (for transitive resolution)
  return resolveCanonicalMemberIdInternal(db, alias.canonical_member_id, visited);
}

/**
 * Resolves a member ID to its canonical form.
 *
 * Use case: When looking up a member, pass through this to ensure you're
 * working with the canonical ID, not an alias.
 *
 * Transitive: if A→B and B→C, resolving A returns C.
 * No alias: returns the input ID unchanged.
 */
export const resolveCanonicalMemberId = query({
  args: { memberId: v.string() },
  handler: async (ctx, args) => {
    return await resolveCanonicalMemberIdInternal(ctx.db, args.memberId);
  }
});

/**
 * Internal query version for use within other Convex functions.
 * Avoids auth overhead when called internally.
 */
export const resolveCanonicalMemberIdInternalQuery = internalQuery({
  args: { memberId: v.string() },
  handler: async (ctx, args) => {
    return await resolveCanonicalMemberIdInternal(ctx.db, args.memberId);
  }
});

/**
 * Gets all aliases that point to a canonical member ID.
 *
 * Use case: When you need to find all member IDs that should be
 * considered "the same person" as the canonical ID.
 *
 * Returns: Array of alias_member_id strings that resolve to this canonical ID.
 * Note: This is NOT transitive - it only returns direct aliases.
 */
export const getAliasesForMember = query({
  args: { canonicalMemberId: v.string() },
  handler: async (ctx, args) => {
    return await getEquivalentAliasMemberIds(ctx.db, args.canonicalMemberId);
  }
});

/**
 * Internal helper to get all member IDs that resolve to the same canonical ID.
 * Returns the canonical ID plus all aliases pointing to it.
 *
 * Useful for membership checks: user.member_id might be canonical,
 * but group member might have an alias ID.
 */
export async function getAllEquivalentMemberIds(
  db: DatabaseReader,
  memberId: string
): Promise<string[]> {
  // First resolve to canonical
  const normalizedMemberId = normalizeMemberId(memberId);
  const canonicalId = await resolveCanonicalMemberIdInternal(db, normalizedMemberId);

  // Get all aliases pointing to this canonical
  const aliasIds = await getEquivalentAliasMemberIds(db, canonicalId);

  // Return canonical + all aliases (deduplicated)
  const allIds = new Set([canonicalId, ...aliasIds]);

  // Also include the original input in case it's neither canonical nor alias yet
  allIds.add(normalizedMemberId);

  return Array.from(allIds);
}

export async function findMergeFriendRecordByMemberId(
  ctx: MutationCtx,
  accountEmail: string,
  memberId: string,
  readBudget: MergeReadBudget,
  options: { includeLinkedLocalAliases?: boolean } = {}
) {
  const normalizedMemberId = normalizeMemberId(memberId);
  accountMergeQueriesForLimit(readBudget, 1);
  let record = await ctx.db
    .query("account_friends")
    .withIndex("by_account_email_and_member_id", (q) =>
      q.eq("account_email", accountEmail).eq("member_id", normalizedMemberId)
    )
    .unique();
  accountMergeRowsForLimit(readBudget, record ? [record] : []);

  if (record) return record;

  if (memberId !== normalizedMemberId) {
    accountMergeQueriesForLimit(readBudget, 1);
    record = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", accountEmail).eq("member_id", memberId)
      )
      .unique();
    accountMergeRowsForLimit(readBudget, record ? [record] : []);
    if (record) return record;
  }

  const allFriends = await collectSequentialMergeIndexRows(
    readBudget,
    async (cursor, limit) =>
      await ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (q) => q.eq("account_email", accountEmail))
        .order("asc")
        .paginate({ cursor, numItems: limit }),
    () => accountMergeQueriesForLimit(readBudget, 1),
    mergeCanonicalizationLimits.friendRecords + 1
  );

  if (allFriends.length > mergeCanonicalizationLimits.friendRecords) {
    throw mergeWorkLimitError();
  }

  const primaryMatch = allFriends.find(
    (friend) => normalizeMemberId(friend.member_id) === normalizedMemberId
  );
  if (primaryMatch || options.includeLinkedLocalAliases !== true) return primaryMatch;

  const localAliasMatches = allFriends.filter(
    (friend) =>
      (friend.has_linked_account ||
        friend.link_state === "linked" ||
        Boolean(friend.linked_account_id) ||
        Boolean(friend.linked_account_email) ||
        Boolean(friend.linked_member_id)) &&
      normalizeMemberIds(friend.local_alias_member_ids).includes(normalizedMemberId)
  );
  if (localAliasMatches.length > 1) {
    throw new Error("Identity maintenance required: duplicate local friend aliases");
  }
  return localAliasMatches[0];
}

export async function findMergeMaterializedAliasByMemberId(
  ctx: MutationCtx,
  memberId: string,
  readBudget: MergeReadBudget
) {
  const normalizedMemberId = normalizeMemberId(memberId);
  accountMergeQueriesForLimit(readBudget, 1);
  const alias = await ctx.db
    .query("member_aliases")
    .withIndex("by_alias_member_id_and_source", (q) =>
      q.eq("alias_member_id", normalizedMemberId).eq("materialization_source", "account_alias")
    )
    .first();
  accountMergeRowsForLimit(readBudget, alias ? [alias] : []);
  return alias;
}

export async function resolveMergeAccountByMemberId(
  ctx: MutationCtx,
  memberId: string,
  readBudget: MergeReadBudget
) {
  let currentMemberId = normalizeMemberId(memberId);
  const visited = new Set<string>();
  let hasMaterializedAlias = false;

  for (let depth = 0; depth < 20; depth += 1) {
    if (!currentMemberId || visited.has(currentMemberId)) {
      return { account: null, canonicalMemberId: currentMemberId, hasMaterializedAlias };
    }
    visited.add(currentMemberId);

    accountMergeQueriesForLimit(readBudget, 1);
    const account = await ctx.db
      .query("accounts")
      .withIndex("by_member_id", (q) => q.eq("member_id", currentMemberId))
      .first();
    accountMergeRowsForLimit(readBudget, account ? [account] : []);
    if (account) {
      return {
        account,
        canonicalMemberId: account.member_id
          ? normalizeMemberId(account.member_id)
          : currentMemberId,
        hasMaterializedAlias
      };
    }

    const alias = await findMergeMaterializedAliasByMemberId(ctx, currentMemberId, readBudget);
    if (!alias) {
      return { account: null, canonicalMemberId: currentMemberId, hasMaterializedAlias };
    }
    hasMaterializedAlias = true;
    currentMemberId = normalizeMemberId(alias.canonical_member_id);
  }

  return { account: null, canonicalMemberId: currentMemberId, hasMaterializedAlias };
}

export async function findMergeAccountByAuthIdOrDocId(
  ctx: MutationCtx,
  accountId: string,
  readBudget: MergeReadBudget
) {
  const trimmedAccountId = accountId.trim();
  if (!trimmedAccountId) return null;
  accountMergeQueriesForLimit(readBudget, 1);
  const account = await ctx.db
    .query("accounts")
    .withIndex("by_auth_id", (q) => q.eq("id", trimmedAccountId))
    .unique();
  accountMergeRowsForLimit(readBudget, account ? [account] : []);
  if (account) return account;

  const documentId = ctx.db.normalizeId("accounts", trimmedAccountId);
  if (!documentId) return null;
  accountMergeQueriesForLimit(readBudget, 1);
  const legacyAccount = await ctx.db.get(documentId);
  accountMergeRowsForLimit(readBudget, legacyAccount ? [legacyAccount] : []);
  return legacyAccount;
}

function mergeSplitsByMember(
  splits: Doc<"expenses">["splits"],
  sourceMemberIds: ReadonlySet<string>,
  targetMemberId: string
) {
  const normalizedTarget = normalizeMemberId(targetMemberId);
  const merged = new Map<string, Doc<"expenses">["splits"][number]>();

  for (const split of splits) {
    const normalizedSplitMember = normalizeMemberId(split.member_id);
    const key = sourceMemberIds.has(normalizedSplitMember)
      ? normalizedTarget
      : normalizedSplitMember;
    const existing = merged.get(key);

    if (!existing) {
      merged.set(key, {
        ...split,
        member_id: key
      });
      continue;
    }

    merged.set(key, {
      ...existing,
      amount: existing.amount + split.amount,
      is_settled: Boolean(existing.is_settled) && Boolean(split.is_settled)
    });
  }

  return Array.from(merged.values());
}

function expenseReferencesAnyMember(expense: Doc<"expenses">, memberIds: ReadonlySet<string>) {
  return (
    memberIds.has(normalizeMemberId(expense.paid_by_member_id)) ||
    expense.involved_member_ids.some((memberId) => memberIds.has(normalizeMemberId(memberId))) ||
    expense.splits.some((split) => memberIds.has(normalizeMemberId(split.member_id))) ||
    expense.participant_member_ids.some((memberId) => memberIds.has(normalizeMemberId(memberId))) ||
    expense.participants.some((participant) =>
      memberIds.has(normalizeMemberId(participant.member_id))
    )
  );
}

function rewritableSourceMemberIdsForExpense(
  expense: Doc<"expenses">,
  sourceMemberIds: ReadonlySet<string>
) {
  const inactiveMemberIds = new Set(
    (expense.inactive_participant_member_ids ?? []).map(normalizeMemberId)
  );
  return new Set(
    Array.from(sourceMemberIds).filter((memberId) => !inactiveMemberIds.has(memberId))
  );
}

const mergeCanonicalizationLimits = {
  friendRecords: 256,
  localAliasMemberIds: 256,
  affectedGroups: 64,
  expenses: 64,
  participantRows: 256,
  identityLookups: 1024,
  queries: 4096,
  directScannedRows: 4096,
  worstCaseScannedRows: 16000,
  estimatedReadBytes: 8 * 1024 * 1024,
  visibilityRows: 512
} as const;

const mergeReadSafetyLimits = {
  // Convex documents are capped at 1 MiB. Reserving twice that amount covers JSON measurement
  // overhead while leaving six MiB below the platform's 16 MiB transaction read limit.
  maximumDocumentReservationBytes: 2 * 1024 * 1024,
  hardReadSafetyBytes: 10 * 1024 * 1024,
  maximumPageRows: 5
} as const;

export type MergeReadBudget = {
  scannedRows: number;
  estimatedReadBytes: number;
  accountFriendRows?: number;
  lookupWork?: number;
  queryWork?: number;
  reservedReadRows?: number;
  reservedReadBytes?: number;
};

export function createMergeReadBudget(): MergeReadBudget {
  return {
    scannedRows: 0,
    estimatedReadBytes: 0,
    accountFriendRows: 0,
    lookupWork: 0,
    queryWork: 0,
    reservedReadRows: 0,
    reservedReadBytes: 0
  };
}

export async function assertMergeIdentityMaterializationReady(
  ctx: MutationCtx,
  readBudget: MergeReadBudget
) {
  accountMergeQueriesForLimit(readBudget, 1);
  const state = await ctx.db
    .query("identity_materialization_state")
    .withIndex("by_key", (q) => q.eq("key", IDENTITY_MATERIALIZATION_KEY))
    .unique();
  accountMergeRowsForLimit(readBudget, state ? [state] : []);
  if (state?.status !== "ready") {
    throw new Error(
      "Identity maintenance required: indexed identity migration is not complete; try again later"
    );
  }
}

function mergeWorkLimitError() {
  return new Error("Friend merge is too large to complete safely");
}

export function accountMergeRowsForLimit(budget: MergeReadBudget, rows: readonly unknown[]) {
  budget.scannedRows += rows.length;
  budget.estimatedReadBytes += rows.reduce<number>(
    (total, row) => total + getConvexSize(row as Value),
    0
  );
  if (
    budget.scannedRows > mergeCanonicalizationLimits.directScannedRows ||
    budget.estimatedReadBytes > mergeCanonicalizationLimits.estimatedReadBytes
  ) {
    throw mergeWorkLimitError();
  }
}

export type LinkingReadBudget = MergeReadBudget;

export function createLinkingReadBudget(): LinkingReadBudget {
  return createMergeReadBudget();
}

export function chargeLinkingQueries(budget: LinkingReadBudget, count: number) {
  accountMergeQueriesForLimit(budget, count);
}

export function accountLinkingRows(
  budget: LinkingReadBudget,
  rows: readonly unknown[],
  areAccountFriendRows = false
) {
  accountMergeRowsForLimit(budget, rows);
  if (areAccountFriendRows) {
    budget.accountFriendRows = (budget.accountFriendRows ?? 0) + rows.length;
    if (budget.accountFriendRows > 512) throw mergeWorkLimitError();
  }
}

export function accountMergeQueriesForLimit(budget: MergeReadBudget, count: number) {
  budget.queryWork = (budget.queryWork ?? 0) + count;
  if (budget.queryWork > mergeCanonicalizationLimits.queries) {
    throw mergeWorkLimitError();
  }
}

function accountMergeLookupWorkForLimit(budget: MergeReadBudget, count: number) {
  budget.lookupWork = (budget.lookupWork ?? 0) + count;
  accountMergeQueriesForLimit(budget, count);
  if (budget.lookupWork > mergeCanonicalizationLimits.identityLookups) {
    throw mergeWorkLimitError();
  }
}

function accountMergeIdentityWorkForLimit(budget: MergeReadBudget, count: number) {
  budget.lookupWork = (budget.lookupWork ?? 0) + count;
  if (budget.lookupWork > mergeCanonicalizationLimits.identityLookups) {
    throw mergeWorkLimitError();
  }
}

export function assertMergeWorstCaseReadWithinLimit(budget: MergeReadBudget) {
  const lookupWork = budget.lookupWork ?? 0;
  if (
    budget.scannedRows + (budget.reservedReadRows ?? 0) + lookupWork * 2 >
      mergeCanonicalizationLimits.worstCaseScannedRows ||
    budget.estimatedReadBytes + (budget.reservedReadBytes ?? 0) >
      mergeCanonicalizationLimits.estimatedReadBytes
  ) {
    throw mergeWorkLimitError();
  }
}

export async function collectSequentialMergeIndexRows<T>(
  budget: MergeReadBudget,
  readPage: (
    cursor: string | null,
    limit: number
  ) => Promise<{ page: T[]; continueCursor: string; isDone: boolean }>,
  reserveLookup: () => void,
  stopAfterRows?: number
): Promise<T[]> {
  const rows: T[] = [];
  let cursor: string | null = null;

  while (true) {
    const remainingRowAllowance =
      mergeCanonicalizationLimits.directScannedRows - budget.scannedRows + 1;
    const remainingHardReadBytes =
      mergeReadSafetyLimits.hardReadSafetyBytes - budget.estimatedReadBytes;
    const byteReservedRows = Math.floor(
      remainingHardReadBytes / mergeReadSafetyLimits.maximumDocumentReservationBytes
    );
    const pageSize = Math.min(
      mergeReadSafetyLimits.maximumPageRows,
      remainingRowAllowance,
      byteReservedRows
    );
    if (pageSize <= 0) throw mergeWorkLimitError();

    reserveLookup();
    const result = await readPage(cursor, pageSize);
    accountMergeRowsForLimit(budget, result.page);
    rows.push(...result.page);
    if (stopAfterRows !== undefined && rows.length >= stopAfterRows) {
      return rows.slice(0, stopAfterRows);
    }
    if (result.isDone) return rows;
    if (result.continueCursor === cursor) {
      throw mergeWorkLimitError();
    }
    cursor = result.continueCursor;
  }
}

export async function collectSequentialLinkingRows<T>(
  budget: LinkingReadBudget,
  readPage: (
    cursor: string | null,
    limit: number
  ) => Promise<{ page: T[]; continueCursor: string; isDone: boolean }>,
  areAccountFriendRows = false
) {
  const rows = await collectSequentialMergeIndexRows(
    budget,
    readPage,
    () => accountMergeQueriesForLimit(budget, 1),
    areAccountFriendRows ? 513 : undefined
  );
  if (areAccountFriendRows) {
    budget.accountFriendRows = (budget.accountFriendRows ?? 0) + rows.length;
    if (budget.accountFriendRows > 512) throw mergeWorkLimitError();
  }
  return rows;
}

function localFriendIdentityClosure(friend: Doc<"account_friends">, primaryMemberId: string) {
  const localAliases = normalizeMemberIds(friend.local_alias_member_ids);
  if (localAliases.length > mergeCanonicalizationLimits.localAliasMemberIds) {
    throw mergeWorkLimitError();
  }
  return new Set(normalizeMemberIds([primaryMemberId, ...localAliases]));
}

function isGroupOwnedByAccount(group: Doc<"groups">, account: Doc<"accounts">) {
  const hasOwnerAccountId = Boolean(group.owner_account_id?.trim());
  const hasOwnerDocumentId = Boolean(group.owner_id);
  const ownerEmail = group.owner_email?.trim().toLowerCase();
  const hasOwnerEmail = Boolean(ownerEmail);
  return (
    (!hasOwnerAccountId || group.owner_account_id === account.id) &&
    (!hasOwnerDocumentId || group.owner_id === account._id) &&
    (!hasOwnerEmail || ownerEmail === account.email.trim().toLowerCase()) &&
    (hasOwnerAccountId || hasOwnerDocumentId || hasOwnerEmail)
  );
}

function isExpenseOwnedByAccount(expense: Doc<"expenses">, account: Doc<"accounts">) {
  const hasOwnerAccountId = Boolean(expense.owner_account_id?.trim());
  const hasOwnerDocumentId = Boolean(expense.owner_id);
  const ownerEmail = expense.owner_email?.trim().toLowerCase();
  const hasOwnerEmail = Boolean(ownerEmail);
  return (
    (!hasOwnerAccountId || expense.owner_account_id === account.id) &&
    (!hasOwnerDocumentId || expense.owner_id === account._id) &&
    (!hasOwnerEmail || ownerEmail === account.email.trim().toLowerCase()) &&
    (hasOwnerAccountId || hasOwnerDocumentId || hasOwnerEmail)
  );
}

function assertNoConflictingOwnerIdentity(
  rows: readonly (Doc<"groups"> | Doc<"expenses">)[],
  account: Doc<"accounts">
) {
  if (rows.some((row) => !isGroupOrExpenseOwnedByAccount(row, account))) {
    throw new Error("Cannot merge records with inconsistent ownership: conflicting owner identity");
  }
}

function isGroupOrExpenseOwnedByAccount(
  row: Doc<"groups"> | Doc<"expenses">,
  account: Doc<"accounts">
) {
  return "members" in row
    ? isGroupOwnedByAccount(row, account)
    : isExpenseOwnedByAccount(row, account);
}

async function prepareCanonicalReferenceRewrite(
  ctx: MutationCtx,
  account: Doc<"accounts">,
  sourceMemberIds: ReadonlySet<string>,
  targetMemberId: string,
  targetName: string,
  targetLinkedAccountId?: string,
  targetLinkedAccountEmail?: string,
  readBudget: MergeReadBudget = createMergeReadBudget()
) {
  const normalizedTarget = normalizeMemberId(targetMemberId);
  const normalizedTargetEmail = targetLinkedAccountEmail?.toLowerCase().trim();
  const accountForLimit = (rows: readonly unknown[]) => {
    accountMergeRowsForLimit(readBudget, rows);
  };
  const lookupForLimit = (count: number) => {
    accountMergeLookupWorkForLimit(readBudget, count);
  };

  const ownedGroupRows = [
    await collectSequentialMergeIndexRows(
      readBudget,
      async (cursor, limit) =>
        await ctx.db
          .query("groups")
          .withIndex("by_owner_id", (q) => q.eq("owner_id", account._id))
          .order("asc")
          .paginate({ cursor, numItems: limit }),
      () => lookupForLimit(1)
    ),
    await collectSequentialMergeIndexRows(
      readBudget,
      async (cursor, limit) =>
        await ctx.db
          .query("groups")
          .withIndex("by_owner_account_id", (q) => q.eq("owner_account_id", account.id))
          .order("asc")
          .paginate({ cursor, numItems: limit }),
      () => lookupForLimit(1)
    ),
    await collectSequentialMergeIndexRows(
      readBudget,
      async (cursor, limit) =>
        await ctx.db
          .query("groups")
          .withIndex("by_owner_email", (q) => q.eq("owner_email", account.email))
          .order("asc")
          .paginate({ cursor, numItems: limit }),
      () => lookupForLimit(1)
    )
  ];
  assertNoConflictingOwnerIdentity(ownedGroupRows.flat(), account);
  const ownedGroups = new Map<string, Doc<"groups">>();
  for (const group of ownedGroupRows.flat()) {
    ownedGroups.set(String(group._id), group);
  }
  const affectedGroups = Array.from(ownedGroups.values()).filter((group) =>
    group.members.some((member) => sourceMemberIds.has(normalizeMemberId(member.id)))
  );
  if (affectedGroups.length > mergeCanonicalizationLimits.affectedGroups) {
    throw mergeWorkLimitError();
  }
  const expensesByGroup = new Map<string, Map<string, Doc<"expenses">>>();
  const blockedGroupIds = new Set<string>();

  for (const group of affectedGroups) {
    const byClientId = await collectSequentialMergeIndexRows(
      readBudget,
      async (cursor, limit) =>
        await ctx.db
          .query("expenses")
          .withIndex("by_group_id", (q) => q.eq("group_id", group.id))
          .order("asc")
          .paginate({ cursor, numItems: limit }),
      () => lookupForLimit(1)
    );
    const byReference = await collectSequentialMergeIndexRows(
      readBudget,
      async (cursor, limit) =>
        await ctx.db
          .query("expenses")
          .withIndex("by_group_ref", (q) => q.eq("group_ref", group._id))
          .order("asc")
          .paginate({ cursor, numItems: limit }),
      () => lookupForLimit(1)
    );
    const groupExpenses = new Map<string, Doc<"expenses">>();
    for (const expense of [...byClientId, ...byReference]) {
      groupExpenses.set(String(expense._id), expense);
    }
    expensesByGroup.set(String(group._id), groupExpenses);

    const hasBlockingForeignReference = Array.from(groupExpenses.values()).some((expense) => {
      return (
        !isExpenseOwnedByAccount(expense, account) &&
        expenseReferencesAnyMember(expense, sourceMemberIds)
      );
    });
    if (hasBlockingForeignReference) {
      blockedGroupIds.add(String(group._id));
    }
  }

  const canonicalizableGroupIds = new Set(
    affectedGroups
      .filter((group) => !blockedGroupIds.has(String(group._id)))
      .map((group) => String(group._id))
  );
  const plannedGroupUpdates: Array<{ group: Doc<"groups">; members: any[] }> = [];
  for (const group of affectedGroups) {
    if (blockedGroupIds.has(String(group._id))) continue;

    const dedupedMembers = new Map<string, any>();

    for (const member of group.members) {
      const normalizedMemberId = normalizeMemberId(member.id);
      const canonicalMemberId = sourceMemberIds.has(normalizedMemberId)
        ? normalizedTarget
        : normalizedMemberId;
      const nextMember = {
        ...member,
        id: canonicalMemberId,
        name: canonicalMemberId === normalizedTarget ? targetName : member.name
      };
      const existing = dedupedMembers.get(canonicalMemberId);

      if (!existing) {
        dedupedMembers.set(canonicalMemberId, nextMember);
      } else if (!existing.is_current_user && nextMember.is_current_user) {
        dedupedMembers.set(canonicalMemberId, nextMember);
      }
    }

    const updatedMembers = Array.from(dedupedMembers.values());
    const changed =
      updatedMembers.length !== group.members.length ||
      group.members.some((member: any, index: number) => {
        const updated = updatedMembers[index];
        return !updated || updated.id !== member.id || updated.name !== member.name;
      });

    if (changed) {
      plannedGroupUpdates.push({ group, members: updatedMembers });
    }
  }

  const ownedExpenseRows = [
    await collectSequentialMergeIndexRows(
      readBudget,
      async (cursor, limit) =>
        await ctx.db
          .query("expenses")
          .withIndex("by_owner_id", (q) => q.eq("owner_id", account._id))
          .order("asc")
          .paginate({ cursor, numItems: limit }),
      () => lookupForLimit(1)
    ),
    await collectSequentialMergeIndexRows(
      readBudget,
      async (cursor, limit) =>
        await ctx.db
          .query("expenses")
          .withIndex("by_owner_account_id", (q) => q.eq("owner_account_id", account.id))
          .order("asc")
          .paginate({ cursor, numItems: limit }),
      () => lookupForLimit(1)
    ),
    await collectSequentialMergeIndexRows(
      readBudget,
      async (cursor, limit) =>
        await ctx.db
          .query("expenses")
          .withIndex("by_owner_email", (q) => q.eq("owner_email", account.email))
          .order("asc")
          .paginate({ cursor, numItems: limit }),
      () => lookupForLimit(1)
    )
  ];
  assertNoConflictingOwnerIdentity(ownedExpenseRows.flat(), account);
  const authorizedExpenses = new Map<string, Doc<"expenses">>();
  for (const expense of ownedExpenseRows.flat()) {
    authorizedExpenses.set(String(expense._id), expense);
  }
  const relevantExpenses = Array.from(authorizedExpenses.values()).filter((expense) =>
    expenseReferencesAnyMember(
      expense,
      rewritableSourceMemberIdsForExpense(expense, sourceMemberIds)
    )
  );
  if (relevantExpenses.length > mergeCanonicalizationLimits.expenses) {
    throw mergeWorkLimitError();
  }

  const resolvedGroupsByDocumentId = new Map<string, Doc<"groups">>();
  const resolvedGroupsByClientId = new Map<string, Doc<"groups"> | null>();
  for (const group of ownedGroups.values()) {
    resolvedGroupsByDocumentId.set(String(group._id), group);
    resolvedGroupsByClientId.set(group.id, group);
  }

  const resolveExpenseGroup = async (expense: Doc<"expenses">) => {
    let group: Doc<"groups"> | null = null;
    if (expense.group_ref) {
      const documentId = String(expense.group_ref);
      const cached = resolvedGroupsByDocumentId.get(documentId);
      if (cached) {
        group = cached;
      } else {
        lookupForLimit(1);
        group = await ctx.db.get(expense.group_ref);
        accountForLimit(group ? [group] : []);
        if (group) {
          resolvedGroupsByDocumentId.set(documentId, group);
          resolvedGroupsByClientId.set(group.id, group);
        }
      }
    }
    if (!group && expense.group_id) {
      if (resolvedGroupsByClientId.has(expense.group_id)) {
        group = resolvedGroupsByClientId.get(expense.group_id) ?? null;
      } else {
        lookupForLimit(1);
        group = await ctx.db
          .query("groups")
          .withIndex("by_client_id", (q) => q.eq("id", expense.group_id))
          .unique();
        accountForLimit(group ? [group] : []);
        resolvedGroupsByClientId.set(expense.group_id, group);
        if (group) {
          resolvedGroupsByDocumentId.set(String(group._id), group);
        }
      }
    }
    return group;
  };

  const plannedExpenses: Doc<"expenses">[] = [];
  for (const expense of relevantExpenses) {
    const group = await resolveExpenseGroup(expense);
    if (group) {
      const groupDocumentId = String(group._id);
      if (blockedGroupIds.has(groupDocumentId)) continue;

      const groupAlreadyContainsTarget = group.members.some(
        (member) => normalizeMemberId(member.id) === normalizedTarget
      );
      const canRewriteWithGroup =
        (canonicalizableGroupIds.has(groupDocumentId) && isGroupOwnedByAccount(group, account)) ||
        groupAlreadyContainsTarget;
      if (!canRewriteWithGroup) continue;
    }
    const inactiveMemberIds = new Set(
      (expense.inactive_participant_member_ids ?? []).map(normalizeMemberId)
    );
    if (inactiveMemberIds.has(normalizedTarget)) {
      throw new Error("Cannot merge into inactive participant history");
    }
    plannedExpenses.push(expense);
  }

  let visibilityRows = 0;
  const pricedMemberIds = new Set<string>();
  const pricedLinkedAccountIds = new Set<string>();
  const pricedEmails = new Set<string>();
  for (const expense of plannedExpenses) {
    if (expense.participants.length > mergeCanonicalizationLimits.participantRows) {
      throw mergeWorkLimitError();
    }
    const currentReadBytes = readBudget.estimatedReadBytes;
    const visibility = await collectSequentialMergeIndexRows(
      readBudget,
      async (cursor, limit) =>
        await ctx.db
          .query("user_expenses")
          .withIndex("by_expense_id", (q) => q.eq("expense_id", expense.id))
          .order("asc")
          .paginate({ cursor, numItems: limit }),
      () => lookupForLimit(1),
      mergeCanonicalizationLimits.visibilityRows + 1
    );
    // Reserve the second indexed visibility read performed during reconciliation.
    lookupForLimit(1);
    visibilityRows += visibility.length;
    const currentVisibilityBytes = readBudget.estimatedReadBytes - currentReadBytes;
    readBudget.reservedReadRows = (readBudget.reservedReadRows ?? 0) + visibility.length;
    readBudget.reservedReadBytes = (readBudget.reservedReadBytes ?? 0) + currentVisibilityBytes;
    if (visibilityRows > mergeCanonicalizationLimits.visibilityRows) {
      throw mergeWorkLimitError();
    }

    const emails = new Set(
      [expense.owner_email, ...expense.participant_emails]
        .filter((email): email is string => Boolean(email?.trim()))
        .map((email) => email.trim().toLowerCase())
    );
    const memberIds = new Set([
      expense.paid_by_member_id,
      ...expense.participant_member_ids,
      ...(expense.inactive_participant_member_ids ?? []),
      ...expense.involved_member_ids,
      ...expense.splits.map((split) => split.member_id)
    ]);
    for (const participant of expense.participants) {
      pricedMemberIds.add(normalizeMemberId(participant.member_id));
      const linkedAccountId = participant.linked_account_id?.trim();
      const linkedAccountEmail = participant.linked_account_email?.trim().toLowerCase();
      if (linkedAccountId) pricedLinkedAccountIds.add(linkedAccountId);
      if (linkedAccountEmail) pricedEmails.add(linkedAccountEmail);
    }
    for (const memberId of memberIds) pricedMemberIds.add(normalizeMemberId(memberId));
    for (const email of emails) pricedEmails.add(email);
    if (expense.owner_account_id?.trim()) {
      pricedLinkedAccountIds.add(expense.owner_account_id.trim());
    }
    // owner_id is a direct document read and is not part of the shared indexed cache.
    lookupForLimit(1);
  }

  if (plannedExpenses.length > 0) {
    pricedMemberIds.add(normalizedTarget);
    if (targetLinkedAccountId?.trim()) {
      pricedLinkedAccountIds.add(targetLinkedAccountId.trim());
    }
    if (normalizedTargetEmail) pricedEmails.add(normalizedTargetEmail);
  }

  const identityResolutionCache = createExpenseIdentityResolutionCache();
  // Member resolution can follow up to twenty materialized-alias hops. Preserve the bounded
  // identity-cardinality guard independently of the exact rows and bytes charged below.
  accountMergeIdentityWorkForLimit(
    readBudget,
    pricedMemberIds.size * 80 + pricedLinkedAccountIds.size * 2 + pricedEmails.size
  );
  for (const memberId of pricedMemberIds) {
    const resolution = await resolveMergeAccountByMemberId(ctx, memberId, readBudget);
    identityResolutionCache.memberAccounts.set(memberId, Promise.resolve(resolution.account));
  }
  for (const linkedAccountId of pricedLinkedAccountIds) {
    const linkedAccount = await findMergeAccountByAuthIdOrDocId(ctx, linkedAccountId, readBudget);
    identityResolutionCache.linkedIdAccounts.set(linkedAccountId, Promise.resolve(linkedAccount));
  }
  for (const email of pricedEmails) {
    accountMergeQueriesForLimit(readBudget, 1);
    const emailAccount = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", email))
      .unique();
    accountMergeRowsForLimit(readBudget, emailAccount ? [emailAccount] : []);
    identityResolutionCache.emailAccounts.set(email, Promise.resolve(emailAccount));
  }
  // resolveAuthoritativeExpenseOwnerAccount reads owner_id directly even when the indexed owner
  // cache is warm. Charge that exact account document once per planned expense up front.
  accountForLimit(plannedExpenses.map(() => account));

  const plannedExpenseUpdates: Array<{
    expense: Doc<"expenses">;
    patch: Partial<Doc<"expenses">>;
    viewerAccountIds: Id<"accounts">[];
  }> = [];
  for (const expense of plannedExpenses) {
    const rewritableSourceMemberIds = rewritableSourceMemberIdsForExpense(expense, sourceMemberIds);
    const canonicalize = (memberId: string) => {
      const normalized = normalizeMemberId(memberId);
      return rewritableSourceMemberIds.has(normalized) ? normalizedTarget : normalized;
    };
    const paidByMemberId = canonicalize(expense.paid_by_member_id);
    const involvedMemberIds = normalizeMemberIds(expense.involved_member_ids.map(canonicalize));
    const participantMemberIds = normalizeMemberIds(
      expense.participant_member_ids.map(canonicalize)
    );
    const splits = mergeSplitsByMember(expense.splits, rewritableSourceMemberIds, normalizedTarget);
    const participantsByMember = new Map<string, Doc<"expenses">["participants"][number]>();
    for (const participant of expense.participants) {
      const canonicalParticipantId = canonicalize(participant.member_id);
      const nextParticipant = {
        ...participant,
        member_id: canonicalParticipantId,
        name: canonicalParticipantId === normalizedTarget ? targetName : participant.name,
        linked_account_id:
          canonicalParticipantId === normalizedTarget
            ? targetLinkedAccountId
            : participant.linked_account_id,
        linked_account_email:
          canonicalParticipantId === normalizedTarget
            ? normalizedTargetEmail
            : participant.linked_account_email
      };
      const existing = participantsByMember.get(canonicalParticipantId);

      if (!existing) {
        participantsByMember.set(canonicalParticipantId, nextParticipant);
        continue;
      }

      participantsByMember.set(canonicalParticipantId, {
        ...existing,
        name: nextParticipant.name || existing.name,
        linked_account_id: nextParticipant.linked_account_id || existing.linked_account_id,
        linked_account_email: nextParticipant.linked_account_email || existing.linked_account_email
      });
    }

    const participants = await canonicalizeExpenseParticipantLinks(
      ctx,
      Array.from(participantsByMember.values()),
      identityResolutionCache
    );
    const canonicalIdentityPatch = {
      paid_by_member_id: paidByMemberId,
      involved_member_ids: involvedMemberIds,
      participant_member_ids: participantMemberIds,
      splits,
      participants,
      updated_at: Date.now()
    };
    const participantAccounts = await resolveActiveExpenseParticipantAccounts(
      ctx,
      {
        ...expense,
        ...canonicalIdentityPatch,
        owner_id: account._id,
        owner_account_id: account.id,
        owner_email: account.email,
        participant_emails: []
      },
      new Set(),
      identityResolutionCache
    );
    const participantEmails = Array.from(
      new Set(
        participantAccounts.map((participantAccount) =>
          participantAccount.email.trim().toLowerCase()
        )
      )
    );
    const expensePatch = {
      ...canonicalIdentityPatch,
      owner_id: account._id,
      owner_account_id: account.id,
      owner_email: account.email,
      participant_emails: participantEmails
    };
    plannedExpenseUpdates.push({
      expense,
      patch: expensePatch,
      viewerAccountIds: participantAccounts.map((participantAccount) => participantAccount._id)
    });
  }

  // All identity and variable-size friend/account reads are complete before the returned apply
  // closure can perform its first write. Reconciliation's second visibility read is reserved from
  // the exact preflight rows above.
  assertMergeWorstCaseReadWithinLimit(readBudget);

  return async () => {
    const groupVisibilityBatch = new GroupVisibilityWriteBatch(ctx);
    for (const { group, members } of plannedGroupUpdates) {
      await groupVisibilityBatch.patch(group._id, {
        members,
        owner_id: account._id,
        owner_account_id: account.id,
        owner_email: account.email,
        updated_at: Date.now()
      });
    }
    await groupVisibilityBatch.flush();

    const expenseOperations: ExpenseWriteOperation[] = plannedExpenseUpdates.map(
      ({ expense, patch, viewerAccountIds }) => ({
        kind: "patch",
        expense,
        patch,
        viewerAccountIds
      })
    );
    await applyExpenseWriteBatch(ctx, expenseOperations);
  };
}

export type CanonicalReferenceRewritePlan = () => Promise<void>;

export async function applyCanonicalReferenceRewrite(
  _ctx: MutationCtx,
  plan: CanonicalReferenceRewritePlan
) {
  await plan();
}

export async function prepareClaimedFriendReferenceRewrite(
  ctx: MutationCtx,
  creator: Doc<"accounts">,
  sourceMemberIds: string | readonly string[],
  claimant: Pick<Doc<"accounts">, "id" | "email" | "display_name" | "member_id">,
  readBudget: MergeReadBudget = createMergeReadBudget()
) {
  if (!claimant.member_id) {
    throw new Error("Claimant account is missing a canonical member ID");
  }
  const normalizedSourceMemberIds = new Set(
    normalizeMemberIds(
      typeof sourceMemberIds === "string" ? [sourceMemberIds] : Array.from(sourceMemberIds)
    )
  );
  return await prepareCanonicalReferenceRewrite(
    ctx,
    creator,
    normalizedSourceMemberIds,
    claimant.member_id,
    claimant.display_name ?? claimant.email ?? "Unknown",
    claimant.id,
    claimant.email,
    readBudget
  );
}

export async function rewriteClaimedFriendReferences(
  ctx: MutationCtx,
  creator: Doc<"accounts">,
  sourceMemberIds: string | readonly string[],
  claimant: Pick<Doc<"accounts">, "id" | "email" | "display_name" | "member_id">,
  readBudget: MergeReadBudget = createMergeReadBudget()
) {
  const applyCanonicalRewrite = await prepareClaimedFriendReferenceRewrite(
    ctx,
    creator,
    sourceMemberIds,
    claimant,
    readBudget
  );
  await applyCanonicalRewrite();
}

type MergeAccountFriendIntoCanonicalOptions = {
  accountEmail: string;
  sourceMemberId: string;
  targetMemberId: string;
  allowLinkedTarget?: boolean;
  trustedInviteTarget?: {
    accountId: string;
    email: string;
  };
  preparedCanonicalRewrite?: () => Promise<void>;
  targetName?: string;
  targetLinkedAccountId?: string;
  targetLinkedAccountEmail?: string;
  readBudget?: MergeReadBudget;
};

const mergeEligibleFriendStatuses = new Set(["friend", "accepted", "manual"]);
const mergeBlockedFriendStatuses = new Set([
  "pending",
  "rejected",
  "request_sent",
  "request_received",
  "ghost"
]);

function normalizedFriendStatus(status: string | undefined) {
  const normalized = status?.trim().toLowerCase();
  return normalized || undefined;
}

function assertMergeEligibleFriend(
  friend: Doc<"account_friends">,
  role: "source" | "target",
  allowLinked: boolean
) {
  const status = normalizedFriendStatus(friend.status);
  const hasBlockedState =
    isGhostFriendIdentity(friend) ||
    (status !== undefined && mergeBlockedFriendStatuses.has(status));
  const hasUnknownStatus = status !== undefined && !mergeEligibleFriendStatuses.has(status);
  if (hasBlockedState || hasUnknownStatus) {
    throw new Error(`Cannot merge: ${role} friend "${friend.name}" is not mergeable.`);
  }

  const isLinked =
    friend.has_linked_account ||
    friend.link_state === "linked" ||
    Boolean(friend.linked_account_id) ||
    Boolean(friend.linked_account_email) ||
    Boolean(friend.linked_member_id);
  if (!isLinked || allowLinked) return;

  if (role === "source") {
    throw new Error(`Cannot merge: friend "${friend.name}" is not an unlinked friend.`);
  }
  throw new Error(
    `Cannot merge: friend "${friend.name}" has a linked account. Use invite flow instead.`
  );
}

async function assertMergeIdentityIsLocal(
  ctx: MutationCtx,
  memberId: string,
  role: "source" | "target",
  readBudget: MergeReadBudget
) {
  const resolution = await resolveMergeAccountByMemberId(ctx, memberId, readBudget);
  if (resolution.hasMaterializedAlias) {
    throw new Error(
      role === "source"
        ? "Cannot merge a friend identity that is already globally linked"
        : "Cannot merge into a friend identity that is already globally linked"
    );
  }
  if (resolution.account) {
    throw new Error(
      role === "source"
        ? "Cannot merge a friend identity that belongs to a registered account"
        : "Cannot merge into a friend identity that belongs to a registered account"
    );
  }
}

function assertTrustedInviteTarget(
  friend: Doc<"account_friends">,
  targetMemberId: string,
  target: NonNullable<MergeAccountFriendIntoCanonicalOptions["trustedInviteTarget"]>
) {
  const expectedEmail = target.email.trim().toLowerCase();
  const linkedEmail = friend.linked_account_email?.trim().toLowerCase();
  const isVerifiedTarget =
    friend.has_linked_account === true &&
    friend.link_state === "linked" &&
    normalizedFriendStatus(friend.status) === "friend" &&
    friend.linked_account_id === target.accountId &&
    linkedEmail === expectedEmail &&
    normalizeMemberId(friend.linked_member_id ?? "") === targetMemberId;
  if (!isVerifiedTarget) {
    throw new Error("Cannot merge into an unverified invite target");
  }
}

export type PreparedInviteMergeSource = {
  applyCanonicalRewrite: () => Promise<void>;
  sourceFriend: Doc<"account_friends">;
  targetFriend: Doc<"account_friends"> | null;
  localAliases: string[];
};

export async function prepareInviteMergeSourceInternal(
  ctx: MutationCtx,
  options: {
    accountEmail: string;
    sourceMemberId: string;
    targetMemberId: string;
    targetName: string;
    targetLinkedAccountId: string;
    targetLinkedAccountEmail: string;
    allowMissingSource?: boolean;
    readBudget?: MergeReadBudget;
  }
) {
  const accountEmail = options.accountEmail.trim().toLowerCase();
  const sourceMemberId = normalizeMemberId(options.sourceMemberId);
  const targetMemberId = normalizeMemberId(options.targetMemberId);
  const readBudget = options.readBudget ?? createMergeReadBudget();
  const sourceFriend = await findMergeFriendRecordByMemberId(
    ctx,
    accountEmail,
    sourceMemberId,
    readBudget
  );
  if (!sourceFriend) {
    if (options.allowMissingSource) return undefined;
    throw new Error(`Friend with member_id ${sourceMemberId} not found`);
  }
  assertMergeEligibleFriend(sourceFriend, "source", false);

  const sourceMemberIds = localFriendIdentityClosure(sourceFriend, sourceMemberId);
  for (const memberId of sourceMemberIds) {
    if (memberId !== targetMemberId) {
      await assertMergeIdentityIsLocal(ctx, memberId, "source", readBudget);
    }
  }

  if (sourceMemberId === targetMemberId) return undefined;

  const targetFriend =
    (await findMergeFriendRecordByMemberId(ctx, accountEmail, targetMemberId, readBudget)) ?? null;
  const targetAliases = new Set(normalizeMemberIds(targetFriend?.local_alias_member_ids));
  for (const targetAlias of targetAliases) {
    if (targetAlias === targetMemberId) continue;
    const resolution = await resolveMergeAccountByMemberId(ctx, targetAlias, readBudget);
    if (resolution.account && resolution.account.id !== options.targetLinkedAccountId) {
      throw new Error("Cannot merge because a target alias belongs to another registered account");
    }
    if (resolution.hasMaterializedAlias && !resolution.account) {
      throw new Error("Cannot merge because a target alias has conflicting global materialization");
    }
  }
  if (sourceMemberIds.has(targetMemberId)) {
    throw new Error("Cannot merge friends because their local aliases form a cycle");
  }
  const localAliases = normalizeMemberIds([...targetAliases, ...sourceMemberIds]).filter(
    (memberId) => memberId !== targetMemberId
  );
  if (localAliases.length > mergeCanonicalizationLimits.localAliasMemberIds) {
    throw mergeWorkLimitError();
  }

  accountMergeQueriesForLimit(readBudget, 1);
  const account = await ctx.db
    .query("accounts")
    .withIndex("by_email", (q) => q.eq("email", accountEmail))
    .unique();
  accountMergeRowsForLimit(readBudget, account ? [account] : []);
  if (!account || account.status === "deleted") {
    throw new Error("Account not found");
  }

  const accountFriends = await collectSequentialMergeIndexRows(
    readBudget,
    async (cursor, limit) =>
      await ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (q) => q.eq("account_email", accountEmail))
        .order("asc")
        .paginate({ cursor, numItems: limit }),
    () => accountMergeQueriesForLimit(readBudget, 1),
    mergeCanonicalizationLimits.friendRecords + 1
  );
  if (accountFriends.length > mergeCanonicalizationLimits.friendRecords) {
    throw mergeWorkLimitError();
  }
  const targetMemberIds = new Set([targetMemberId, ...targetAliases]);
  const conflictingFriend = accountFriends.find(
    (friend) =>
      friend._id !== sourceFriend._id &&
      friend._id !== targetFriend?._id &&
      Array.from(localFriendIdentityClosure(friend, friend.member_id)).some(
        (memberId) => sourceMemberIds.has(memberId) || targetMemberIds.has(memberId)
      )
  );
  if (conflictingFriend) {
    throw new Error("Cannot merge because this identity is already attached to another friend");
  }

  const applyCanonicalRewrite = await prepareCanonicalReferenceRewrite(
    ctx,
    account,
    sourceMemberIds,
    targetMemberId,
    options.targetName,
    options.targetLinkedAccountId,
    options.targetLinkedAccountEmail,
    readBudget
  );
  return {
    applyCanonicalRewrite,
    sourceFriend,
    targetFriend,
    localAliases
  } satisfies PreparedInviteMergeSource;
}

export async function mergeAccountFriendIntoCanonicalInternal(
  ctx: MutationCtx,
  options: MergeAccountFriendIntoCanonicalOptions
) {
  const accountEmail = options.accountEmail.toLowerCase().trim();
  const sourceMemberId = normalizeMemberId(options.sourceMemberId);
  const targetMemberId = normalizeMemberId(options.targetMemberId);
  const readBudget = options.readBudget ?? createMergeReadBudget();

  const targetFriend = await findMergeFriendRecordByMemberId(
    ctx,
    accountEmail,
    targetMemberId,
    readBudget,
    { includeLinkedLocalAliases: options.allowLinkedTarget === true }
  );
  if (!targetFriend) {
    throw new Error(`Friend with member_id ${targetMemberId} not found`);
  }
  const trustedInviteTarget = options.trustedInviteTarget;
  const allowLinkedTarget = options.allowLinkedTarget === true;
  let provenLinkedTarget: Awaited<ReturnType<typeof resolveProvenFriendLink>> = null;

  if (sourceMemberId === targetMemberId) {
    if (trustedInviteTarget) {
      assertTrustedInviteTarget(targetFriend, targetMemberId, trustedInviteTarget);
    } else {
      assertMergeEligibleFriend(targetFriend, "target", allowLinkedTarget);
      const targetIsLinked =
        targetFriend.has_linked_account ||
        targetFriend.link_state === "linked" ||
        Boolean(targetFriend.linked_account_id) ||
        Boolean(targetFriend.linked_account_email) ||
        Boolean(targetFriend.linked_member_id);
      if (allowLinkedTarget && targetIsLinked) {
        accountMergeQueriesForLimit(readBudget, provenFriendLinkQueryWork(targetFriend));
        provenLinkedTarget = await resolveProvenFriendLink(ctx, targetFriend, (rows) =>
          accountMergeRowsForLimit(readBudget, rows)
        );
        if (!provenLinkedTarget) {
          throw new Error("Cannot merge into an unverified linked friend");
        }
      } else {
        await assertMergeIdentityIsLocal(ctx, targetMemberId, "target", readBudget);
        assertMergeEligibleFriend(targetFriend, "source", false);
      }
    }
    return {
      success: true,
      already_merged: true,
      message: "Both IDs are the same",
      canonical_member_id: provenLinkedTarget?.linkedMemberId ?? targetMemberId
    };
  }

  if (trustedInviteTarget) {
    assertTrustedInviteTarget(targetFriend, targetMemberId, trustedInviteTarget);
  } else {
    assertMergeEligibleFriend(targetFriend, "target", allowLinkedTarget);
    const targetIsLinked =
      targetFriend.has_linked_account ||
      targetFriend.link_state === "linked" ||
      Boolean(targetFriend.linked_account_id) ||
      Boolean(targetFriend.linked_account_email) ||
      Boolean(targetFriend.linked_member_id);
    if (allowLinkedTarget && targetIsLinked) {
      accountMergeQueriesForLimit(readBudget, provenFriendLinkQueryWork(targetFriend));
      provenLinkedTarget = await resolveProvenFriendLink(ctx, targetFriend, (rows) =>
        accountMergeRowsForLimit(readBudget, rows)
      );
      if (!provenLinkedTarget) {
        throw new Error("Cannot merge into an unverified linked friend");
      }
    } else {
      await assertMergeIdentityIsLocal(ctx, targetMemberId, "target", readBudget);
    }
  }

  const effectiveTargetMemberId = provenLinkedTarget?.linkedMemberId ?? targetMemberId;

  const existingTargetAliases = new Set(
    normalizeMemberIds([
      ...(targetFriend.local_alias_member_ids ?? []),
      ...(effectiveTargetMemberId === targetMemberId ? [] : [targetMemberId])
    ])
  );
  if (existingTargetAliases.size > mergeCanonicalizationLimits.localAliasMemberIds) {
    throw mergeWorkLimitError();
  }
  const wasAlreadyMerged = existingTargetAliases.has(sourceMemberId);

  const sourceFriend = await findMergeFriendRecordByMemberId(
    ctx,
    accountEmail,
    sourceMemberId,
    readBudget
  );
  if (!sourceFriend) {
    await assertMergeIdentityIsLocal(ctx, sourceMemberId, "source", readBudget);
    if (wasAlreadyMerged) {
      return {
        success: true,
        already_merged: true,
        message: "Friends already merged",
        canonical_member_id: effectiveTargetMemberId,
        alias_member_id: sourceMemberId
      };
    }
    throw new Error(`Friend with member_id ${sourceMemberId} not found`);
  }

  const sourceMemberIds = localFriendIdentityClosure(sourceFriend, sourceMemberId);
  if (sourceMemberIds.has(effectiveTargetMemberId)) {
    throw new Error("Cannot merge friends because their local aliases form a cycle");
  }

  assertMergeEligibleFriend(sourceFriend, "source", false);

  const localAliases = normalizeMemberIds([...existingTargetAliases, ...sourceMemberIds]).filter(
    (alias) => alias !== effectiveTargetMemberId
  );
  if (localAliases.length > mergeCanonicalizationLimits.localAliasMemberIds) {
    throw mergeWorkLimitError();
  }

  for (const sourceId of sourceMemberIds) {
    await assertMergeIdentityIsLocal(ctx, sourceId, "source", readBudget);
  }

  accountMergeQueriesForLimit(readBudget, 1);
  const account = await ctx.db
    .query("accounts")
    .withIndex("by_email", (q) => q.eq("email", accountEmail))
    .unique();
  accountMergeRowsForLimit(readBudget, account ? [account] : []);
  if (!account || account.status === "deleted") {
    throw new Error("Account not found");
  }

  const accountFriends = await collectSequentialMergeIndexRows(
    readBudget,
    async (cursor, limit) =>
      await ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (q) => q.eq("account_email", accountEmail))
        .order("asc")
        .paginate({ cursor, numItems: limit }),
    () => accountMergeQueriesForLimit(readBudget, 1),
    mergeCanonicalizationLimits.friendRecords + 1
  );
  if (accountFriends.length > mergeCanonicalizationLimits.friendRecords) {
    throw mergeWorkLimitError();
  }
  const targetMemberIds = new Set([effectiveTargetMemberId, ...existingTargetAliases]);
  const conflictingFriend = accountFriends.find(
    (friend) =>
      friend._id !== sourceFriend._id &&
      friend._id !== targetFriend._id &&
      Array.from(localFriendIdentityClosure(friend, friend.member_id)).some(
        (memberId) => sourceMemberIds.has(memberId) || targetMemberIds.has(memberId)
      )
  );
  if (conflictingFriend) {
    throw new Error("Cannot merge because this identity is already attached to another friend");
  }

  const applyCanonicalRewrite =
    options.preparedCanonicalRewrite ??
    (await prepareCanonicalReferenceRewrite(
      ctx,
      account,
      sourceMemberIds,
      effectiveTargetMemberId,
      options.targetName ?? targetFriend.name,
      options.targetLinkedAccountId ??
        provenLinkedTarget?.linkedAccountId ??
        targetFriend.linked_account_id,
      options.targetLinkedAccountEmail ??
        provenLinkedTarget?.linkedAccountEmail ??
        targetFriend.linked_account_email,
      readBudget
    ));
  assertMergeWorstCaseReadWithinLimit(readBudget);
  await applyCanonicalRewrite();

  await ctx.db.patch(targetFriend._id, {
    member_id: effectiveTargetMemberId,
    has_linked_account: provenLinkedTarget ? true : targetFriend.has_linked_account,
    linked_account_id: provenLinkedTarget?.linkedAccountId ?? targetFriend.linked_account_id,
    linked_account_email:
      provenLinkedTarget?.linkedAccountEmail ?? targetFriend.linked_account_email,
    linked_member_id: provenLinkedTarget?.linkedMemberId ?? targetFriend.linked_member_id,
    local_alias_member_ids: localAliases,
    nickname: targetFriend.nickname ?? sourceFriend.nickname,
    original_name: targetFriend.original_name ?? sourceFriend.original_name,
    original_nickname: targetFriend.original_nickname ?? sourceFriend.original_nickname,
    prefer_nickname: targetFriend.prefer_nickname ?? sourceFriend.prefer_nickname,
    first_name: targetFriend.first_name ?? sourceFriend.first_name,
    last_name: targetFriend.last_name ?? sourceFriend.last_name,
    display_preference: targetFriend.display_preference ?? sourceFriend.display_preference,
    profile_image_url: targetFriend.profile_image_url ?? sourceFriend.profile_image_url,
    updated_at: Date.now()
  });
  await ctx.db.delete(sourceFriend._id);

  return {
    success: true,
    already_merged: wasAlreadyMerged,
    message: wasAlreadyMerged
      ? "Reconciled an already merged friend"
      : "Friends merged successfully",
    canonical_member_id: effectiveTargetMemberId,
    alias_member_id: sourceMemberId
  };
}

/**
 * Deprecated compatibility endpoint for older iOS clients.
 *
 * This performs the same owner-scoped merge as mergeUnlinkedFriends. It never
 * writes member_aliases and cannot operate on group-only or arbitrary IDs.
 * A linked target remains supported for the legacy invite-claim cleanup flow.
 */
export const mergeMemberIds = mutation({
  args: {
    sourceId: v.string(),
    targetCanonicalId: v.optional(v.string()),
    // Backward-compatible alias for older clients.
    targetId: v.optional(v.string()),
    // Deprecated: ignored, account email is derived from auth context.
    accountEmail: v.optional(v.string())
  },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUserOrThrow(ctx);
    await assertIdentityMaterializationReady(ctx.db);
    const rawTarget = args.targetCanonicalId ?? args.targetId;
    if (!rawTarget) {
      throw new Error("targetCanonicalId is required");
    }
    return await mergeAccountFriendIntoCanonicalInternal(ctx, {
      accountEmail: user.email,
      sourceMemberId: args.sourceId,
      targetMemberId: rawTarget,
      allowLinkedTarget: true
    });
  }
});

/**
 * Merges two unlinked friends into one by creating an alias.
 *
 * Use case: User realizes two "different" friends are actually the same person,
 * but neither has linked their account yet. This allows manual merge in settings.
 *
 * IMPORTANT: Both friends must NOT have linked accounts. If either is linked,
 * the merge must happen through the invite claim flow instead.
 *
 * @param friendId1 - First friend's member_id (will become the canonical)
 * @param friendId2 - Second friend's member_id (will become alias to first)
 * @param accountEmail - The account performing the merge
 */
export const mergeUnlinkedFriends = mutation({
  args: {
    friendId1: v.string(),
    friendId2: v.string(),
    // Deprecated: ignored, account email is derived from auth context.
    accountEmail: v.optional(v.string())
  },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUserOrThrow(ctx);
    await assertIdentityMaterializationReady(ctx.db);
    return await mergeAccountFriendIntoCanonicalInternal(ctx, {
      accountEmail: user.email,
      targetMemberId: args.friendId1,
      sourceMemberId: args.friendId2
    });
  }
});
