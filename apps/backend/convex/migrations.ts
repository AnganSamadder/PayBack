import { internalMutation } from "./_generated/server";
import { Doc } from "./_generated/dataModel";
import type { PaginationOptions } from "convex/server";
import { v } from "convex/values";
import { getRandomAvatarColor } from "./utils";
import { resolveActiveExpenseParticipantAccounts } from "./helpers";
import { applyExpenseWriteBatch, type ExpenseWriteOperation } from "./expenseWrites";
import {
  assertIdentityMaterializationReady,
  applyPreflightedAccountAliasMaterialization,
  ensureAccountAliasMaterialization,
  findAccountByAuthIdOrDocId,
  findAccountByMemberId,
  IDENTITY_MATERIALIZATION_KEY,
  MAX_LIVE_ACCOUNT_ALIASES,
  MAX_ALIAS_ROWS_PER_MEMBER_ID,
  normalizeMemberId,
  normalizeMemberIds,
  preflightNormalizedAccountAliasMaterialization
} from "./identity";
import { GroupVisibilityWriteBatch } from "./groupVisibility";

function normalizeEmail(value: string | undefined | null): string | undefined {
  if (typeof value !== "string") return undefined;
  const normalized = value.trim().toLowerCase();
  return normalized.length > 0 ? normalized : undefined;
}

async function deriveExpenseParticipantEmails(ctx: any, expense: any): Promise<string[]> {
  const accounts = (
    await resolveActiveExpenseParticipantAccounts(ctx, {
      ...expense,
      participant_emails: []
    })
  ).filter((account) => account.status !== "deleting" && account.status !== "deleted");
  return Array.from(
    new Set(
      accounts
        .map((account) => normalizeEmail(account.email))
        .filter((email): email is string => email !== undefined)
    )
  );
}

function canonicalEmailArray(values: string[] | undefined): string[] {
  const normalized = (values ?? [])
    .map((value) => normalizeEmail(value))
    .filter((value): value is string => Boolean(value));
  return Array.from(new Set(normalized)).sort();
}

function arraysEqual(lhs: string[], rhs: string[]): boolean {
  if (lhs.length !== rhs.length) return false;
  for (let i = 0; i < lhs.length; i += 1) {
    if (lhs[i] !== rhs[i]) return false;
  }
  return true;
}

const MAX_EXPENSE_REPAIR_BATCH_SIZE = 64;
const MAX_EXPENSE_PAGE_BYTES = 4 * 1024 * 1024;
const MAX_NAME_REPAIR_ACCOUNT_BATCH_SIZE = 2;
const MAX_NAME_REPAIR_EXPENSES_PER_BATCH = 256;
const MAX_REPAIR_ROWS_PER_ACCOUNT = 128;

type ExpensePatchOperation = Extract<ExpenseWriteOperation, { kind: "patch" }>;
type ExpenseVisibilityOperation = Extract<ExpenseWriteOperation, { kind: "visibility" }>;
type ExpenseMaintenanceOperation = ExpensePatchOperation | ExpenseVisibilityOperation;
type BoundedPaginationOptions = PaginationOptions & {
  maximumRowsRead: number;
  maximumBytesRead: number;
};

function expensePageLimit(limit: number | undefined): number {
  const resolved = limit ?? 32;
  validateExpenseRepairBatchSize(resolved);
  return resolved;
}

function expensePaginationOptions(
  cursor: string | undefined,
  limit: number
): BoundedPaginationOptions {
  return {
    cursor: cursor ?? null,
    numItems: limit,
    maximumRowsRead: limit,
    maximumBytesRead: MAX_EXPENSE_PAGE_BYTES
  };
}

function validateExpenseRepairBatchSize(limit: number): void {
  if (!Number.isInteger(limit) || limit < 1 || limit > MAX_EXPENSE_REPAIR_BATCH_SIZE) {
    throw new Error(`limit must be an integer between 1 and ${MAX_EXPENSE_REPAIR_BATCH_SIZE}`);
  }
}

function validateNameRepairAccountBatchSize(limit: number): void {
  if (!Number.isInteger(limit) || limit < 1 || limit > MAX_NAME_REPAIR_ACCOUNT_BATCH_SIZE) {
    throw new Error(`limit must be an integer between 1 and ${MAX_NAME_REPAIR_ACCOUNT_BATCH_SIZE}`);
  }
}

function expenseReferencesMemberId(expense: Doc<"expenses">, memberId: string): boolean {
  const normalizedMemberId = normalizeMemberId(memberId);
  return (
    normalizeMemberId(expense.paid_by_member_id) === normalizedMemberId ||
    expense.involved_member_ids.some(
      (candidate) => normalizeMemberId(candidate) === normalizedMemberId
    ) ||
    expense.participant_member_ids.some(
      (candidate) => normalizeMemberId(candidate) === normalizedMemberId
    ) ||
    expense.splits.some((split) => normalizeMemberId(split.member_id) === normalizedMemberId) ||
    expense.participants.some(
      (participant) => normalizeMemberId(participant.member_id) === normalizedMemberId
    )
  );
}

async function expensePatchOperation(
  ctx: any,
  expense: Doc<"expenses">,
  patch: ExpensePatchOperation["patch"]
): Promise<ExpensePatchOperation> {
  const nextExpense = { ...expense, ...patch };
  const viewerAccounts = await resolveActiveExpenseParticipantAccounts(ctx, nextExpense);
  return {
    kind: "patch",
    expense,
    patch,
    viewerAccountIds: viewerAccounts.map((account) => account._id)
  };
}

async function expenseVisibilityOperation(
  ctx: any,
  expense: Doc<"expenses">
): Promise<ExpenseVisibilityOperation> {
  const viewerAccounts = await resolveActiveExpenseParticipantAccounts(ctx, expense);
  return {
    kind: "visibility",
    expense,
    viewerAccountIds: viewerAccounts.map((account) => account._id)
  };
}

