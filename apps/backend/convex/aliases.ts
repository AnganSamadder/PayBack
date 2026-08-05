import { query, internalQuery, mutation, DatabaseReader, MutationCtx } from "./_generated/server";
import { Doc } from "./_generated/dataModel";
import { v } from "convex/values";
import {
  assertIdentityMaterializationReady,
  findAccountByMemberId,
  findAliasByAliasMemberId,
  getEquivalentAliasMemberIds,
  normalizeMemberId,
  normalizeMemberIds
} from "./identity";
import {
  canonicalizeExpenseParticipantLinks,
  createExpenseIdentityResolutionCache,
  getCurrentUserOrThrow,
  reconcileUserExpenses,
  resolveActiveExpenseParticipantAccounts
} from "./helpers";
import { isGhostFriendIdentity, resolveProvenFriendLink } from "./friendLinkProvenance";

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

async function findFriendRecordByMemberId(
  ctx: MutationCtx,
  accountEmail: string,
  memberId: string,
  readBudget: MergeReadBudget
) {
  const normalizedMemberId = normalizeMemberId(memberId);
  let record = await ctx.db
    .query("account_friends")
    .withIndex("by_account_email_and_member_id", (q) =>
      q.eq("account_email", accountEmail).eq("member_id", normalizedMemberId)
    )
    .unique();
  accountMergeRowsForLimit(readBudget, record ? [record] : []);

  if (record) return record;

  if (memberId !== normalizedMemberId) {
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
    () => {}
  );

  if (allFriends.length > mergeCanonicalizationLimits.friendRecords) {
    throw mergeWorkLimitError();
  }

  return allFriends.find((friend) => normalizeMemberId(friend.member_id) === normalizedMemberId);
}

async function findCanonicalAccountByMemberId(ctx: MutationCtx, memberId: string) {
  const normalizedMemberId = normalizeMemberId(memberId);
  const normalizedAccount = await ctx.db
    .query("accounts")
    .withIndex("by_member_id", (q) => q.eq("member_id", normalizedMemberId))
    .first();
  if (normalizedAccount || normalizedMemberId === memberId) {
    return normalizedAccount;
  }
  return await ctx.db
    .query("accounts")
    .withIndex("by_member_id", (q) => q.eq("member_id", memberId))
    .first();
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
  directScannedRows: 4096,
  worstCaseScannedRows: 16000,
  estimatedReadBytes: 8 * 1024 * 1024,
  estimatedIndexedDocumentBytes: 8 * 1024,
  visibilityRows: 512
} as const;

const mergeReadSafetyLimits = {
  // Convex documents are capped at 1 MiB. Reserving twice that amount covers JSON measurement
  // overhead while leaving six MiB below the platform's 16 MiB transaction read limit.
  maximumDocumentReservationBytes: 2 * 1024 * 1024,
  hardReadSafetyBytes: 10 * 1024 * 1024,
  maximumPageRows: 5
} as const;

type MergeReadBudget = {
  scannedRows: number;
  estimatedReadBytes: number;
};

function mergeWorkLimitError() {
  return new Error("Friend merge is too large to complete safely");
}

function accountMergeRowsForLimit(budget: MergeReadBudget, rows: readonly unknown[]) {
  budget.scannedRows += rows.length;
  budget.estimatedReadBytes += rows.reduce<number>(
    (total, row) => total + new TextEncoder().encode(JSON.stringify(row) ?? "").length,
    0
  );
  if (
    budget.scannedRows > mergeCanonicalizationLimits.directScannedRows ||
    budget.estimatedReadBytes > mergeCanonicalizationLimits.estimatedReadBytes
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
  reserveLookup: () => void
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
    if (result.isDone) return rows;
    if (result.continueCursor === cursor) {
      throw mergeWorkLimitError();
    }
    cursor = result.continueCursor;
  }
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
  if (hasOwnerAccountId || hasOwnerDocumentId) {
    return (
      (!hasOwnerAccountId || group.owner_account_id === account.id) &&
      (!hasOwnerDocumentId || group.owner_id === account._id)
    );
  }
  return group.owner_email?.trim().toLowerCase() === account.email.trim().toLowerCase();
}

