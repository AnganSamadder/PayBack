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
import { getCurrentUserOrThrow, reconcileExpenseVisibility } from "./helpers";
import { isGhostFriendIdentity } from "./friendLinkProvenance";

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
  memberId: string
) {
  const normalizedMemberId = normalizeMemberId(memberId);
  let record = await ctx.db
    .query("account_friends")
    .withIndex("by_account_email_and_member_id", (q) =>
      q.eq("account_email", accountEmail).eq("member_id", normalizedMemberId)
    )
    .unique();

  if (record) return record;

  if (memberId !== normalizedMemberId) {
    record = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", accountEmail).eq("member_id", memberId)
      )
      .unique();
    if (record) return record;
  }

  const allFriends = await ctx.db
    .query("account_friends")
    .withIndex("by_account_email", (q) => q.eq("account_email", accountEmail))
    .collect();

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
  affectedGroups: 64,
  expenses: 64,
  identityLookups: 1024,
  directScannedRows: 4096,
  worstCaseScannedRows: 16000,
  estimatedReadBytes: 8 * 1024 * 1024,
  estimatedIndexedDocumentBytes: 8 * 1024,
  visibilityRows: 512
} as const;

function mergeWorkLimitError() {
  return new Error("Friend merge is too large to complete safely");
}

function isGroupOwnedByAccount(group: Doc<"groups">, account: Doc<"accounts">) {
  return (
    group.owner_id === account._id ||
    group.owner_account_id === account.id ||
    group.owner_email === account.email
  );
}

function isExpenseOwnedByAccount(expense: Doc<"expenses">, account: Doc<"accounts">) {
  return (
    expense.owner_id === account._id ||
    expense.owner_account_id === account.id ||
    expense.owner_email === account.email
  );
}