async function rewriteExpenseMemberIdPreservingRevocation(
  ctx: any,
  expense: Doc<"expenses">,
  oldMemberId: string,
  newMemberId: string
): Promise<{
  outcome: "unchanged" | "rewritten" | "skipped_revocation_collision";
  operation?: ExpenseMaintenanceOperation;
}> {
  const normalizedOldMemberId = normalizeMemberId(oldMemberId);
  const normalizedNewMemberId = normalizeMemberId(newMemberId);
  const inactiveMemberIds = new Set(
    (expense.inactive_participant_member_ids ?? []).map(normalizeMemberId)
  );
  const oldIdentityIsInactive = inactiveMemberIds.has(normalizedOldMemberId);
  const newIdentityIsInactive = inactiveMemberIds.has(normalizedNewMemberId);
  const oldIdentityIsReferenced =
    oldIdentityIsInactive || expenseReferencesMemberId(expense, normalizedOldMemberId);
  const newIdentityIsReferenced =
    newIdentityIsInactive || expenseReferencesMemberId(expense, normalizedNewMemberId);

  if (
    normalizedOldMemberId !== normalizedNewMemberId &&
    oldIdentityIsReferenced &&
    newIdentityIsReferenced &&
    oldIdentityIsInactive !== newIdentityIsInactive
  ) {
    const participantEmails = await deriveExpenseParticipantEmails(ctx, expense);
    if (
      !arraysEqual(
        canonicalEmailArray(expense.participant_emails),
        canonicalEmailArray(participantEmails)
      )
    ) {
      return {
        outcome: "skipped_revocation_collision",
        operation: await expensePatchOperation(ctx, expense, {
          participant_emails: participantEmails,
          updated_at: Date.now()
        })
      };
    }
    return {
      outcome: "skipped_revocation_collision",
      operation: await expenseVisibilityOperation(ctx, expense)
    };
  }

  if (!oldIdentityIsReferenced || normalizedOldMemberId === normalizedNewMemberId) {
    return { outcome: "unchanged" };
  }

  const replaceMemberId = (candidate: string) =>
    normalizeMemberId(candidate) === normalizedOldMemberId ? normalizedNewMemberId : candidate;
  const inactiveParticipantMemberIds = Array.from(
    new Set(
      (expense.inactive_participant_member_ids ?? []).map((memberId) => replaceMemberId(memberId))
    )
  );
  const nextExpense: Doc<"expenses"> = {
    ...expense,
    paid_by_member_id: replaceMemberId(expense.paid_by_member_id),
    involved_member_ids: expense.involved_member_ids.map(replaceMemberId),
    splits: expense.splits.map((split) => ({
      ...split,
      member_id: replaceMemberId(split.member_id)
    })),
    participants: expense.participants.map((participant) => ({
      ...participant,
      member_id: replaceMemberId(participant.member_id)
    })),
    participant_member_ids: expense.participant_member_ids.map(replaceMemberId),
    inactive_participant_member_ids: inactiveParticipantMemberIds,
    updated_at: Date.now()
  };
  const participantEmails = await deriveExpenseParticipantEmails(ctx, nextExpense);
  nextExpense.participant_emails = participantEmails;

  return {
    outcome: "rewritten",
    operation: await expensePatchOperation(ctx, expense, {
      paid_by_member_id: nextExpense.paid_by_member_id,
      involved_member_ids: nextExpense.involved_member_ids,
      splits: nextExpense.splits,
      participants: nextExpense.participants,
      participant_member_ids: nextExpense.participant_member_ids,
      inactive_participant_member_ids: nextExpense.inactive_participant_member_ids,
      participant_emails: nextExpense.participant_emails,
      updated_at: nextExpense.updated_at
    })
  };
}

/**
 * Creates member_aliases records for existing linked accounts.
 *
 * This identifies cases where:
 * 1. An invite token was claimed
 * 2. The claimant already had a linked_member_id (canonical)
 * 3. The token's target_member_id differs from the canonical (becomes alias)
 *
 * Also preserves original_nickname from nickname field before linking.
 */
export const createMemberAliasesFromClaimedTokens = internalMutation({
  args: {
    cursor: v.optional(v.string()),
    limit: v.optional(v.number())
  },
  handler: async (ctx, args) => {
    const limit = args.limit ?? 50;
    if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
      throw new Error("limit must be an integer between 1 and 100");
    }
    await assertIdentityMaterializationReady(ctx.db);
    const claimedTokens = await ctx.db
      .query("invite_tokens")
      .filter((q) => q.neq(q.field("claimed_by"), undefined))
      .paginate({ cursor: args.cursor ?? null, numItems: limit });

    let aliasesCreated = 0;
    let nicknamesPreserved = 0;

    for (const token of claimedTokens.page) {
      if (!token.claimed_by) continue;

      const claimantAccount = await ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", token.claimed_by!))
        .unique();

      if (!claimantAccount?.member_id) continue;

      const canonicalId = normalizeMemberId(claimantAccount.member_id);
      const aliasId = normalizeMemberId(token.target_member_id);

      if (canonicalId === aliasId) continue;

      const aliases = normalizeMemberIds([
        ...(claimantAccount.alias_member_ids ?? []),
        aliasId
      ]).filter((memberId) => memberId !== canonicalId);
      if (aliases.length > MAX_LIVE_ACCOUNT_ALIASES) {
        throw new Error(`Account ${claimantAccount.id} has too many aliases`);
      }
      const created = await ensureAccountAliasMaterialization(
        ctx,
        {
          id: claimantAccount.id,
          email: claimantAccount.email,
          member_id: canonicalId
        },
        aliasId,
        token.claimed_at || Date.now()
      );
      await ctx.db.patch(claimantAccount._id, {
        alias_member_ids: aliases,
        updated_at: Date.now()
      });
      if (created) {
        aliasesCreated++;
      }

      const creatorFriend = await ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q.eq("account_email", token.creator_email).eq("member_id", aliasId)
        )
        .unique();

      if (creatorFriend && creatorFriend.nickname && !creatorFriend.original_nickname) {
        await ctx.db.patch(creatorFriend._id, {
          original_nickname: creatorFriend.nickname,
          updated_at: Date.now()
        });
        nicknamesPreserved++;
      }
    }

    return {
      aliasesCreated,
      nicknamesPreserved,
      tokensProcessed: claimedTokens.page.length,
      cursor: claimedTokens.continueCursor,
      isDone: claimedTokens.isDone
    };
  }
});

export const backfillProfileColors = internalMutation({
  args: {},
  handler: async (ctx) => {
    const groupVisibilityBatch = new GroupVisibilityWriteBatch(ctx);
    // Backfill accounts
    const accounts = await ctx.db.query("accounts").collect();
    let accountsUpdated = 0;
    for (const account of accounts) {
      if (!account.profile_avatar_color) {
        await ctx.db.patch(account._id, {
          profile_avatar_color: getRandomAvatarColor()
        });
        accountsUpdated++;
      }
    }

    // Backfill friends
    const friends = await ctx.db.query("account_friends").collect();
    let friendsUpdated = 0;
    for (const friend of friends) {
      if (!friend.profile_avatar_color) {
        await ctx.db.patch(friend._id, {
          profile_avatar_color: getRandomAvatarColor()
        });
        friendsUpdated++;
      }
    }

    // Backfill groups
    const groups = await ctx.db.query("groups").collect();
    let groupsUpdated = 0;
    for (const group of groups) {
      let groupChanged = false;
      const newMembers = group.members.map((m: any) => {
        if (!m.profile_avatar_color && !m.profile_image_url) {
          groupChanged = true;
          return { ...m, profile_avatar_color: getRandomAvatarColor() };
        }
        return m;
      });

      if (groupChanged) {
        await groupVisibilityBatch.patch(group._id, { members: newMembers });
        groupsUpdated++;
      }
    }
    await groupVisibilityBatch.flush();

    return { accountsUpdated, friendsUpdated, groupsUpdated };
  }
});