function isExpenseOwnedByAccount(expense: Doc<"expenses">, account: Doc<"accounts">) {
  const hasOwnerAccountId = Boolean(expense.owner_account_id?.trim());
  const hasOwnerDocumentId = Boolean(expense.owner_id);
  if (hasOwnerAccountId || hasOwnerDocumentId) {
    return (
      (!hasOwnerAccountId || expense.owner_account_id === account.id) &&
      (!hasOwnerDocumentId || expense.owner_id === account._id)
    );
  }
  return expense.owner_email?.trim().toLowerCase() === account.email.trim().toLowerCase();
}

function assertNoConflictingOwnerIdentity(
  rows: readonly (Doc<"groups"> | Doc<"expenses">)[],
  account: Doc<"accounts">
) {
  if (rows.some((row) => !isGroupOrExpenseOwnedByAccount(row, account))) {
    throw new Error("Cannot merge records with a conflicting owner identity");
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
  readBudget: MergeReadBudget = { scannedRows: 0, estimatedReadBytes: 0 }
) {
  const normalizedTarget = normalizeMemberId(targetMemberId);
  const normalizedTargetEmail = targetLinkedAccountEmail?.toLowerCase().trim();
  let lookupWork = 0;

  const accountForLimit = (rows: readonly unknown[]) => {
    accountMergeRowsForLimit(readBudget, rows);
  };
  const lookupForLimit = (count: number) => {
    lookupWork += count;
    if (lookupWork > mergeCanonicalizationLimits.identityLookups) {
      throw mergeWorkLimitError();
    }
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
    plannedExpenses.push(expense);
  }

  let visibilityRows = 0;
  let visibilityBytes = 0;
  const pricedMemberIds = new Set<string>();
  const pricedLinkedAccountIds = new Set<string>();
  const pricedEmails = new Set<string>();
  for (const expense of plannedExpenses) {
    if (expense.participants.length > mergeCanonicalizationLimits.participantRows) {
      throw mergeWorkLimitError();
    }
    const visibility = await ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) => q.eq("expense_id", expense.id))
      .take(mergeCanonicalizationLimits.visibilityRows + 1);
    // One indexed visibility read now, and one during reconciliation.
    lookupForLimit(2);
    visibilityRows += visibility.length;
    const currentReadBytes = readBudget.estimatedReadBytes;
    accountForLimit(visibility);
    visibilityBytes += readBudget.estimatedReadBytes - currentReadBytes;
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

  // findAccountByMemberId can traverse twenty materialized alias hops. Each hop performs
  // an indexed account read, two readiness/evidence reads, and an alias read. The apply
  // phase shares this cache across both participant passes and every planned expense.
  lookupForLimit(pricedMemberIds.size * 80 + pricedLinkedAccountIds.size * 2 + pricedEmails.size);

  if (plannedExpenses.length > 0) {
    // Visibility reconciliation resolves only identities referenced by planned expenses.
    // Price those bounded index lookups conservatively without reading unrelated accounts.
    const worstCaseScannedRows = readBudget.scannedRows + visibilityRows + lookupWork * 2;
    const worstCaseReadBytes =
      readBudget.estimatedReadBytes +
      visibilityBytes +
      mergeCanonicalizationLimits.estimatedIndexedDocumentBytes * lookupWork;
    if (
      worstCaseScannedRows > mergeCanonicalizationLimits.worstCaseScannedRows ||
      worstCaseReadBytes > mergeCanonicalizationLimits.estimatedReadBytes
    ) {
      throw mergeWorkLimitError();
    }
  }

  return async () => {
    const identityResolutionCache = createExpenseIdentityResolutionCache();
    for (const { group, members } of plannedGroupUpdates) {
      await ctx.db.patch(group._id, {
        members,
        owner_id: account._id,
        owner_account_id: account.id,
        owner_email: account.email,
        updated_at: Date.now()
      });
    }

    for (const expense of plannedExpenses) {
      const rewritableSourceMemberIds = rewritableSourceMemberIdsForExpense(
        expense,
        sourceMemberIds
      );
      const canonicalize = (memberId: string) => {
        const normalized = normalizeMemberId(memberId);
        return rewritableSourceMemberIds.has(normalized) ? normalizedTarget : normalized;
      };
      const paidByMemberId = canonicalize(expense.paid_by_member_id);
      const involvedMemberIds = normalizeMemberIds(expense.involved_member_ids.map(canonicalize));
      const participantMemberIds = normalizeMemberIds(
        expense.participant_member_ids.map(canonicalize)
      );
      const splits = mergeSplitsByMember(
        expense.splits,
        rewritableSourceMemberIds,
        normalizedTarget
      );
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
          linked_account_email:
            nextParticipant.linked_account_email || existing.linked_account_email
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
      await ctx.db.patch(expense._id, expensePatch);

      await reconcileUserExpenses(
        ctx,
        expense.id,
        participantAccounts.map((participantAccount) => participantAccount.id)
      );
    }
  };
}

