import { internalMutation } from "./_generated/server";
import { Doc } from "./_generated/dataModel";
import { v } from "convex/values";
import { getRandomAvatarColor } from "./utils";
import { reconcileUserExpenses } from "./helpers";
import {
  ensureAccountAliasMaterialization,
  ensureStandaloneAlias,
  findAliasByAliasMemberId,
  findAccountByAuthIdOrDocId,
  findAccountByMemberId,
  IDENTITY_MATERIALIZATION_KEY,
  MAX_ALIAS_ROWS_PER_MEMBER_ID,
  normalizeMemberId,
  normalizeMemberIds,
  preflightAccountAliasMaterialization
} from "./identity";

function normalizeEmail(value: string | undefined | null): string | undefined {
  if (typeof value !== "string") return undefined;
  const normalized = value.trim().toLowerCase();
  return normalized.length > 0 ? normalized : undefined;
}

async function deriveExpenseParticipantEmails(ctx: any, expense: any): Promise<string[]> {
  const emailSet = new Set<string>();
  const ownerEmail = normalizeEmail(expense.owner_email);
  if (ownerEmail) {
    emailSet.add(ownerEmail);
  }

  for (const participant of expense.participants ?? []) {
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
        emailSet.add(normalized);
      }
    }
  }

  for (const memberId of expense.participant_member_ids ?? []) {
    const account = await findAccountByMemberId(ctx.db, memberId);
    if (account?.email) {
      const normalized = normalizeEmail(account.email);
      if (normalized) {
        emailSet.add(normalized);
      }
    }
  }

  return Array.from(emailSet);
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

      if (
        await ensureStandaloneAlias(ctx, {
          canonicalMemberId: canonicalId,
          aliasMemberId: aliasId,
          provenanceEmail: token.creator_email,
          createdAt: token.claimed_at || Date.now()
        })
      ) {
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
        await ctx.db.patch(group._id, { members: newMembers });
        groupsUpdated++;
      }
    }

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
  args: {},
  handler: async (ctx) => {
    const accounts = await ctx.db.query("accounts").collect();
    let expensesFixed = 0;

    for (const account of accounts) {
      if (!account.member_id) continue;

      // Get all groups owned by this account
      const groups = await ctx.db
        .query("groups")
        .withIndex("by_owner_email", (q) => q.eq("owner_email", account.email))
        .collect();

      // Collect all member IDs from groups to identify "old" member IDs used for this account
      const knownMemberIds = new Set<string>();
      for (const group of groups) {
        for (const member of group.members) {
          // If member name matches display name, it's the user
          if (member.name.toLowerCase() === account.display_name.toLowerCase()) {
            knownMemberIds.add(member.id);
          }
        }
      }

      // Get expenses owned by this account
      const expenses = await ctx.db
        .query("expenses")
        .withIndex("by_owner_email", (q) => q.eq("owner_email", account.email))
        .collect();

      for (const expense of expenses) {
        let needsPatch = false;
        const patches: any = {};

        // Fix paid_by_member_id if it's not the linked_member_id but is in knownMemberIds
        // OR if it matches none of the group members (orphaned ID)
        if (expense.paid_by_member_id !== account.member_id) {
          // Check if it was the user who paid (name-based matching in participants)
          const userParticipant = expense.participants?.find(
            (p: any) => p.name.toLowerCase() === account.display_name.toLowerCase()
          );

          if (userParticipant && userParticipant.member_id !== account.member_id) {
            // This expense's participant is the user, update the member ID
            patches.paid_by_member_id = account.member_id;
            patches.involved_member_ids = expense.involved_member_ids.map((id: string) =>
              id === expense.paid_by_member_id ? account.member_id : id
            );
            patches.splits = expense.splits.map((s: any) => ({
              ...s,
              member_id: s.member_id === expense.paid_by_member_id ? account.member_id : s.member_id
            }));
            patches.participants = expense.participants.map((p: any) => ({
              ...p,
              member_id: p.member_id === expense.paid_by_member_id ? account.member_id : p.member_id
            }));
            patches.participant_member_ids = expense.participant_member_ids.map((id: string) =>
              id === expense.paid_by_member_id ? account.member_id : id
            );
            needsPatch = true;
          }
        }

        if (needsPatch) {
          await ctx.db.patch(expense._id, patches);
          console.log(`Fixed expense ${expense.id} for ${account.email}`);
          expensesFixed++;
        }
      }
    }

    return { expensesFixed };
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
    account_email: v.string()
  },
  handler: async (ctx, args) => {
    const { old_member_id, new_member_id, account_email } = args;

    // Get ALL expenses for this account
    const expenses = await ctx.db
      .query("expenses")
      .withIndex("by_owner_email", (q) => q.eq("owner_email", account_email))
      .collect();

    let fixed = 0;

    for (const expense of expenses) {
      const patches: any = { updated_at: Date.now() };
      let needsPatch = false;

      // Fix paid_by_member_id
      if (expense.paid_by_member_id === old_member_id) {
        patches.paid_by_member_id = new_member_id;
        needsPatch = true;
      }

      // Fix involved_member_ids
      if (expense.involved_member_ids.includes(old_member_id)) {
        patches.involved_member_ids = expense.involved_member_ids.map((id: string) =>
          id === old_member_id ? new_member_id : id
        );
        needsPatch = true;
      }

      // Fix splits
      const hasOldSplit = expense.splits.some((s: any) => s.member_id === old_member_id);
      if (hasOldSplit) {
        patches.splits = expense.splits.map((s: any) => ({
          ...s,
          member_id: s.member_id === old_member_id ? new_member_id : s.member_id
        }));
        needsPatch = true;
      }

      // Fix participants
      const hasOldParticipant = expense.participants?.some(
        (p: any) => p.member_id === old_member_id
      );
      if (hasOldParticipant) {
        patches.participants = expense.participants.map((p: any) => ({
          ...p,
          member_id: p.member_id === old_member_id ? new_member_id : p.member_id
        }));
        needsPatch = true;
      }

      // Fix participant_member_ids
      if (expense.participant_member_ids?.includes(old_member_id)) {
        patches.participant_member_ids = expense.participant_member_ids.map((id: string) =>
          id === old_member_id ? new_member_id : id
        );
        needsPatch = true;
      }

      if (needsPatch) {
        await ctx.db.patch(expense._id, patches);
        console.log(`Fixed expense ${expense.id}`);
        fixed++;
      }
    }

    // Also fix groups
    const groups = await ctx.db
      .query("groups")
      .withIndex("by_owner_email", (q) => q.eq("owner_email", account_email))
      .collect();

    let groupsFixed = 0;
    for (const group of groups) {
      const hasOldMember = group.members.some((m: any) => m.id === old_member_id);
      if (hasOldMember) {
        const newMembers = group.members.map((m: any) => ({
          ...m,
          id: m.id === old_member_id ? new_member_id : m.id
        }));
        await ctx.db.patch(group._id, { members: newMembers, updated_at: Date.now() });
        console.log(`Fixed group ${group.id}`);
        groupsFixed++;
      }
    }

    return { expensesFixed: fixed, groupsFixed };
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
  args: {},
  handler: async (ctx) => {
    const expenses = await ctx.db.query("expenses").collect();
    let updated = 0;

    for (const expense of expenses) {
      // Build participant_emails from participants array + owner
      const emails: string[] = [];

      // Add owner email
      if (expense.owner_email && !emails.includes(expense.owner_email)) {
        emails.push(expense.owner_email);
      }

      // Add linked participant emails
      for (const p of expense.participants || []) {
        if (p.linked_account_email && !emails.includes(p.linked_account_email)) {
          emails.push(p.linked_account_email);
        }
      }

      // Only update if emails changed
      const currentEmails = expense.participant_emails || [];
      const hasNewEmails = emails.some((e) => !currentEmails.includes(e));

      if (hasNewEmails || emails.length !== currentEmails.length) {
        await ctx.db.patch(expense._id, {
          participant_emails: emails,
          updated_at: Date.now()
        });
        const visibilityUsers = await Promise.all(
          emails.map((email) =>
            ctx.db
              .query("accounts")
              .withIndex("by_email", (q: any) => q.eq("email", email))
              .unique()
          )
        );
        const visibilityUserIds = visibilityUsers
          .filter((account): account is NonNullable<typeof account> => account !== null)
          .map((account) => account.id);
        await reconcileUserExpenses(ctx, expense.id, visibilityUserIds);
        updated++;
        console.log(
          `Backfilled participant_emails for expense ${expense.id}: ${emails.join(", ")}`
        );
      }
    }

    return { updated };
  }
});