export const backfillFriendsFromGroups = internalMutation({
  args: {},
  handler: async (ctx) => {
    const groups = await ctx.db.query("groups").collect();
    let newFriendsCreated = 0;

    for (const group of groups) {
      const ownerEmail = group.owner_email;

      // Try to find owner account to skip "self"
      const ownerAccount = await ctx.db
        .query("accounts")
        .withIndex("by_email", (q) => q.eq("email", ownerEmail))
        .unique();

      for (const member of group.members) {
        // Skip if member is self
        if (ownerAccount && ownerAccount.member_id === member.id) {
          continue;
        }

        const existingFriend = await ctx.db
          .query("account_friends")
          .withIndex("by_account_email_and_member_id", (q) =>
            q.eq("account_email", ownerEmail).eq("member_id", member.id)
          )
          .unique();

        if (!existingFriend) {
          await ctx.db.insert("account_friends", {
            account_email: ownerEmail,
            member_id: member.id,
            name: member.name,
            profile_avatar_color: member.profile_avatar_color || getRandomAvatarColor(),
            profile_image_url: member.profile_image_url,
            has_linked_account: false,
            updated_at: Date.now()
          });
          newFriendsCreated++;
        }
      }
    }
    return { newFriendsCreated };
  }
});

/**
 * Fixes linked_member_id by finding members with matching display names in owned groups.
 */
export const fixLinkedMemberIds = internalMutation({
  args: {},
  handler: async (ctx) => {
    const accounts = await ctx.db.query("accounts").collect();
    let fixed = 0;

    for (const account of accounts) {
      // Skip if already has a member_id
      if (account.member_id) continue;

      // Find groups owned by this account
      const groups = await ctx.db
        .query("groups")
        .withIndex("by_owner_email", (q) => q.eq("owner_email", account.email))
        .collect();

      // Look for a member with a matching display name
      for (const group of groups) {
        const matchingMember = group.members.find(
          (m: any) => m.name.toLowerCase() === account.display_name.toLowerCase()
        );

        if (matchingMember) {
          await ctx.db.patch(account._id, {
            member_id: matchingMember.id,
            updated_at: Date.now()
          });
          console.log(`Fixed member_id for ${account.email}: ${matchingMember.id}`);
          fixed++;
          break;
        }
      }
    }

    return { fixed };
  }
});

/**
 * Fixes expenses where paid_by_member_id doesn't match any member in the group's owner account.
 * This can happen when expenses were created before the account was properly linked.
 */
export const fixExpenseMemberIds = internalMutation({
  args: {
    cursor: v.optional(v.string()),
    limit: v.optional(v.number())
  },
  handler: async (ctx, args) => {
    const limit = args.limit ?? MAX_NAME_REPAIR_ACCOUNT_BATCH_SIZE;
    validateNameRepairAccountBatchSize(limit);
    const accountsPage = await ctx.db
      .query("accounts")
      .paginate(expensePaginationOptions(args.cursor, limit));
    let expensesFixed = 0;
    let expensesSkipped = 0;
    let expensesScanned = 0;
    const expenseOperations: ExpenseMaintenanceOperation[] = [];

    for (const account of accountsPage.page) {
      if (!account.member_id) continue;

      const expenses = await ctx.db
        .query("expenses")
        .withIndex("by_owner_email", (q) => q.eq("owner_email", account.email))
        .take(MAX_REPAIR_ROWS_PER_ACCOUNT + 1);
      if (expenses.length > MAX_REPAIR_ROWS_PER_ACCOUNT) {
        throw new Error(`Identity maintenance required: too many expenses for ${account.email}`);
      }
      expensesScanned += expenses.length;
      if (expensesScanned > MAX_NAME_REPAIR_EXPENSES_PER_BATCH) {
        throw new Error("Identity maintenance required: expense repair batch exceeds read budget");
      }

      for (const expense of expenses) {
        const payerMemberId = normalizeMemberId(expense.paid_by_member_id);
        if (payerMemberId === normalizeMemberId(account.member_id)) continue;
        const userParticipant = expense.participants.find(
          (participant) =>
            participant.name.toLowerCase() === account.display_name.toLowerCase() &&
            normalizeMemberId(participant.member_id) === payerMemberId
        );
        if (!userParticipant) continue;

        const rewrite = await rewriteExpenseMemberIdPreservingRevocation(
          ctx,
          expense,
          expense.paid_by_member_id,
          account.member_id
        );
        if (rewrite.operation) expenseOperations.push(rewrite.operation);
        if (rewrite.outcome === "rewritten") expensesFixed++;
        if (rewrite.outcome === "skipped_revocation_collision") expensesSkipped++;
      }
    }
    await applyExpenseWriteBatch(ctx, expenseOperations);

    return {
      expensesFixed,
      expensesSkipped,
      expensesScanned,
      continueCursor: accountsPage.isDone ? undefined : accountsPage.continueCursor,
      isDone: accountsPage.isDone
    };
  }
});

/**
 * Force fixes ALL expenses by replacing any orphaned member ID with the account's linked_member_id.
 * This is a more aggressive fix that handles all cases.
 */
export const fixAllExpenseMemberIds = internalMutation({
  args: {
    old_member_id: v.string(),
    new_member_id: v.string(),
    account_email: v.string(),
    cursor: v.optional(v.string()),
    limit: v.optional(v.number())
  },
  handler: async (ctx, args) => {
    const groupVisibilityBatch = new GroupVisibilityWriteBatch(ctx);
    const { old_member_id, new_member_id, account_email } = args;
    const limit = args.limit ?? 32;
    validateExpenseRepairBatchSize(limit);
    const expensesPage = await ctx.db
      .query("expenses")
      .withIndex("by_owner_email", (q) => q.eq("owner_email", account_email))
      .paginate(expensePaginationOptions(args.cursor, limit));

    let fixed = 0;
    let skipped = 0;
    const expenseOperations: ExpenseMaintenanceOperation[] = [];
    for (const expense of expensesPage.page) {
      const rewrite = await rewriteExpenseMemberIdPreservingRevocation(
        ctx,
        expense,
        old_member_id,
        new_member_id
      );
      if (rewrite.operation) expenseOperations.push(rewrite.operation);
      if (rewrite.outcome === "rewritten") fixed++;
      if (rewrite.outcome === "skipped_revocation_collision") skipped++;
    }

    let groupsFixed = 0;
    if (!args.cursor) {
      const groups = await ctx.db
        .query("groups")
        .withIndex("by_owner_email", (q) => q.eq("owner_email", account_email))
        .take(MAX_REPAIR_ROWS_PER_ACCOUNT + 1);
      if (groups.length > MAX_REPAIR_ROWS_PER_ACCOUNT) {
        throw new Error(`Identity maintenance required: too many groups for ${account_email}`);
      }
      for (const group of groups) {
        const hasOldMember = group.members.some(
          (member) => normalizeMemberId(member.id) === normalizeMemberId(old_member_id)
        );
        if (hasOldMember) {
          const newMembers = group.members.map((member) => ({
            ...member,
            id:
              normalizeMemberId(member.id) === normalizeMemberId(old_member_id)
                ? normalizeMemberId(new_member_id)
                : member.id
          }));
          await groupVisibilityBatch.patch(group._id, {
            members: newMembers,
            updated_at: Date.now()
          });
          groupsFixed++;
        }
      }
    }
    await groupVisibilityBatch.flush();
    await applyExpenseWriteBatch(ctx, expenseOperations);

    return {
      expensesFixed: fixed,
      expensesSkipped: skipped,
      groupsFixed,
      continueCursor: expensesPage.isDone ? undefined : expensesPage.continueCursor,
      isDone: expensesPage.isDone
    };
  }
});

