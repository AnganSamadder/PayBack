import { mutation, query, internalMutation } from "./_generated/server";
import { v } from "convex/values";
import { getRandomAvatarColor } from "./utils";
import { resolveCanonicalMemberIdInternal } from "./aliases";
import { reconcileUserExpenses } from "./helpers";
import {
  deterministicLinkingError,
  findAccountByMemberId,
  findAliasByAliasMemberId,
  LINKING_CONTRACT_VERSION,
  LINKING_ERROR_CODES,
  normalizeMemberId,
  normalizeMemberIds
} from "./identity";

// Helper to get current authenticated user
async function getCurrentUser(ctx: any) {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) {
    throw new Error("Unauthenticated");
  }
  const user = await ctx.db
    .query("accounts")
    .withIndex("by_email", (q) => q.eq("email", identity.email!))
    .unique();

  return { identity, user };
}

type LinkClaimContext = {
  targetMemberId: string;
  creatorEmail: string;
  creatorId?: string;
};

function normalizeLinkClaimContext(input: LinkClaimContext): LinkClaimContext {
  return {
    targetMemberId: normalizeMemberId(input.targetMemberId),
    creatorEmail: input.creatorEmail.toLowerCase().trim(),
    creatorId: input.creatorId
  };
}

async function findFriendRecordByMemberId(ctx: any, accountEmail: string, memberId: string) {
  const normalizedMemberId = normalizeMemberId(memberId);
  let record = await ctx.db
    .query("account_friends")
    .withIndex("by_account_email_and_member_id", (q: any) =>
      q.eq("account_email", accountEmail).eq("member_id", normalizedMemberId)
    )
    .unique();

  if (record) return record;

  if (memberId !== normalizedMemberId) {
    record = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q: any) =>
        q.eq("account_email", accountEmail).eq("member_id", memberId)
      )
      .unique();
    if (record) return record;
  }

  const allFriends = await ctx.db
    .query("account_friends")
    .withIndex("by_account_email", (q: any) => q.eq("account_email", accountEmail))
    .collect();

  return allFriends.find(
    (friend: any) => normalizeMemberId(friend.member_id) === normalizedMemberId
  );
}

function mergeSplitsByMember(splits: any[], targetMemberId: string, canonicalMemberId: string) {
  const normalizedTarget = normalizeMemberId(targetMemberId);
  const normalizedCanonical = normalizeMemberId(canonicalMemberId);
  const merged = new Map<string, any>();

  for (const split of splits) {
    const normalizedSplitMember = normalizeMemberId(split.member_id);
    const key =
      normalizedSplitMember === normalizedTarget ? normalizedCanonical : normalizedSplitMember;
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
      // If any duplicate split is unsettled, keep unsettled for safety.
      is_settled: Boolean(existing.is_settled) && Boolean(split.is_settled)
    });
  }

  return Array.from(merged.values());
}

/**
 * Creates a new invite token for a target member.
 * The current user becomes the creator of the token.
 */
export const create = mutation({
  args: {
    id: v.string(), // Client-generated UUID for deduplication
    target_member_id: v.string(),
    target_member_name: v.string()
  },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");
    const normalizedTargetMemberId = normalizeMemberId(args.target_member_id);

    // Deduplication check
    const existing = await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    if (existing) {
      return existing._id;
    }

    // Create token with 30-day expiry
    const now = Date.now();
    const expiresAt = now + 30 * 24 * 60 * 60 * 1000; // 30 days

    const tokenId = await ctx.db.insert("invite_tokens", {
      id: args.id,
      creator_id: user.id,
      creator_email: user.email,
      target_member_id: normalizedTargetMemberId,
      target_member_name: args.target_member_name,
      created_at: now,
      expires_at: expiresAt
    });

    return tokenId;
  }
});

/**
 * Gets a single invite token by client ID.
 * Does NOT require authentication - used for validation before login.
 */
export const get = query({
  args: { id: v.string() },
  handler: async (ctx, args) => {
    const token = await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    return token;
  }
});

/**
 * Validates an invite token and returns its status.
 * Returns validation info including whether it's valid, expired, or already claimed.
 * Does NOT require authentication - used for preview before login.
 */