async function rewriteCanonicalReferences(
  ctx: MutationCtx,
  account: Doc<"accounts">,
  sourceMemberIds: ReadonlySet<string>,
  targetMemberId: string,
  targetName: string,
  targetLinkedAccountId?: string,
  targetLinkedAccountEmail?: string
) {
  const normalizedTarget = normalizeMemberId(targetMemberId);
  const normalizedTargetEmail = targetLinkedAccountEmail?.toLowerCase().trim();
  const shouldReconcileVisibility = Boolean(targetLinkedAccountId?.trim() || normalizedTargetEmail);
  let scannedRows = 0;
  let estimatedReadBytes = 0;
  let lookupWork = 6;

  const accountForLimit = (rows: readonly unknown[]) => {
    scannedRows += rows.length;
    estimatedReadBytes += rows.reduce<number>(
      (total, row) => total + new TextEncoder().encode(JSON.stringify(row) ?? "").length,
      0
    );
    if (
      scannedRows > mergeCanonicalizationLimits.directScannedRows ||
      estimatedReadBytes > mergeCanonicalizationLimits.estimatedReadBytes
    ) {
      throw mergeWorkLimitError();
    }
  };
  const lookupForLimit = (count: number) => {
    lookupWork += count;
    if (lookupWork > mergeCanonicalizationLimits.identityLookups) {
      throw mergeWorkLimitError();
    }
  };

  const ownedGroupRows = await Promise.all([
    ctx.db
      .query("groups")
      .withIndex("by_owner_id", (q) => q.eq("owner_id", account._id))
      .take(mergeCanonicalizationLimits.directScannedRows + 1),
    ctx.db
      .query("groups")
      .withIndex("by_owner_account_id", (q) => q.eq("owner_account_id", account.id))
      .take(mergeCanonicalizationLimits.directScannedRows + 1),
    ctx.db
      .query("groups")
      .withIndex("by_owner_email", (q) => q.eq("owner_email", account.email))
      .take(mergeCanonicalizationLimits.directScannedRows + 1)
  ]);
  accountForLimit(ownedGroupRows.flat());
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
    lookupForLimit(2);
    const [byClientId, byReference] = await Promise.all([
      ctx.db
        .query("expenses")
        .withIndex("by_group_id", (q) => q.eq("group_id", group.id))
        .take(mergeCanonicalizationLimits.directScannedRows + 1),
      ctx.db
        .query("expenses")
        .withIndex("by_group_ref", (q) => q.eq("group_ref", group._id))
        .take(mergeCanonicalizationLimits.directScannedRows + 1)
    ]);
    accountForLimit([...byClientId, ...byReference]);
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

  const ownedExpenseRows = await Promise.all([
    ctx.db
      .query("expenses")
      .withIndex("by_owner_id", (q) => q.eq("owner_id", account._id))
      .take(mergeCanonicalizationLimits.directScannedRows + 1),
    ctx.db
      .query("expenses")
      .withIndex("by_owner_account_id", (q) => q.eq("owner_account_id", account.id))
      .take(mergeCanonicalizationLimits.directScannedRows + 1),
    ctx.db
      .query("expenses")
      .withIndex("by_owner_email", (q) => q.eq("owner_email", account.email))
      .take(mergeCanonicalizationLimits.directScannedRows + 1)
  ]);
  accountForLimit(ownedExpenseRows.flat());
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
  for (const expense of shouldReconcileVisibility ? plannedExpenses : []) {
    const visibility = await ctx.db
      .query("user_expenses")
      .withIndex("by_expense_id", (q) => q.eq("expense_id", expense.id))
      .take(mergeCanonicalizationLimits.visibilityRows + 1);
    lookupForLimit(1);
    visibilityRows += visibility.length;
    const currentReadBytes = estimatedReadBytes;
    accountForLimit(visibility);
    visibilityBytes += estimatedReadBytes - currentReadBytes;
    if (visibilityRows > mergeCanonicalizationLimits.visibilityRows) {
      throw mergeWorkLimitError();
    }

    const emails = new Set(
      [expense.owner_email, ...expense.participant_emails]
        .filter((email): email is string => Boolean(email?.trim()))
        .map((email) => email.trim().toLowerCase())
    );
    const memberIds = new Set([
      ...expense.participant_member_ids,
      ...expense.involved_member_ids,
      ...expense.participants.map((participant) => participant.member_id),
      ...expense.splits.map((split) => split.member_id)
    ]);
    const linkedAccountIds = new Set(
      expense.participants
        .map((participant) => participant.linked_account_id?.trim())
        .filter((accountId): accountId is string => Boolean(accountId))
    );
    lookupForLimit(2 + emails.size + memberIds.size * 2 + linkedAccountIds.size);
  }

  if (shouldReconcileVisibility && plannedExpenses.length > 0) {
    // Visibility reconciliation resolves only identities referenced by planned expenses.
    // Price those bounded index lookups conservatively without reading unrelated accounts.
    const worstCaseScannedRows = scannedRows + visibilityRows + lookupWork * 2;
    const worstCaseReadBytes =
      estimatedReadBytes +
      visibilityBytes +
      mergeCanonicalizationLimits.estimatedIndexedDocumentBytes * lookupWork;
    if (
      worstCaseScannedRows > mergeCanonicalizationLimits.worstCaseScannedRows ||
      worstCaseReadBytes > mergeCanonicalizationLimits.estimatedReadBytes
    ) {
      throw mergeWorkLimitError();
    }
  }

  for (const { group, members } of plannedGroupUpdates) {
    await ctx.db.patch(group._id, {
      members,
      updated_at: Date.now()
    });
  }

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
    const replacedParticipantEmails = new Set(
      expense.participants
        .filter((participant) =>
          rewritableSourceMemberIds.has(normalizeMemberId(participant.member_id))
        )
        .map((participant) => participant.linked_account_email?.trim().toLowerCase())
        .filter((email): email is string => Boolean(email))
    );
    const retainedParticipantEmails = new Set(
      expense.participants
        .filter(
          (participant) => !rewritableSourceMemberIds.has(normalizeMemberId(participant.member_id))
        )
        .map((participant) => participant.linked_account_email?.trim().toLowerCase())
        .filter((email): email is string => Boolean(email))
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
        linked_account_email: nextParticipant.linked_account_email || existing.linked_account_email
      });
    }

    const participantEmails = Array.from(
      new Set(
        [
          ...expense.participant_emails.filter((email) => {
            const normalizedEmail = email.trim().toLowerCase();
            return (
              !replacedParticipantEmails.has(normalizedEmail) ||
              retainedParticipantEmails.has(normalizedEmail)
            );
          }),
          normalizedTargetEmail
        ]
          .filter((email): email is string => Boolean(email))
          .map((email) => email.toLowerCase().trim())
      )
    );
    const participants = Array.from(participantsByMember.values());

    const expensePatch = {
      paid_by_member_id: paidByMemberId,
      involved_member_ids: involvedMemberIds,
      participant_member_ids: participantMemberIds,
      splits,
      participants,
      participant_emails: participantEmails,
      updated_at: Date.now()
    };
    await ctx.db.patch(expense._id, expensePatch);

    if (shouldReconcileVisibility) {
      await reconcileExpenseVisibility(ctx, { ...expense, ...expensePatch });
    }
  }
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
  await rewriteCanonicalReferences(
    ctx,
    creator,
    new Set([normalizeMemberId(sourceMemberId)]),
    claimant.member_id,
    claimant.display_name ?? claimant.email ?? "Unknown",
    claimant.id,
    claimant.email
  );
}