/**
 * Clear linked_member_id for a specific user email.
 * Use this to fix data isolation issues where a user has the wrong linked_member_id.
 */
export const clearLinkedMemberId = internalMutation({
  args: { email: v.string() },
  handler: async (ctx, args) => {
    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", args.email))
      .unique();

    if (!user) {
      return { success: false, error: "User not found" };
    }

    await ctx.db.patch(user._id, {
      member_id: undefined,
      updated_at: Date.now()
    });

    return {
      success: true,
      email: args.email,
      previousLinkedMemberId: user.member_id
    };
  }
});

/**
 * Set linked_member_id for a specific user email.
 * Use this to fix data where a user has the wrong linked_member_id.
 */
export const setLinkedMemberId = internalMutation({
  args: {
    email: v.string(),
    linked_member_id: v.string()
  },
  handler: async (ctx, args) => {
    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", args.email))
      .unique();

    if (!user) {
      return { success: false, error: "User not found" };
    }

    const previousId = user.member_id;

    await ctx.db.patch(user._id, {
      member_id: args.linked_member_id,
      updated_at: Date.now()
    });

    return {
      success: true,
      email: args.email,
      previousLinkedMemberId: previousId,
      newLinkedMemberId: args.linked_member_id
    };
  }
});

/**
 * Backfill participant_emails on all expenses.
 * This ensures all expenses have the correct participant_emails array
 * for cross-account visibility.
 */
export const backfillParticipantEmails = internalMutation({
  args: {
    cursor: v.optional(v.string()),
    limit: v.optional(v.number())
  },
  handler: async (ctx, args) => {
    const limit = expensePageLimit(args.limit);
    const expensesPage = await ctx.db
      .query("expenses")
      .order("asc")
      .paginate(expensePaginationOptions(args.cursor, limit));
    let updated = 0;
    const operations: ExpenseMaintenanceOperation[] = [];

    for (const expense of expensesPage.page) {
      const emails = await deriveExpenseParticipantEmails(ctx, expense);

      // Only update if emails changed
      const currentEmails = expense.participant_emails || [];
      const hasNewEmails = emails.some((e) => !currentEmails.includes(e));

      if (hasNewEmails || emails.length !== currentEmails.length) {
        operations.push(
          await expensePatchOperation(ctx, expense, {
            participant_emails: emails,
            updated_at: Date.now()
          })
        );
        updated++;
        console.log(
          `Backfilled participant_emails for expense ${expense.id}: ${emails.join(", ")}`
        );
      }
    }
    await applyExpenseWriteBatch(ctx, operations);

    return {
      processed: expensesPage.page.length,
      updated,
      continueCursor: expensesPage.isDone ? undefined : expensesPage.continueCursor,
      isDone: expensesPage.isDone
    };
  }
});

/**
 * Advanced backfill that looks up linked accounts by member_id.
 * This is more thorough than the simple backfill.
 */
export const backfillParticipantEmailsAdvanced = internalMutation({
  args: {
    cursor: v.optional(v.string()),
    limit: v.optional(v.number())
  },
  handler: async (ctx, args) => {
    const limit = expensePageLimit(args.limit);
    const expensesPage = await ctx.db
      .query("expenses")
      .order("asc")
      .paginate(expensePaginationOptions(args.cursor, limit));
    let updated = 0;
    const memberMappings = new Set<string>();
    const operations: ExpenseMaintenanceOperation[] = [];

    for (const expense of expensesPage.page) {
      const inactiveMemberIds = new Set(
        (expense.inactive_participant_member_ids ?? []).map(normalizeMemberId)
      );
      const activeAccounts = await resolveActiveExpenseParticipantAccounts(ctx, {
        ...expense,
        participant_emails: []
      });
      const accountByMemberId = new Map<string, (typeof activeAccounts)[number]>();
      for (const account of activeAccounts) {
        const memberIds = normalizeMemberIds([
          ...(account.member_id ? [account.member_id] : []),
          ...(account.alias_member_ids ?? [])
        ]);
        for (const memberId of memberIds) {
          accountByMemberId.set(memberId, account);
          memberMappings.add(`${memberId}\u0000${account.email}`);
        }
      }

      const emailArray = Array.from(
        new Set(activeAccounts.map((account) => account.email.trim().toLowerCase()))
      );
      const currentEmails = expense.participant_emails || [];
      const canonicalCurrentEmails = canonicalEmailArray(currentEmails);
      const canonicalNextEmails = canonicalEmailArray(emailArray);

      if (!arraysEqual(canonicalCurrentEmails, canonicalNextEmails)) {
        // Also update participant info with linked account details
        const updatedParticipants = expense.participants.map((p: any) => {
          if (inactiveMemberIds.has(normalizeMemberId(p.member_id))) return p;
          const account = accountByMemberId.get(normalizeMemberId(p.member_id));
          if (account) {
            return {
              ...p,
              name: account.display_name,
              linked_account_id: account.id,
              linked_account_email: account.email
            };
          }
          return p;
        });

        operations.push(
          await expensePatchOperation(ctx, expense, {
            participant_emails: emailArray,
            participants: updatedParticipants,
            updated_at: Date.now()
          })
        );
        updated++;
        console.log(`Updated expense ${expense.id} with emails: ${emailArray.join(", ")}`);
      }
    }
    await applyExpenseWriteBatch(ctx, operations);

    return {
      processed: expensesPage.page.length,
      updated,
      memberMappings: memberMappings.size,
      continueCursor: expensesPage.isDone ? undefined : expensesPage.continueCursor,
      isDone: expensesPage.isDone
    };
  }
});

export const backfillUserExpenses = internalMutation({
  args: {
    cursor: v.optional(v.string()),
    limit: v.optional(v.number())
  },
  handler: async (ctx, args) => {
    const limit = expensePageLimit(args.limit);
    const expensesPage = await ctx.db
      .query("expenses")
      .order("asc")
      .paginate(expensePaginationOptions(args.cursor, limit));
    const operations = await Promise.all(
      expensesPage.page.map((expense) => expenseVisibilityOperation(ctx, expense))
    );
    await applyExpenseWriteBatch(ctx, operations);

    return {
      processed: expensesPage.page.length,
      continueCursor: expensesPage.isDone ? undefined : expensesPage.continueCursor,
      isDone: expensesPage.isDone
    };
  }
});