/**
 * Advanced backfill that looks up linked accounts by member_id.
 * This is more thorough than the simple backfill.
 */
export const backfillParticipantEmailsAdvanced = internalMutation({
  args: {},
  handler: async (ctx) => {
    // Build a map of member_id -> account email
    const accounts = await ctx.db.query("accounts").collect();
    const memberIdToEmail = new Map<string, string>();

    for (const account of accounts) {
      if (account.member_id) {
        memberIdToEmail.set(account.member_id, account.email);
        console.log(`Member ${account.member_id} -> ${account.email}`);
      }
    }

    const expenses = await ctx.db.query("expenses").collect();
    let updated = 0;

    for (const expense of expenses) {
      const emails = new Set<string>();

      // Add owner email
      if (expense.owner_email) {
        emails.add(expense.owner_email);
      }

      // Add linked participant emails from lookup
      for (const memberId of expense.involved_member_ids) {
        const email = memberIdToEmail.get(memberId);
        if (email) {
          emails.add(email);
        }
      }

      const emailArray = Array.from(emails);
      const currentEmails = expense.participant_emails || [];

      // Check if we have new emails to add
      const hasNewEmails = emailArray.some((e) => !currentEmails.includes(e));

      if (hasNewEmails || emailArray.length > currentEmails.length) {
        // Also update participant info with linked account details
        const updatedParticipants = expense.participants.map((p: any) => {
          const email = memberIdToEmail.get(p.member_id);
          const account = accounts.find((a) => a.email === email);
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

        await ctx.db.patch(expense._id, {
          participant_emails: emailArray,
          participants: updatedParticipants,
          updated_at: Date.now()
        });
        const visibilityUsers = await Promise.all(
          emailArray.map((email) =>
            ctx.db
              .query("accounts")
              .withIndex("by_email", (q: any) => q.eq("email", email))
              .unique()
          )
        );
        const visibilityUserIds = visibilityUsers
          .filter((account): account is NonNullable<typeof account> => account !== null)
          .map((account) => account.id);
        await reconcileUserExpenses(ctx, expense.id, visibilityUserIds);
        updated++;
        console.log(`Updated expense ${expense.id} with emails: ${emailArray.join(", ")}`);
      }
    }

    return { updated, memberMappings: memberIdToEmail.size };
  }
});

export const backfillUserExpenses = internalMutation({
  args: {},
  handler: async (ctx) => {
    const expenses = await ctx.db.query("expenses").collect();
    let processed = 0;

    for (const expense of expenses) {
      // 1. Collect User IDs (Owner + derived participants)
      const userIds = new Set<string>();
      if (expense.owner_account_id) {
        userIds.add(expense.owner_account_id);
      }

      // Add linked accounts from participants array
      if (expense.participants) {
        for (const p of expense.participants) {
          if (p.linked_account_id) {
            userIds.add(p.linked_account_id);
          }
        }
      }

      // Resolve participant_emails to accounts
      if (expense.participant_emails) {
        for (const email of expense.participant_emails) {
          const account = await ctx.db
            .query("accounts")
            .withIndex("by_email", (q) => q.eq("email", email))
            .unique();
          if (account) {
            userIds.add(account.id);
          }
        }
      }

      // 2. Reconcile
      await reconcileUserExpenses(ctx, expense.id, Array.from(userIds));
      processed++;
    }

    return { processed };
  }
});

/**
 * One-time repair:
 * 1) recompute `expenses.is_settled` from split-level settled state
 * 2) rebuild `participant_emails` from resolved participant accounts + owner
 * 3) reconcile `user_expenses` visibility rows from the rebuilt participant emails
 */
export const repairExpenseSettlementAndVisibility = internalMutation({
  args: {},
  handler: async (ctx) => {
    const expenses = await ctx.db.query("expenses").collect();

    let patchedCount = 0;
    let reconciledCount = 0;

    for (const expense of expenses) {
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
        await ctx.db.patch(expense._id, {
          is_settled: computedSettled,
          participant_emails: canonicalNextEmails,
          updated_at: Date.now()
        });
        patchedCount += 1;
      }

      const participantUsers = await Promise.all(
        canonicalNextEmails.map((email) =>
          ctx.db
            .query("accounts")
            .withIndex("by_email", (q: any) => q.eq("email", email))
            .unique()
        )
      );
      const participantUserIds = participantUsers
        .filter((user): user is NonNullable<typeof user> => user !== null)
        .map((user) => user.id);
      await reconcileUserExpenses(ctx, expense.id, participantUserIds);
      reconciledCount += 1;
    }

    return {
      processed: expenses.length,
      patched: patchedCount,
      reconciled: reconciledCount
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
  args: {},
  handler: async (ctx) => {
    const expenses = await ctx.db.query("expenses").collect();

    let skipped = 0;
    let patchedDirect = 0;
    let patchedGroup = 0;

    for (const expense of expenses) {
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

      await ctx.db.patch(expense._id, {
        context_kind: contextKind,
        updated_at: Date.now()
      });

      if (contextKind === "direct") {
        patchedDirect++;
      } else {
        patchedGroup++;
      }
    }

    return {
      total: expenses.length,
      skipped,
      patchedDirect,
      patchedGroup
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
      const deletedIds = new Set<string>();
      for (const alias of page.page) {
        if (deletedIds.has(String(alias._id))) continue;
        const aliasMemberId = normalizeMemberId(alias.alias_member_id);
        const canonicalMemberId = normalizeMemberId(alias.canonical_member_id);
        const accountEmail = alias.account_email.trim().toLowerCase();
        const candidates = await ctx.db
          .query("member_aliases")
          .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", aliasMemberId))
          .take(MAX_ALIAS_ROWS_PER_MEMBER_ID + 1);
        if (candidates.length > MAX_ALIAS_ROWS_PER_MEMBER_ID) {
          const lastError = `Too many alias rows for ${aliasMemberId}`;
          await ctx.db.patch(state._id, { last_error: lastError, updated_at: Date.now() });
          return { status: "pending" as const, phase: "aliases" as const, lastError };
        }
        const conflict = candidates.find(
          (candidate) =>
            candidate._id !== alias._id &&
            normalizeMemberId(candidate.canonical_member_id) !== canonicalMemberId
        );
        if (conflict) {
          const lastError = `Conflicting alias ownership for ${aliasMemberId}`;
          await ctx.db.patch(state._id, { last_error: lastError, updated_at: Date.now() });
          return { status: "pending" as const, phase: "aliases" as const, lastError };
        }
        const sameSource = candidates.find(
          (candidate) =>
            candidate._id !== alias._id &&
            (candidate.source_account_id ?? null) === (alias.source_account_id ?? null)
        );
        if (sameSource) {
          const keepExisting =
            sameSource._creationTime < alias._creationTime ||
            (sameSource._creationTime === alias._creationTime &&
              String(sameSource._id) < String(alias._id));
          const deletedId = keepExisting ? alias._id : sameSource._id;
          await ctx.db.delete(deletedId);
          deletedIds.add(String(deletedId));
          if (keepExisting) continue;
        }
        await ctx.db.patch(alias._id, {
          alias_member_id: aliasMemberId,
          canonical_member_id: canonicalMemberId,
          account_email: accountEmail
        });
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
    if (canonicalMemberId) {
      const collisions = await ctx.db
        .query("accounts")
        .withIndex("by_member_id", (q) => q.eq("member_id", canonicalMemberId))
        .take(2);
      const collision = collisions.find((candidate) => candidate._id !== account!._id);
      if (collision) {
        const lastError = `Conflicting canonical account identity ${canonicalMemberId}`;
        await ctx.db.patch(state._id, { last_error: lastError, updated_at: Date.now() });
        return { status: "pending" as const, phase: "accounts" as const, lastError };
      }

      const shadowingAlias = await findAliasByAliasMemberId(ctx.db, account.member_id!);
      if (shadowingAlias) {
        const lastError = `Alias ${shadowingAlias.alias_member_id} shadows canonical account identity ${canonicalMemberId}`;
        await ctx.db.patch(state._id, { last_error: lastError, updated_at: Date.now() });
        return { status: "pending" as const, phase: "accounts" as const, lastError };
      }
    }

    const aliases = normalizeMemberIds(account.alias_member_ids);
    const aliasOffset = state.current_account_id ? (state.alias_offset ?? 0) : 0;
    const batch = aliases.slice(aliasOffset, aliasOffset + batchSize);
    if (canonicalMemberId) {
      const accountIdentity = {
        id: account.id,
        email: account.email,
        member_id: canonicalMemberId
      };
      try {
        for (const alias of batch) {
          await preflightAccountAliasMaterialization(ctx, accountIdentity, alias);
        }
      } catch (error) {
        const lastError =
          error instanceof Error ? error.message : "Unknown identity maintenance error";
        await ctx.db.patch(state._id, { last_error: lastError, updated_at: Date.now() });
        return { status: "pending" as const, phase: "accounts" as const, lastError };
      }
      for (const alias of batch) {
        await ensureAccountAliasMaterialization(ctx, accountIdentity, alias);
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
      await ctx.db.patch(account._id, {
        member_id: canonicalMemberId,
        alias_member_ids: aliases,
        updated_at: Date.now()
      });
      await ctx.db.patch(state._id, {
        cursor: nextAccountCursor,
        current_account_id: undefined,
        next_account_cursor: undefined,
        alias_offset: undefined,
        last_error: undefined,
        updated_at: Date.now()
      });
    }
    return { status: "pending" as const, phase: "accounts" as const, lastError: undefined };
  }
});
