import { mutation, internalMutation, query } from "./_generated/server";
import { v } from "convex/values";
import { Doc } from "./_generated/dataModel";
import { getAllEquivalentMemberIds, resolveCanonicalMemberIdInternal } from "./aliases";
import {
  assertIdentityMaterializationReady,
  findAccountByAuthIdOrDocId,
  findAccountByMemberId,
  MAX_LIVE_ACCOUNT_ALIASES,
  MAX_LIVE_ALIAS_DELTA,
  normalizeMemberId,
  removeAccountAliasMaterialization
} from "./identity";
import { reconcileExpenseVisibility, reconcileUserExpenses } from "./helpers";

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

async function buildResolvedParticipantEmails(
  ctx: any,
  ownerEmail: string | undefined,
  participants: any[] | undefined,
  participantMemberIds: string[] | undefined
): Promise<string[]> {
  const emails = new Set<string>();
  const normalizedOwnerEmail = normalizeEmail(ownerEmail);
  if (normalizedOwnerEmail) {
    emails.add(normalizedOwnerEmail);
  }

  for (const participant of participants ?? []) {
    let account: any | null = null;
    const linkedEmail = normalizeEmail(participant.linked_account_email);
    const linkedAccountId =
      typeof participant.linked_account_id === "string"
        ? participant.linked_account_id.trim()
        : undefined;

    if (linkedEmail) {
      account = await ctx.db
        .query("accounts")
        .withIndex("by_email", (q: any) => q.eq("email", linkedEmail))
        .unique();
    }
    if (!account && linkedAccountId) {
      account = await findAccountByAuthIdOrDocId(ctx.db, linkedAccountId);
    }
    if (!account && typeof participant.member_id === "string") {
      account = await findAccountByMemberId(ctx.db, participant.member_id);
    }
    if (account?.email) {
      const normalized = normalizeEmail(account.email);
      if (normalized) {
        emails.add(normalized);
      }
    }
  }

  for (const memberId of participantMemberIds ?? []) {
    const account = await findAccountByMemberId(ctx.db, memberId);
    if (account?.email) {
      const normalized = normalizeEmail(account.email);
      if (normalized) {
        emails.add(normalized);
      }
    }
  }

  return Array.from(emails);
}

async function reconcileExpenseVisibilityFromEmails(
  ctx: any,
  expenseId: string,
  participantEmails: string[]
) {
  const participantUsers = await Promise.all(
    participantEmails.map((email) =>
      ctx.db
        .query("accounts")
        .withIndex("by_email", (q: any) => q.eq("email", email))
        .unique()
    )
  );
  const participantUserIds = participantUsers
    .filter((user): user is NonNullable<typeof user> => user !== null)
    .map((user) => user.id);
  await reconcileUserExpenses(ctx, expenseId, participantUserIds);
}