/**
 * One-time repair:
 * 1) recompute `expenses.is_settled` from split-level settled state
 * 2) rebuild `participant_emails` from resolved participant accounts + owner
 * 3) reconcile `user_expenses` visibility rows from the rebuilt participant emails
 */
export const repairExpenseSettlementAndVisibility = internalMutation({
  args: {
    cursor: v.optional(v.string()),
    limit: v.optional(v.number())
  },
  handler: async (ctx, args) => {
    const limit = expensePageLimit(args.limit);
    const expensesPage = await ctx.db
      .query("expenses")
      .order("asc")
      .paginate(expensePaginationOptions(args.cursor, limit));

    let patchedCount = 0;
    let reconciledCount = 0;
    const operations: ExpenseMaintenanceOperation[] = [];

    for (const expense of expensesPage.page) {
      const computedSettled =
        Array.isArray(expense.splits) &&
        expense.splits.length > 0 &&
        expense.splits.every((split: any) => split.is_settled === true);

      const participantEmails = await deriveExpenseParticipantEmails(ctx, expense);
      const canonicalCurrentEmails = canonicalEmailArray(expense.participant_emails);
      const canonicalNextEmails = canonicalEmailArray(participantEmails);

      if (
        expense.is_settled !== computedSettled ||
        !arraysEqual(canonicalCurrentEmails, canonicalNextEmails)
      ) {
        operations.push(
          await expensePatchOperation(ctx, expense, {
            is_settled: computedSettled,
            participant_emails: canonicalNextEmails,
            updated_at: Date.now()
          })
        );
        patchedCount += 1;
      } else {
        operations.push(await expenseVisibilityOperation(ctx, expense));
      }
      reconciledCount += 1;
    }
    await applyExpenseWriteBatch(ctx, operations);

    return {
      processed: expensesPage.page.length,
      patched: patchedCount,
      reconciled: reconciledCount,
      continueCursor: expensesPage.isDone ? undefined : expensesPage.continueCursor,
      isDone: expensesPage.isDone
    };
  }
});

export const backfillFriendStatus = internalMutation({
  args: {},
  handler: async (ctx) => {
    const friends = await ctx.db.query("account_friends").collect();
    let updated = 0;

    for (const friend of friends) {
      if (!friend.status) {
        // Default to "friend" for existing records
        await ctx.db.patch(friend._id, {
          status: "friend",
          updated_at: Date.now()
        });
        updated++;
      }
    }

    return { updated, total: friends.length };
  }
});

/**
 * Backfill first_name and last_name on accounts and linked friends.
 * Splits display_name on whitespace: first word → first_name, rest → last_name.
 * For linked friends, copies first_name/last_name from the linked account.
 */
export const backfillFirstLastNames = internalMutation({
  args: {},
  handler: async (ctx) => {
    const accounts = await ctx.db.query("accounts").collect();
    let accountsUpdated = 0;

    for (const account of accounts) {
      if (account.first_name) continue; // Already backfilled
      const nameParts = (account.display_name || "").trim().split(/\s+/);
      const firstName = nameParts[0] || undefined;
      const lastName = nameParts.length > 1 ? nameParts.slice(1).join(" ") : undefined;

      if (firstName) {
        await ctx.db.patch(account._id, {
          first_name: firstName,
          last_name: lastName,
          updated_at: Date.now()
        });
        accountsUpdated++;
      }
    }

    // Refresh accounts after patching
    const updatedAccounts = await ctx.db.query("accounts").collect();
    const accountByEmail = new Map(updatedAccounts.map((a) => [a.email, a]));

    const friends = await ctx.db.query("account_friends").collect();
    let friendsUpdated = 0;

    for (const friend of friends) {
      if (friend.first_name) continue; // Already backfilled
      if (friend.has_linked_account && friend.linked_account_email) {
        const linkedAccount = accountByEmail.get(friend.linked_account_email);
        if (linkedAccount?.first_name) {
          await ctx.db.patch(friend._id, {
            first_name: linkedAccount.first_name,
            last_name: linkedAccount.last_name,
            updated_at: Date.now()
          });
          friendsUpdated++;
          continue;
        }
      }
      // Fallback: split name field
      const nameParts = (friend.name || "").trim().split(/\s+/);
      const firstName = nameParts[0] || undefined;
      const lastName = nameParts.length > 1 ? nameParts.slice(1).join(" ") : undefined;
      if (firstName) {
        await ctx.db.patch(friend._id, {
          first_name: firstName,
          last_name: lastName,
          updated_at: Date.now()
        });
        friendsUpdated++;
      }
    }

    return { accountsUpdated, friendsUpdated };
  }
});

/**
 * Backfill context_kind on all expenses.
 *
 * Legacy expenses predate the context_kind field. Without it, the iOS client
 * defaults to `.group`, which causes direct expenses to be re-sent with
 * `context_kind: "group"` — the backend then rejects the upsert with
 * "Group expenses cannot target a direct group."
 *
 * Resolution logic (mirrors `inferExpenseContextKind` in expenses.ts):
 *   1. Already has context_kind → skip
 *   2. Backing group has is_direct=true → "direct"
 *   3. Otherwise → "group"
 *
 * Run via:  npx convex run --no-push migrations:backfillExpenseContextKind
 */
export const backfillExpenseContextKind = internalMutation({
  args: {
    cursor: v.optional(v.string()),
    limit: v.optional(v.number())
  },
  handler: async (ctx, args) => {
    const limit = expensePageLimit(args.limit);
    const expensesPage = await ctx.db
      .query("expenses")
      .order("asc")
      .paginate(expensePaginationOptions(args.cursor, limit));

    let skipped = 0;
    let patchedDirect = 0;
    let patchedGroup = 0;
    const operations: ExpensePatchOperation[] = [];

    for (const expense of expensesPage.page) {
      if (expense.context_kind) {
        skipped++;
        continue;
      }

      let contextKind: "group" | "direct" = "group";

      // Look up the backing group to determine if it's a direct expense
      if (expense.group_ref) {
        const group = await ctx.db.get(expense.group_ref);
        if (group?.is_direct === true) {
          contextKind = "direct";
        }
      } else if (expense.group_id) {
        // Fallback: resolve group by client id when group_ref is missing
        const group = await ctx.db
          .query("groups")
          .withIndex("by_client_id", (q: any) => q.eq("id", expense.group_id))
          .unique();
        if (group?.is_direct === true) {
          contextKind = "direct";
        }
      }

      operations.push(
        await expensePatchOperation(ctx, expense, {
          context_kind: contextKind,
          updated_at: Date.now()
        })
      );

      if (contextKind === "direct") {
        patchedDirect++;
      } else {
        patchedGroup++;
      }
    }
    await applyExpenseWriteBatch(ctx, operations);

    return {
      total: expensesPage.page.length,
      processed: expensesPage.page.length,
      skipped,
      patchedDirect,
      patchedGroup,
      continueCursor: expensesPage.isDone ? undefined : expensesPage.continueCursor,
      isDone: expensesPage.isDone
    };
  }
});