export const validate = query({
  args: { id: v.string() },
  handler: async (ctx, args) => {
    const token = await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    if (!token) {
      return {
        is_valid: false,
        error: "Token not found",
        token: null,
        expense_preview: null
      };
    }

    // Fetch creator's profile info
    const creatorAccount = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", token.creator_email))
      .unique();

    const now = Date.now();
    const targetMemberId = normalizeMemberId(token.target_member_id);

    if (token.expires_at < now) {
      return {
        is_valid: false,
        error: "Token has expired",
        token: {
          ...token,
          creator_name: creatorAccount?.display_name,
          creator_profile_image_url: creatorAccount?.profile_image_url
        },
        expense_preview: null
      };
    }

    if (token.claimed_by) {
      return {
        is_valid: false,
        error: "Token has already been claimed",
        token: {
          ...token,
          creator_name: creatorAccount?.display_name,
          creator_profile_image_url: creatorAccount?.profile_image_url
        },
        expense_preview: null
      };
    }

    // Generate expense preview - find all expenses involving this member
    const allExpenses = await ctx.db.query("expenses").collect();
    const memberExpenses = allExpenses.filter(
      (e) =>
        e.involved_member_ids.some((id: string) => normalizeMemberId(id) === targetMemberId) ||
        normalizeMemberId(e.paid_by_member_id) === targetMemberId
    );

    // Get group names
    const groupIds = [...new Set(memberExpenses.map((e) => e.group_id))];
    const groups = await Promise.all(
      groupIds.map(async (gid) => {
        const g = await ctx.db
          .query("groups")
          .withIndex("by_client_id", (q) => q.eq("id", gid))
          .first();
        return g;
      })
    );
    const groupNames = groups.filter((g) => g).map((g) => g!.name);

    // Calculate balance
    let totalBalance = 0;
    for (const expense of memberExpenses) {
      if (normalizeMemberId(expense.paid_by_member_id) === targetMemberId) {
        // They paid, others owe them
        const othersOwe = expense.splits
          .filter((s) => normalizeMemberId(s.member_id) !== targetMemberId)
          .reduce((sum, s) => sum + s.amount, 0);
        totalBalance += othersOwe;
      } else {
        // They owe someone
        const theirSplit = expense.splits.find(
          (s) => normalizeMemberId(s.member_id) === targetMemberId
        );
        if (theirSplit) {
          totalBalance -= theirSplit.amount;
        }
      }
    }

    return {
      is_valid: true,
      error: null,
      token: {
        ...token,
        creator_name: creatorAccount?.display_name,
        creator_profile_image_url: creatorAccount?.profile_image_url
      },
      expense_preview: {
        expense_count: memberExpenses.length,
        group_names: groupNames,
        total_balance: totalBalance
      }
    };
  }
});

/**
 * Shared logic for claiming a link target for a user.
 * This powers both inviteTokens:claim and linkRequests:accept.
 */