async function pruneAliasMemberIdsFromAccount(
  ctx: any,
  accountEmail: string,
  memberIdsToRemove: string[]
): Promise<number> {
  const account = await ctx.db
    .query("accounts")
    .withIndex("by_email", (q: any) => q.eq("email", accountEmail))
    .unique();
  if (!account || !Array.isArray(account.alias_member_ids)) return 0;

  const removeSet = new Set(memberIdsToRemove.map((id) => normalizeMemberId(id)));
  const hasAliasToRemove = account.alias_member_ids.some((memberId: string) =>
    removeSet.has(normalizeMemberId(memberId))
  );
  if (!hasAliasToRemove) return 0;
  if (account.alias_member_ids.length > MAX_LIVE_ACCOUNT_ALIASES) {
    throw new Error("Identity maintenance required: account alias cleanup must be migrated");
  }
  if (removeSet.size > MAX_LIVE_ALIAS_DELTA) {
    throw new Error("Identity maintenance required: alias cleanup delta is too large");
  }
  const nextAliasIds = account.alias_member_ids.filter(
    (memberId: string) => !removeSet.has(normalizeMemberId(memberId))
  );
  await assertIdentityMaterializationReady(ctx.db);
  let aliasesDeleted = 0;
  for (const memberId of removeSet) {
    aliasesDeleted += await removeAccountAliasMaterialization(ctx, account.id, memberId);
  }
  await ctx.db.patch(account._id, {
    alias_member_ids: nextAliasIds,
    updated_at: Date.now()
  });
  return aliasesDeleted;
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
    const normalizedEquivalentIds = new Set(equivalentIds.map(normalizeMemberId));

    const userAccount = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", accountEmail))
      .unique();

    if (!userAccount) {
      return { success: false, message: "Account not found" };
    }

    let directGroupDeleted = false;
    let expensesDeleted = 0;

    const ownedGroups = await ctx.db
      .query("groups")
      .withIndex("by_owner_email", (q) => q.eq("owner_email", accountEmail))
      .collect();

    for (const group of ownedGroups) {
      if (!group.is_direct) continue;

      const hasFriend = group.members.some((member) =>
        matchesEquivalentMemberId(member.id, normalizedEquivalentIds)
      );
      if (!hasFriend) continue;

      const groupExpenses = await ctx.db
        .query("expenses")
        .withIndex("by_group_id", (q) => q.eq("group_id", group.id))
        .collect();

      for (const expense of groupExpenses) {
        await deleteUserExpensesForExpense(ctx, expense.id);
        await ctx.db.delete(expense._id);
        expensesDeleted++;
      }

      await ctx.db.delete(group._id);
      directGroupDeleted = true;
    }

    const aliasesDeleted = await pruneAliasMemberIdsFromAccount(ctx, accountEmail, equivalentIds);

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
    const normalizedEquivalentIds = new Set(equivalentIds.map(normalizeMemberId));

    let groupsModified = 0;
    let expensesDeleted = 0;
    let expensesModified = 0;
    let aliasesDeleted = 0;

    const ownedGroups = await ctx.db
      .query("groups")
      .withIndex("by_owner_email", (q) => q.eq("owner_email", accountEmail))
      .collect();

    for (const group of ownedGroups) {
      const hasFriend = group.members.some((member) =>
        matchesEquivalentMemberId(member.id, normalizedEquivalentIds)
      );
      if (!hasFriend) continue;

      const remainingMembers = group.members.filter(
        (member) => !matchesEquivalentMemberId(member.id, normalizedEquivalentIds)
      );

      if (remainingMembers.length <= 1) {
        const groupExpenses = await ctx.db
          .query("expenses")
          .withIndex("by_group_id", (q) => q.eq("group_id", group.id))
          .collect();

        for (const expense of groupExpenses) {
          await deleteUserExpensesForExpense(ctx, expense.id);
          await ctx.db.delete(expense._id);
          expensesDeleted++;
        }

        await ctx.db.delete(group._id);
      } else {
        await ctx.db.patch(group._id, {
          members: remainingMembers,
          updated_at: Date.now()
        });

        const groupExpenses = await ctx.db
          .query("expenses")
          .withIndex("by_group_id", (q) => q.eq("group_id", group.id))
          .collect();

        for (const expense of groupExpenses) {
          if (!expenseReferencesEquivalentMember(expense, normalizedEquivalentIds)) continue;

          const remainingParticipants = expense.participant_member_ids.filter(
            (memberId) => !matchesEquivalentMemberId(memberId, normalizedEquivalentIds)
          );
          const removedFriendWasPayer = matchesEquivalentMemberId(
            expense.paid_by_member_id,
            normalizedEquivalentIds
          );

          if (removedFriendWasPayer || remainingParticipants.length <= 1) {
            await deleteUserExpensesForExpense(ctx, expense.id);
            await ctx.db.delete(expense._id);
            expensesDeleted++;
          } else {
            const newSplits = expense.splits.filter(
              (split) => !matchesEquivalentMemberId(split.member_id, normalizedEquivalentIds)
            );
            const newParticipants = expense.participants.filter(
              (participant) =>
                !matchesEquivalentMemberId(participant.member_id, normalizedEquivalentIds)
            );
            const newInvolvedIds = expense.involved_member_ids.filter(
              (memberId) => !matchesEquivalentMemberId(memberId, normalizedEquivalentIds)
            );
            const newIsSettled =
              newSplits.length > 0 && newSplits.every((split) => split.is_settled);
            const participantEmails = await buildResolvedParticipantEmails(
              ctx,
              expense.owner_email,
              newParticipants,
              remainingParticipants
            );

            await ctx.db.patch(expense._id, {
              splits: newSplits,
              participants: newParticipants,
              participant_member_ids: remainingParticipants,
              involved_member_ids: newInvolvedIds,
              participant_emails: participantEmails,
              is_settled: newIsSettled,
              updated_at: Date.now()
            });
            await reconcileExpenseVisibilityFromEmails(ctx, expense.id, participantEmails);
            expensesModified++;
          }
        }
      }
      groupsModified++;
    }

    aliasesDeleted = await pruneAliasMemberIdsFromAccount(ctx, accountEmail, equivalentIds);

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