/**
 * Resumable identity rollout. Each call performs at most batchSize alias operations and
 * records its own cursor. The ready marker is written only after both tables are complete.
 */
export const runIdentityMaterializationMigration = internalMutation({
  args: {
    batchSize: v.optional(v.number())
  },
  handler: async (ctx, args) => {
    const batchSize = args.batchSize ?? 64;
    if (!Number.isInteger(batchSize) || batchSize < 1 || batchSize > 128) {
      throw new Error("batchSize must be an integer between 1 and 128");
    }

    let state: any = await ctx.db
      .query("identity_materialization_state")
      .withIndex("by_key", (q) => q.eq("key", IDENTITY_MATERIALIZATION_KEY))
      .unique();
    if (!state) {
      const stateId = await ctx.db.insert("identity_materialization_state", {
        key: IDENTITY_MATERIALIZATION_KEY,
        status: "pending",
        phase: "aliases",
        updated_at: Date.now()
      });
      state = await ctx.db.get(stateId);
    }
    if (state.status === "ready") {
      return { status: "ready" as const, phase: "complete" as const, lastError: undefined };
    }

    if (state.phase === "aliases") {
      const page = await ctx.db.query("member_aliases").paginate({
        cursor: state.cursor ?? null,
        numItems: batchSize
      });
      const normalizedPage = page.page.map((row) => ({
        row,
        aliasMemberId: normalizeMemberId(row.alias_member_id),
        canonicalMemberId: normalizeMemberId(row.canonical_member_id)
      }));
      const pageIds = new Set(page.page.map((row) => String(row._id)));
      const pageCanonicalOwners = new Map<string, string>();
      for (const entry of normalizedPage) {
        const pageCanonical = pageCanonicalOwners.get(entry.aliasMemberId);
        if (pageCanonical && pageCanonical !== entry.canonicalMemberId) {
          const lastError = `Conflicting alias ownership for ${entry.aliasMemberId}`;
          await ctx.db.patch(state._id, { last_error: lastError, updated_at: Date.now() });
          return { status: "pending" as const, phase: "aliases" as const, lastError };
        }
        pageCanonicalOwners.set(entry.aliasMemberId, entry.canonicalMemberId);
      }

      const deleteIds = new Set<Doc<"member_aliases">["_id"]>();
      const survivorPatches = new Map<
        Doc<"member_aliases">["_id"],
        { alias_member_id: string; canonical_member_id: string; account_email: string }
      >();
      for (const aliasMemberId of pageCanonicalOwners.keys()) {
        const indexedRows = await ctx.db
          .query("member_aliases")
          .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", aliasMemberId))
          .take(MAX_ALIAS_ROWS_PER_MEMBER_ID + 1);
        const rowsById = new Map<string, Doc<"member_aliases">>();
        for (const row of indexedRows) rowsById.set(String(row._id), row);
        for (const entry of normalizedPage) {
          if (entry.aliasMemberId === aliasMemberId) {
            rowsById.set(String(entry.row._id), entry.row);
          }
        }
        const candidateRows = Array.from(rowsById.values());
        if (candidateRows.length > MAX_ALIAS_ROWS_PER_MEMBER_ID) {
          const lastError = `Too many alias rows for ${aliasMemberId}`;
          await ctx.db.patch(state._id, { last_error: lastError, updated_at: Date.now() });
          return { status: "pending" as const, phase: "aliases" as const, lastError };
        }
        const canonicalIds = new Set(
          candidateRows.map((row) => normalizeMemberId(row.canonical_member_id))
        );
        if (canonicalIds.size > 1) {
          const lastError = `Conflicting alias ownership for ${aliasMemberId}`;
          await ctx.db.patch(state._id, { last_error: lastError, updated_at: Date.now() });
          return { status: "pending" as const, phase: "aliases" as const, lastError };
        }

        const rowsBySource = new Map<string | null, Doc<"member_aliases">[]>();
        for (const row of candidateRows) {
          const sourceKey = row.source_account_id ?? null;
          const sourceRows = rowsBySource.get(sourceKey) ?? [];
          sourceRows.push(row);
          rowsBySource.set(sourceKey, sourceRows);
        }
        for (const sourceRows of rowsBySource.values()) {
          sourceRows.sort(
            (left, right) =>
              left._creationTime - right._creationTime ||
              String(left._id).localeCompare(String(right._id))
          );
          const survivor = sourceRows[0];
          for (const duplicate of sourceRows.slice(1)) {
            if (pageIds.has(String(duplicate._id))) deleteIds.add(duplicate._id);
          }
          if (pageIds.has(String(survivor._id))) {
            survivorPatches.set(survivor._id, {
              alias_member_id: aliasMemberId,
              canonical_member_id: normalizeMemberId(survivor.canonical_member_id),
              account_email: survivor.account_email.trim().toLowerCase()
            });
          }
        }
      }

      for (const deleteId of deleteIds) await ctx.db.delete(deleteId);
      for (const [survivorId, patch] of survivorPatches) {
        if (!deleteIds.has(survivorId)) await ctx.db.patch(survivorId, patch);
      }
      await ctx.db.patch(state._id, {
        phase: page.isDone ? "accounts" : "aliases",
        cursor: page.isDone ? undefined : page.continueCursor,
        last_error: undefined,
        updated_at: Date.now()
      });
      return {
        status: "pending" as const,
        phase: page.isDone ? ("accounts" as const) : ("aliases" as const),
        lastError: undefined
      };
    }

    const persistError = async (
      phase: "accounts" | "alias_provenance" | "account_aliases",
      lastError: string
    ) => {
      await ctx.db.patch(state._id, { last_error: lastError, updated_at: Date.now() });
      return { status: "pending" as const, phase, lastError };
    };

    if (state.phase === "accounts") {
      const page = await ctx.db.query("accounts").paginate({
        cursor: state.cursor ?? null,
        numItems: batchSize
      });
      const normalizedAccounts = page.page.map((account) => {
        const canonicalMemberId = account.member_id
          ? normalizeMemberId(account.member_id)
          : undefined;
        const aliases = normalizeMemberIds(account.alias_member_ids).filter(
          (alias) => alias !== canonicalMemberId
        );
        return { account, canonicalMemberId, aliases };
      });

      const canonicalOwners = new Map<string, Doc<"accounts">["_id"]>();
      for (const normalizedAccount of normalizedAccounts) {
        const { account, canonicalMemberId, aliases } = normalizedAccount;
        if (aliases.length > MAX_LIVE_ACCOUNT_ALIASES) {
          return await persistError(
            "accounts",
            `Identity maintenance required: account ${account.id} has ${aliases.length} aliases; maximum is ${MAX_LIVE_ACCOUNT_ALIASES}`
          );
        }
        if (!canonicalMemberId) {
          if (aliases.length > 0) {
            return await persistError(
              "accounts",
              `Identity maintenance required: account ${account.id} has aliases without a canonical member_id`
            );
          }
          continue;
        }

        const pageOwner = canonicalOwners.get(canonicalMemberId);
        if (pageOwner && pageOwner !== account._id) {
          return await persistError(
            "accounts",
            `Conflicting canonical account identity ${canonicalMemberId}`
          );
        }
        canonicalOwners.set(canonicalMemberId, account._id);

        const collisions = await ctx.db
          .query("accounts")
          .withIndex("by_member_id", (q) => q.eq("member_id", canonicalMemberId))
          .take(2);
        if (collisions.some((candidate) => candidate._id !== account._id)) {
          return await persistError(
            "accounts",
            `Conflicting canonical account identity ${canonicalMemberId}`
          );
        }
      }

      for (const { account, canonicalMemberId, aliases } of normalizedAccounts) {
        await ctx.db.patch(account._id, {
          member_id: canonicalMemberId,
          alias_member_ids: aliases,
          updated_at: Date.now()
        });
      }
      await ctx.db.patch(state._id, {
        phase: page.isDone ? "alias_provenance" : "accounts",
        cursor: page.isDone ? undefined : page.continueCursor,
        current_account_id: undefined,
        next_account_cursor: undefined,
        alias_offset: undefined,
        last_error: undefined,
        updated_at: Date.now()
      });
      return {
        status: "pending" as const,
        phase: page.isDone ? ("alias_provenance" as const) : ("accounts" as const),
        lastError: undefined
      };
    }

    if (state.phase === "alias_provenance") {
      const page = await ctx.db.query("member_aliases").paginate({
        cursor: state.cursor ?? null,
        numItems: batchSize
      });
      const resolvedPage: Array<{
        row: Doc<"member_aliases">;
        aliasMemberId: string;
        canonicalMemberId: string;
        canonicalAccount: Doc<"accounts">;
      }> = [];
      const provenancePageIds = new Set(page.page.map((row) => String(row._id)));
      for (const alias of page.page) {
        const aliasMemberId = normalizeMemberId(alias.alias_member_id);
        const canonicalMemberId = normalizeMemberId(alias.canonical_member_id);
        const canonicalAccounts = await ctx.db
          .query("accounts")
          .withIndex("by_member_id", (q) => q.eq("member_id", canonicalMemberId))
          .take(2);
        const canonicalAccount = canonicalAccounts.length === 1 ? canonicalAccounts[0] : null;
        const isCorroborated =
          canonicalAccount !== null &&
          normalizeMemberIds(canonicalAccount.alias_member_ids).includes(aliasMemberId);
        if (!isCorroborated) {
          return await persistError(
            "alias_provenance",
            `Unproven legacy alias ${aliasMemberId}; migrate it to an owner-local friend alias or remove it`
          );
        }

        const canonicalShadow = await ctx.db
          .query("accounts")
          .withIndex("by_member_id", (q) => q.eq("member_id", aliasMemberId))
          .first();
        if (canonicalShadow) {
          return await persistError(
            "alias_provenance",
            `Alias ${aliasMemberId} shadows canonical account identity ${aliasMemberId}`
          );
        }

        resolvedPage.push({
          row: alias,
          aliasMemberId,
          canonicalMemberId,
          canonicalAccount
        });
      }

      const pageProvenanceOwners = new Map<
        string,
        { canonicalMemberId: string; sourceAccountId: string }
      >();
      for (const entry of resolvedPage) {
        const existingOwner = pageProvenanceOwners.get(entry.aliasMemberId);
        if (
          existingOwner &&
          (existingOwner.canonicalMemberId !== entry.canonicalMemberId ||
            existingOwner.sourceAccountId !== entry.canonicalAccount.id)
        ) {
          return await persistError(
            "alias_provenance",
            `Conflicting alias ownership for ${entry.aliasMemberId}`
          );
        }
        pageProvenanceOwners.set(entry.aliasMemberId, {
          canonicalMemberId: entry.canonicalMemberId,
          sourceAccountId: entry.canonicalAccount.id
        });
      }

      const provenanceDeleteIds = new Set<Doc<"member_aliases">["_id"]>();
      const provenancePatches = new Map<
        Doc<"member_aliases">["_id"],
        {
          canonical_member_id: string;
          alias_member_id: string;
          account_email: string;
          materialization_source: "account_alias";
          source_account_id: string;
        }
      >();
      const provenanceGroups = new Map<string, typeof resolvedPage>();
      for (const entry of resolvedPage) {
        const key = `${entry.canonicalAccount.id}\u0000${entry.aliasMemberId}`;
        const entries = provenanceGroups.get(key) ?? [];
        entries.push(entry);
        provenanceGroups.set(key, entries);
      }
      for (const entries of provenanceGroups.values()) {
        const { canonicalAccount, aliasMemberId, canonicalMemberId } = entries[0];
        const sourceRows = await ctx.db
          .query("member_aliases")
          .withIndex("by_source_account_and_alias", (q) =>
            q.eq("source_account_id", canonicalAccount.id).eq("alias_member_id", aliasMemberId)
          )
          .take(MAX_ALIAS_ROWS_PER_MEMBER_ID + 1);
        const rowsById = new Map<string, Doc<"member_aliases">>();
        for (const sourceRow of sourceRows) rowsById.set(String(sourceRow._id), sourceRow);
        for (const entry of entries) rowsById.set(String(entry.row._id), entry.row);
        const convergingRows = Array.from(rowsById.values());
        if (convergingRows.length > MAX_ALIAS_ROWS_PER_MEMBER_ID) {
          return await persistError("alias_provenance", `Too many alias rows for ${aliasMemberId}`);
        }
        if (
          convergingRows.some(
            (row) => normalizeMemberId(row.canonical_member_id) !== canonicalMemberId
          )
        ) {
          return await persistError(
            "alias_provenance",
            `Conflicting alias ownership for ${aliasMemberId}`
          );
        }
        convergingRows.sort(
          (left, right) =>
            left._creationTime - right._creationTime ||
            String(left._id).localeCompare(String(right._id))
        );
        const survivor = convergingRows[0];
        for (const duplicate of convergingRows.slice(1)) {
          if (provenancePageIds.has(String(duplicate._id))) {
            provenanceDeleteIds.add(duplicate._id);
          }
        }
        if (provenancePageIds.has(String(survivor._id))) {
          provenancePatches.set(survivor._id, {
            canonical_member_id: canonicalMemberId,
            alias_member_id: aliasMemberId,
            account_email: canonicalAccount.email.trim().toLowerCase(),
            materialization_source: "account_alias",
            source_account_id: canonicalAccount.id
          });
        }
      }

      for (const deleteId of provenanceDeleteIds) await ctx.db.delete(deleteId);
      for (const [survivorId, patch] of provenancePatches) {
        if (!provenanceDeleteIds.has(survivorId)) await ctx.db.patch(survivorId, patch);
      }
      await ctx.db.patch(state._id, {
        phase: page.isDone ? "account_aliases" : "alias_provenance",
        cursor: page.isDone ? undefined : page.continueCursor,
        last_error: undefined,
        updated_at: Date.now()
      });
      return {
        status: "pending" as const,
        phase: page.isDone ? ("account_aliases" as const) : ("alias_provenance" as const),
        lastError: undefined
      };
    }

    if (!state.current_account_id) {
      const page = await ctx.db.query("accounts").paginate({
        cursor: state.cursor ?? null,
        numItems: batchSize
      });
      if (page.page.length === 0) {
        await ctx.db.patch(state._id, {
          status: "ready",
          phase: "complete",
          cursor: undefined,
          current_account_id: undefined,
          next_account_cursor: undefined,
          alias_offset: undefined,
          last_error: undefined,
          updated_at: Date.now()
        });
        return { status: "ready" as const, phase: "complete" as const, lastError: undefined };
      }

      const normalizedAccounts = page.page.map((account) => {
        const canonicalMemberId = account.member_id
          ? normalizeMemberId(account.member_id)
          : undefined;
        const aliases = normalizeMemberIds(account.alias_member_ids).filter(
          (alias) => alias !== canonicalMemberId
        );
        return { account, canonicalMemberId, aliases };
      });
      const aliasCount = normalizedAccounts.reduce(
        (total, normalizedAccount) => total + normalizedAccount.aliases.length,
        0
      );

      if (aliasCount <= batchSize) {
        const materializations: Array<
          Awaited<ReturnType<typeof preflightNormalizedAccountAliasMaterialization>>
        > = [];
        try {
          const pageAliasOwners = new Map<
            string,
            { canonicalMemberId: string; accountId: string }
          >();
          for (const { account, canonicalMemberId, aliases } of normalizedAccounts) {
            if (aliases.length > MAX_LIVE_ACCOUNT_ALIASES) {
              throw new Error(
                `Identity maintenance required: account ${account.id} has ${aliases.length} aliases; maximum is ${MAX_LIVE_ACCOUNT_ALIASES}`
              );
            }
            if (!canonicalMemberId && aliases.length > 0) {
              throw new Error(
                `Identity maintenance required: account ${account.id} has aliases without a canonical member_id`
              );
            }
            if (!canonicalMemberId) continue;
            const accountIdentity = {
              id: account.id,
              email: account.email,
              member_id: canonicalMemberId
            };
            for (const alias of aliases) {
              const pageOwner = pageAliasOwners.get(alias);
              if (
                pageOwner &&
                (pageOwner.canonicalMemberId !== canonicalMemberId ||
                  pageOwner.accountId !== account.id)
              ) {
                throw new Error(`Conflicting account alias ownership for ${alias}`);
              }
              pageAliasOwners.set(alias, { canonicalMemberId, accountId: account.id });
              materializations.push(
                await preflightNormalizedAccountAliasMaterialization(ctx, accountIdentity, alias)
              );
            }
          }
          for (const materialization of materializations) {
            await applyPreflightedAccountAliasMaterialization(ctx, materialization);
          }
        } catch (error) {
          const lastError =
            error instanceof Error ? error.message : "Unknown identity maintenance error";
          return await persistError("account_aliases", lastError);
        }

        if (page.isDone) {
          await ctx.db.patch(state._id, {
            status: "ready",
            phase: "complete",
            cursor: undefined,
            current_account_id: undefined,
            next_account_cursor: undefined,
            alias_offset: undefined,
            last_error: undefined,
            updated_at: Date.now()
          });
          return { status: "ready" as const, phase: "complete" as const, lastError: undefined };
        }
        await ctx.db.patch(state._id, {
          cursor: page.continueCursor,
          last_error: undefined,
          updated_at: Date.now()
        });
        return {
          status: "pending" as const,
          phase: "account_aliases" as const,
          lastError: undefined
        };
      }
    }

    let account: Doc<"accounts"> | null = state.current_account_id
      ? await ctx.db.get(state.current_account_id as Doc<"accounts">["_id"])
      : null;
    let nextAccountCursor = state.next_account_cursor;
    if (!account) {
      const page = await ctx.db.query("accounts").paginate({
        cursor: state.cursor ?? null,
        numItems: 1
      });
      account = page.page[0] ?? null;
      nextAccountCursor = page.continueCursor;
      if (!account) {
        await ctx.db.patch(state._id, {
          status: "ready",
          phase: "complete",
          cursor: undefined,
          current_account_id: undefined,
          next_account_cursor: undefined,
          alias_offset: undefined,
          last_error: undefined,
          updated_at: Date.now()
        });
        return { status: "ready" as const, phase: "complete" as const, lastError: undefined };
      }
    }

    const canonicalMemberId = account.member_id ? normalizeMemberId(account.member_id) : undefined;
    const aliases = normalizeMemberIds(account.alias_member_ids).filter(
      (alias) => alias !== canonicalMemberId
    );
    if (aliases.length > MAX_LIVE_ACCOUNT_ALIASES) {
      return await persistError(
        "account_aliases",
        `Identity maintenance required: account ${account.id} has ${aliases.length} aliases; maximum is ${MAX_LIVE_ACCOUNT_ALIASES}`
      );
    }
    if (!canonicalMemberId && aliases.length > 0) {
      return await persistError(
        "account_aliases",
        `Identity maintenance required: account ${account.id} has aliases without a canonical member_id`
      );
    }

    const aliasOffset = state.current_account_id ? (state.alias_offset ?? 0) : 0;
    const batch = aliases.slice(aliasOffset, aliasOffset + batchSize);
    if (canonicalMemberId) {
      const accountIdentity = {
        id: account.id,
        email: account.email,
        member_id: canonicalMemberId
      };
      try {
        const materializations: Array<
          Awaited<ReturnType<typeof preflightNormalizedAccountAliasMaterialization>>
        > = [];
        for (const alias of batch) {
          materializations.push(
            await preflightNormalizedAccountAliasMaterialization(ctx, accountIdentity, alias)
          );
        }
        for (const materialization of materializations) {
          await applyPreflightedAccountAliasMaterialization(ctx, materialization);
        }
      } catch (error) {
        const lastError =
          error instanceof Error ? error.message : "Unknown identity maintenance error";
        return await persistError("account_aliases", lastError);
      }
    }

    const nextOffset = aliasOffset + batch.length;
    if (nextOffset < aliases.length) {
      await ctx.db.patch(state._id, {
        current_account_id: account._id,
        next_account_cursor: nextAccountCursor,
        alias_offset: nextOffset,
        last_error: undefined,
        updated_at: Date.now()
      });
    } else {
      await ctx.db.patch(state._id, {
        cursor: nextAccountCursor,
        current_account_id: undefined,
        next_account_cursor: undefined,
        alias_offset: undefined,
        last_error: undefined,
        updated_at: Date.now()
      });
    }
    return {
      status: "pending" as const,
      phase: "account_aliases" as const,
      lastError: undefined
    };
  }
});