type MergeAccountFriendIntoCanonicalOptions = {
  accountEmail: string;
  sourceMemberId: string;
  targetMemberId: string;
  allowLinkedTarget?: boolean;
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

export async function mergeAccountFriendIntoCanonicalInternal(
  ctx: MutationCtx,
  options: MergeAccountFriendIntoCanonicalOptions
) {
  const accountEmail = options.accountEmail.toLowerCase().trim();
  const sourceMemberId = normalizeMemberId(options.sourceMemberId);
  const targetMemberId = normalizeMemberId(options.targetMemberId);

  const targetFriend = await findFriendRecordByMemberId(ctx, accountEmail, targetMemberId);
  if (!targetFriend) {
    throw new Error(`Friend with member_id ${targetMemberId} not found`);
  }
  const allowLinkedTarget = options.allowLinkedTarget === true;

  if (sourceMemberId === targetMemberId) {
    assertMergeEligibleFriend(targetFriend, "target", allowLinkedTarget);
    await assertMergeIdentityIsLocal(ctx, targetMemberId, "target");
    assertMergeEligibleFriend(targetFriend, "source", false);
    return {
      success: true,
      already_merged: true,
      message: "Both IDs are the same",
      canonical_member_id: targetMemberId
    };
  }

  assertMergeEligibleFriend(targetFriend, "target", allowLinkedTarget);
  const targetIsLinked =
    targetFriend.has_linked_account ||
    targetFriend.link_state === "linked" ||
    Boolean(targetFriend.linked_account_id) ||
    Boolean(targetFriend.linked_account_email) ||
    Boolean(targetFriend.linked_member_id);
  if (!allowLinkedTarget || !targetIsLinked) {
    await assertMergeIdentityIsLocal(ctx, targetMemberId, "target");
  }

  const existingTargetAliases = new Set(normalizeMemberIds(targetFriend.local_alias_member_ids));
  const wasAlreadyMerged = existingTargetAliases.has(sourceMemberId);

  const sourceFriend = await findFriendRecordByMemberId(ctx, accountEmail, sourceMemberId);
  if (!sourceFriend) {
    await assertMergeIdentityIsLocal(ctx, sourceMemberId, "source");
    if (wasAlreadyMerged) {
      return {
        success: true,
        already_merged: true,
        message: "Friends already merged",
        canonical_member_id: targetMemberId,
        alias_member_id: sourceMemberId
      };
    }
    throw new Error(`Friend with member_id ${sourceMemberId} not found`);
  }

  const sourceMemberIds = new Set(
    normalizeMemberIds([sourceMemberId, ...(sourceFriend.local_alias_member_ids || [])])
  );
  if (sourceMemberIds.has(targetMemberId)) {
    throw new Error("Cannot merge friends because their local aliases form a cycle");
  }

  assertMergeEligibleFriend(sourceFriend, "source", false);

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

  const accountFriends = await ctx.db
    .query("account_friends")
    .withIndex("by_account_email", (q) => q.eq("account_email", accountEmail))
    .collect();
  const conflictingFriend = accountFriends.find(
    (friend) =>
      friend._id !== sourceFriend._id &&
      friend._id !== targetFriend._id &&
      normalizeMemberIds(friend.local_alias_member_ids).some((alias) => sourceMemberIds.has(alias))
  );
  if (conflictingFriend) {
    throw new Error("Cannot merge because this identity is already attached to another friend");
  }

  await rewriteCanonicalReferences(
    ctx,
    account,
    sourceMemberIds,
    targetMemberId,
    options.targetName ?? targetFriend.name,
    options.targetLinkedAccountId ?? targetFriend.linked_account_id,
    options.targetLinkedAccountEmail ?? targetFriend.linked_account_email
  );

  const localAliases = normalizeMemberIds([...existingTargetAliases, ...sourceMemberIds]).filter(
    (alias) => alias !== targetMemberId
  );
  await ctx.db.patch(targetFriend._id, {
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
    canonical_member_id: targetMemberId,
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