async function claimForUser(ctx: any, user: any, input: LinkClaimContext) {
  const linkContext = normalizeLinkClaimContext(input);
  const now = Date.now();

  if (
    linkContext.creatorEmail === user.email.toLowerCase().trim() ||
    (linkContext.creatorId && linkContext.creatorId === user.id)
  ) {
    throw deterministicLinkingError(
      LINKING_ERROR_CODES.selfClaim,
      `account_id=${user.id},target_member_id=${linkContext.targetMemberId}`
    );
  }

  const userCanonicalMemberId = user.member_id ? normalizeMemberId(user.member_id) : undefined;
  if (!userCanonicalMemberId) {
    throw new Error("User account does not have a member_id assigned");
  }

  const alreadyLinkedAccount = await findAccountByMemberId(ctx.db, linkContext.targetMemberId);
  if (alreadyLinkedAccount && alreadyLinkedAccount._id !== user._id) {
    throw deterministicLinkingError(
      LINKING_ERROR_CODES.aliasConflict,
      `target_member_id=${linkContext.targetMemberId},existing_account_id=${alreadyLinkedAccount.id}`
    );
  }

  const resolvedTarget = await resolveCanonicalMemberIdInternal(ctx.db, linkContext.targetMemberId);
  const normalizedResolvedTarget = normalizeMemberId(resolvedTarget);

  if (
    normalizedResolvedTarget !== userCanonicalMemberId &&
    normalizedResolvedTarget !== linkContext.targetMemberId
  ) {
    throw deterministicLinkingError(
      LINKING_ERROR_CODES.aliasConflict,
      `target_member_id=${linkContext.targetMemberId},resolved_canonical=${normalizedResolvedTarget},claimer_canonical=${userCanonicalMemberId}`
    );
  }

  if (linkContext.targetMemberId !== userCanonicalMemberId) {
    const existingAlias = await findAliasByAliasMemberId(ctx.db, linkContext.targetMemberId);
    if (
      existingAlias &&
      normalizeMemberId(existingAlias.canonical_member_id) !== userCanonicalMemberId
    ) {
      throw deterministicLinkingError(
        LINKING_ERROR_CODES.aliasConflict,
        `alias_member_id=${linkContext.targetMemberId},existing_canonical=${existingAlias.canonical_member_id},claimer_canonical=${userCanonicalMemberId}`
      );
    }

    if (!existingAlias) {
      await ctx.db.insert("member_aliases", {
        canonical_member_id: userCanonicalMemberId,
        alias_member_id: linkContext.targetMemberId,
        account_email: user.email.toLowerCase().trim(),
        created_at: now
      });
    }
  }

  const updatedAliases = normalizeMemberIds([
    ...(user.alias_member_ids || []),
    linkContext.targetMemberId
  ]).filter((memberId) => memberId !== userCanonicalMemberId);

  await ctx.db.patch(user._id, {
    alias_member_ids: updatedAliases,
    updated_at: now
  });

  // Get the creator's account info for creating the claimant's friend record
  const creatorAccount = await ctx.db
    .query("accounts")
    .withIndex("by_email", (q: any) => q.eq("email", linkContext.creatorEmail))
    .unique();

  // Update a friend row in an owner's account_friends table.
  const updateFriendRecord = async (accountEmail: string) => {
    const normalizedEmail = accountEmail.toLowerCase().trim();
    const friendRecord = await findFriendRecordByMemberId(
      ctx,
      normalizedEmail,
      linkContext.targetMemberId
    );

    if (!friendRecord) {
      return;
    }

    const shouldStoreOriginalName = friendRecord.name !== user.display_name;
    const nicknameMatches =
      friendRecord.nickname &&
      friendRecord.nickname.trim().toLowerCase() === user.display_name.trim().toLowerCase();

    // If both canonical and target rows exist, keep canonical and delete target duplicate.
    const canonicalRow = await findFriendRecordByMemberId(
      ctx,
      normalizedEmail,
      userCanonicalMemberId
    );
    if (canonicalRow && canonicalRow._id !== friendRecord._id) {
      await ctx.db.patch(canonicalRow._id, {
        has_linked_account: true,
        linked_account_id: user.id,
        linked_account_email: user.email,
        linked_member_id: userCanonicalMemberId,
        name: user.display_name ?? user.email ?? "Unknown",
        updated_at: now
      });
      await ctx.db.delete(friendRecord._id);
      return;
    }

    // Use the linked user's first/last name directly from their account
    const userFirstName = user.first_name;
    const userLastName = user.last_name;

    if (nicknameMatches) {
      const { nickname, ...rest } = friendRecord;
      await ctx.db.replace(friendRecord._id, {
        ...rest,
        member_id: normalizeMemberId(friendRecord.member_id),
        has_linked_account: true,
        linked_account_id: user.id,
        linked_account_email: user.email,
        linked_member_id: userCanonicalMemberId,
        name: user.display_name ?? user.email ?? "Unknown",
        first_name: userFirstName,
        last_name: userLastName,
        original_name: shouldStoreOriginalName ? friendRecord.name : undefined,
        updated_at: now
      });
    } else {
      await ctx.db.patch(friendRecord._id, {
        member_id: normalizeMemberId(friendRecord.member_id),
        has_linked_account: true,
        linked_account_id: user.id,
        linked_account_email: user.email,
        linked_member_id: userCanonicalMemberId,
        name: user.display_name ?? user.email ?? "Unknown",
        first_name: userFirstName,
        last_name: userLastName,
        nickname: friendRecord.nickname,
        original_name: shouldStoreOriginalName ? friendRecord.name : undefined,
        updated_at: now
      });
    }
  };

  // 1. Update the creator's friend record
  await updateFriendRecord(linkContext.creatorEmail);

  // 2. Create/update friend record for the claimant to see the creator
  if (creatorAccount?.member_id) {
    const creatorMemberId = normalizeMemberId(creatorAccount.member_id);
    const claimantFriendRecord = await findFriendRecordByMemberId(ctx, user.email, creatorMemberId);

    // Use the creator's first/last name directly from their account
    const creatorFirstName = creatorAccount.first_name;
    const creatorLastName = creatorAccount.last_name;

    if (claimantFriendRecord) {
      const nicknameMatches =
        claimantFriendRecord.nickname &&
        claimantFriendRecord.nickname.trim().toLowerCase() ===
          creatorAccount.display_name.trim().toLowerCase();

      if (nicknameMatches) {
        const { nickname, ...rest } = claimantFriendRecord;
        await ctx.db.replace(claimantFriendRecord._id, {
          ...rest,
          member_id: normalizeMemberId(claimantFriendRecord.member_id),
          has_linked_account: true,
          linked_account_id: creatorAccount.id,
          linked_account_email: creatorAccount.email,
          linked_member_id: creatorMemberId,
          name: creatorAccount.display_name ?? creatorAccount.email ?? "Unknown",
          first_name: creatorFirstName,
          last_name: creatorLastName,
          updated_at: now
        });
      } else {
        await ctx.db.patch(claimantFriendRecord._id, {
          member_id: normalizeMemberId(claimantFriendRecord.member_id),
          has_linked_account: true,
          linked_account_id: creatorAccount.id,
          linked_account_email: creatorAccount.email,
          linked_member_id: creatorMemberId,
          name: creatorAccount.display_name ?? creatorAccount.email ?? "Unknown",
          first_name: creatorFirstName,
          last_name: creatorLastName,
          nickname: claimantFriendRecord.nickname,
          updated_at: now
        });
      }
    } else {
      await ctx.db.insert("account_friends", {
        account_email: user.email,
        member_id: creatorMemberId,
        name: creatorAccount.display_name ?? creatorAccount.email ?? "Unknown",
        first_name: creatorFirstName,
        last_name: creatorLastName,
        has_linked_account: true,
        linked_account_id: creatorAccount.id,
        linked_account_email: creatorAccount.email,
        linked_member_id: creatorMemberId,
        profile_image_url: creatorAccount.profile_image_url,
        profile_avatar_color: creatorAccount.profile_avatar_color ?? getRandomAvatarColor(),
        updated_at: now
      });
    }
  }

  // 3. Find all groups containing this identity (target or canonical)
  const allGroups = await ctx.db.query("groups").collect();
  const memberGroups = allGroups.filter((group: any) =>
    group.members.some((member: any) => {
      const memberId = normalizeMemberId(member.id);
      return memberId === linkContext.targetMemberId || memberId === userCanonicalMemberId;
    })
  );

  // 4. Collect all unique account emails that share a group with the linked member
  const sharedAccountEmails = new Set<string>();
  for (const group of memberGroups) {
    if (group.owner_email && group.owner_email.toLowerCase() !== linkContext.creatorEmail) {
      sharedAccountEmails.add(group.owner_email.toLowerCase());
    }

    for (const member of group.members) {
      const normalizedMemberId = normalizeMemberId(member.id);
      if (
        normalizedMemberId === linkContext.targetMemberId ||
        normalizedMemberId === userCanonicalMemberId
      ) {
        continue;
      }

      const linkedAccount = await findAccountByMemberId(ctx.db, normalizedMemberId);
      if (linkedAccount?.email && linkedAccount.email.toLowerCase() !== linkContext.creatorEmail) {
        sharedAccountEmails.add(linkedAccount.email.toLowerCase());
      }
    }
  }

  // 5. Update friend records for all shared users
  for (const accountEmail of sharedAccountEmails) {
    await updateFriendRecord(accountEmail);
  }

  // 6. Canonicalize group members to the claimer's canonical member ID
  for (const group of memberGroups) {
    let changed = false;
    const dedupedMembers = new Map<string, any>();

    for (const member of group.members) {
      const normalizedMemberId = normalizeMemberId(member.id);
      const canonicalizedMemberId =
        normalizedMemberId === linkContext.targetMemberId
          ? userCanonicalMemberId
          : normalizedMemberId;

      const nextMember = {
        ...member,
        id: canonicalizedMemberId,
        name:
          canonicalizedMemberId === userCanonicalMemberId
            ? (user.display_name ?? user.email ?? member.name)
            : member.name
      };

      const existing = dedupedMembers.get(canonicalizedMemberId);
      if (!existing) {
        dedupedMembers.set(canonicalizedMemberId, nextMember);
      } else if (!existing.is_current_user && nextMember.is_current_user) {
        dedupedMembers.set(canonicalizedMemberId, nextMember);
      }

      if (member.id !== nextMember.id || member.name !== nextMember.name) {
        changed = true;
      }
    }

    const updatedMembers = Array.from(dedupedMembers.values());
    if (changed || updatedMembers.length !== group.members.length) {
      await ctx.db.patch(group._id, {
        members: updatedMembers,
        updated_at: now
      });
    }
  }

  // 7. Canonicalize expenses and participant visibility for all impacted groups
  const memberGroupIds = memberGroups.map((group: any) => group.id);
  for (const groupId of memberGroupIds) {
    const groupExpenses = await ctx.db
      .query("expenses")
      .withIndex("by_group_id", (q: any) => q.eq("group_id", groupId))
      .collect();

    for (const expense of groupExpenses) {
      const hasTargetIdentity =
        normalizeMemberId(expense.paid_by_member_id) === linkContext.targetMemberId ||
        expense.involved_member_ids.some(
          (memberId: string) => normalizeMemberId(memberId) === linkContext.targetMemberId
        ) ||
        expense.splits.some(
          (split: any) => normalizeMemberId(split.member_id) === linkContext.targetMemberId
        ) ||
        expense.participant_member_ids.some(
          (memberId: string) => normalizeMemberId(memberId) === linkContext.targetMemberId
        );

      if (!hasTargetIdentity) continue;

      const paidByMemberId =
        normalizeMemberId(expense.paid_by_member_id) === linkContext.targetMemberId
          ? userCanonicalMemberId
          : normalizeMemberId(expense.paid_by_member_id);

      const involvedMemberIds = normalizeMemberIds(
        expense.involved_member_ids.map((memberId: string) =>
          normalizeMemberId(memberId) === linkContext.targetMemberId
            ? userCanonicalMemberId
            : normalizeMemberId(memberId)
        )
      );

      const participantMemberIds = normalizeMemberIds(
        expense.participant_member_ids.map((memberId: string) =>
          normalizeMemberId(memberId) === linkContext.targetMemberId
            ? userCanonicalMemberId
            : normalizeMemberId(memberId)
        )
      );

      const mergedSplits = mergeSplitsByMember(
        expense.splits,
        linkContext.targetMemberId,
        userCanonicalMemberId
      );

      const participantsByMember = new Map<string, any>();
      for (const participant of expense.participants) {
        const normalizedMemberId = normalizeMemberId(participant.member_id);
        const canonicalizedMemberId =
          normalizedMemberId === linkContext.targetMemberId
            ? userCanonicalMemberId
            : normalizedMemberId;

        const existing = participantsByMember.get(canonicalizedMemberId);
        const nextParticipant = {
          ...participant,
          member_id: canonicalizedMemberId,
          name:
            canonicalizedMemberId === userCanonicalMemberId
              ? (user.display_name ?? user.email ?? participant.name)
              : participant.name,
          linked_account_id:
            canonicalizedMemberId === userCanonicalMemberId
              ? user.id
              : participant.linked_account_id,
          linked_account_email:
            canonicalizedMemberId === userCanonicalMemberId
              ? user.email
              : participant.linked_account_email
        };

        if (!existing) {
          participantsByMember.set(canonicalizedMemberId, nextParticipant);
        } else {
          participantsByMember.set(canonicalizedMemberId, {
            ...existing,
            name: nextParticipant.name || existing.name,
            linked_account_id: nextParticipant.linked_account_id || existing.linked_account_id,
            linked_account_email:
              nextParticipant.linked_account_email || existing.linked_account_email
          });
        }
      }

      const participantEmails = Array.from(
        new Set(
          [...(expense.participant_emails || []), user.email]
            .map((email: string) => email.toLowerCase().trim())
            .filter(Boolean)
        )
      );

      await ctx.db.patch(expense._id, {
        paid_by_member_id: paidByMemberId,
        involved_member_ids: involvedMemberIds,
        participant_member_ids: participantMemberIds,
        splits: mergedSplits,
        participants: Array.from(participantsByMember.values()),
        participant_emails: participantEmails,
        updated_at: now
      });

      const participantUsers = await Promise.all(
        participantEmails.map((email: string) =>
          ctx.db
            .query("accounts")
            .withIndex("by_email", (q: any) => q.eq("email", email))
            .unique()
        )
      );
      const participantUserIds = participantUsers
        .filter((u: any) => u !== null)
        .map((u: any) => u.id);
      await reconcileUserExpenses(ctx, expense.id, participantUserIds);
    }
  }

  return {
    contract_version: LINKING_CONTRACT_VERSION,
    target_member_id: linkContext.targetMemberId,
    canonical_member_id: userCanonicalMemberId,
    alias_member_ids: updatedAliases,
    linked_member_id: userCanonicalMemberId,
    linked_account_id: user.id,
    linked_account_email: user.email
  };
}