export async function rewriteClaimedFriendReferences(
  ctx: MutationCtx,
  creator: Doc<"accounts">,
  sourceMemberId: string,
  claimant: Pick<Doc<"accounts">, "id" | "email" | "display_name" | "member_id">
) {
  if (!claimant.member_id) {
    throw new Error("Claimant account is missing a canonical member ID");
  }
  const applyCanonicalRewrite = await prepareCanonicalReferenceRewrite(
    ctx,
    creator,
    new Set([normalizeMemberId(sourceMemberId)]),
    claimant.member_id,
    claimant.display_name ?? claimant.email ?? "Unknown",
    claimant.id,
    claimant.email
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
  role: "source" | "target"
) {
  if (await findCanonicalAccountByMemberId(ctx, memberId)) {
    throw new Error(
      role === "source"
        ? "Cannot merge a friend identity that belongs to a registered account"
        : "Cannot merge into a friend identity that belongs to a registered account"
    );
  }
  if (await findAliasByAliasMemberId(ctx.db, memberId)) {
    throw new Error(
      role === "source"
        ? "Cannot merge a friend identity that is already globally linked"
        : "Cannot merge into a friend identity that is already globally linked"
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
  }
) {
  const accountEmail = options.accountEmail.trim().toLowerCase();
  const sourceMemberId = normalizeMemberId(options.sourceMemberId);
  const targetMemberId = normalizeMemberId(options.targetMemberId);
  const readBudget: MergeReadBudget = { scannedRows: 0, estimatedReadBytes: 0 };
  const sourceFriend = await findFriendRecordByMemberId(
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
      await assertMergeIdentityIsLocal(ctx, memberId, "source");
    }
  }

  if (sourceMemberId === targetMemberId) return undefined;

  const account = await ctx.db
    .query("accounts")
    .withIndex("by_email", (q) => q.eq("email", accountEmail))
    .unique();
  if (!account || account.status === "deleted") {
    throw new Error("Account not found");
  }
  return await prepareCanonicalReferenceRewrite(
    ctx,
    account,
    sourceMemberIds,
    targetMemberId,
    options.targetName,
    options.targetLinkedAccountId,
    options.targetLinkedAccountEmail,
    readBudget
  );
}

export async function mergeAccountFriendIntoCanonicalInternal(
  ctx: MutationCtx,
  options: MergeAccountFriendIntoCanonicalOptions
) {
  const accountEmail = options.accountEmail.toLowerCase().trim();
  const sourceMemberId = normalizeMemberId(options.sourceMemberId);
  const targetMemberId = normalizeMemberId(options.targetMemberId);
  const readBudget: MergeReadBudget = { scannedRows: 0, estimatedReadBytes: 0 };

  const targetFriend = await findFriendRecordByMemberId(
    ctx,
    accountEmail,
    targetMemberId,
    readBudget
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
        provenLinkedTarget = await resolveProvenFriendLink(ctx, targetFriend);
        if (!provenLinkedTarget) {
          throw new Error("Cannot merge into an unverified linked friend");
        }
      } else {
        await assertMergeIdentityIsLocal(ctx, targetMemberId, "target");
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
      provenLinkedTarget = await resolveProvenFriendLink(ctx, targetFriend);
      if (!provenLinkedTarget) {
        throw new Error("Cannot merge into an unverified linked friend");
      }
    } else {
      await assertMergeIdentityIsLocal(ctx, targetMemberId, "target");
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

  const sourceFriend = await findFriendRecordByMemberId(
    ctx,
    accountEmail,
    sourceMemberId,
    readBudget
  );
  if (!sourceFriend) {
    await assertMergeIdentityIsLocal(ctx, sourceMemberId, "source");
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
    await assertMergeIdentityIsLocal(ctx, sourceId, "source");
  }

  const account = await ctx.db
    .query("accounts")
    .withIndex("by_email", (q) => q.eq("email", accountEmail))
    .unique();
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
    () => {}
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