/**
 * Claims an invite token for the current user.
 * This links the current user's account to the target member.
 * Also performs transitive linking - if other users share a group with the target member,
 * their friend records are also updated.
 */
export const claim = mutation({
  args: { id: v.string() },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");

    const token = await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    if (!token) {
      throw new Error("Token not found");
    }

    const now = Date.now();
    if (token.expires_at < now) {
      throw new Error("Token has expired");
    }

    if (token.claimed_by) {
      throw new Error("Token has already been claimed");
    }

    await ctx.db.patch(token._id, {
      claimed_by: user.id,
      claimed_at: now
    });

    return await claimForUser(ctx, user, {
      targetMemberId: token.target_member_id,
      creatorEmail: token.creator_email,
      creatorId: token.creator_id
    });
  }
});

/**
 * Lists all active (unclaimed, unexpired) invite tokens created by the current user.
 */
export const listByCreator = query({
  args: {},
  handler: async (ctx) => {
    const { user } = await getCurrentUser(ctx);
    if (!user) return [];

    const now = Date.now();

    const tokens = await ctx.db
      .query("invite_tokens")
      .withIndex("by_creator_id", (q) => q.eq("creator_id", user.id))
      .collect();

    // Filter to active tokens only
    return tokens.filter((t) => !t.claimed_by && t.expires_at > now);
  }
});

/**
 * Revokes an invite token, preventing it from being claimed.
 */
export const revoke = mutation({
  args: { id: v.string() },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");

    const token = await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    if (!token) {
      throw new Error("Token not found");
    }

    // Only creator can revoke
    if (token.creator_id !== user.id) {
      throw new Error("Not authorized to revoke this token");
    }

    // Delete the token
    await ctx.db.delete(token._id);
  }
});

export const _internalClaimForAccount = internalMutation({
  args: {
    userAccountId: v.id("accounts"),
    tokenId: v.string()
  },
  handler: async (ctx, args) => {
    const user = await ctx.db.get(args.userAccountId);
    if (!user) throw new Error("User not found");

    const token = await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", args.tokenId))
      .unique();

    if (!token) throw new Error("Token not found");

    const now = Date.now();
    if (token.expires_at < now) {
      throw new Error("Token has expired");
    }

    if (token.claimed_by) {
      throw new Error("Token has already been claimed");
    }

    await ctx.db.patch(token._id, {
      claimed_by: user.id,
      claimed_at: now
    });

    return await claimForUser(ctx, user, {
      targetMemberId: token.target_member_id,
      creatorEmail: token.creator_email,
      creatorId: token.creator_id
    });
  }
});

export const _internalClaimTargetMemberForAccount = internalMutation({
  args: {
    userAccountId: v.id("accounts"),
    targetMemberId: v.string(),
    creatorEmail: v.string(),
    creatorId: v.optional(v.string())
  },
  handler: async (ctx, args) => {
    const user = await ctx.db.get(args.userAccountId);
    if (!user) throw new Error("User not found");

    return await claimForUser(ctx, user, {
      targetMemberId: args.targetMemberId,
      creatorEmail: args.creatorEmail,
      creatorId: args.creatorId
    });
  }
});
