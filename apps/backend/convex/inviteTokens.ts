import { Doc, Id } from "./_generated/dataModel";
import { mutation, query, internalMutation, MutationCtx, QueryCtx } from "./_generated/server";
import { v } from "convex/values";
import { getRandomAvatarColor } from "./utils";
import { resolveCanonicalMemberIdInternal, rewriteClaimedFriendReferences } from "./aliases";
import {
  assertIdentityMaterializationReady,
  deterministicLinkingError,
  ensureAccountAliasMaterialization,
  findAccountByMemberId,
  findAliasByAliasMemberId,
  LINKING_CONTRACT_VERSION,
  LINKING_ERROR_CODES,
  MAX_LIVE_ACCOUNT_ALIASES,
  normalizeMemberId,
  normalizeMemberIds
} from "./identity";
import { isGhostFriendIdentity } from "./friendLinkProvenance";

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
  targetFriendId: Id<"account_friends">;
  creatorEmail: string;
  creatorId?: string;
};

function normalizeLinkClaimContext(input: LinkClaimContext): LinkClaimContext {
  return {
    targetMemberId: normalizeMemberId(input.targetMemberId),
    targetFriendId: input.targetFriendId,
    creatorEmail: input.creatorEmail.toLowerCase().trim(),
    creatorId: input.creatorId
  };
}

const MAX_INVITE_TARGET_FRIENDS = 256;

function isUnlinkedInviteTarget(friend: Doc<"account_friends">): boolean {
  return (
    friend.has_linked_account === false &&
    !isGhostFriendIdentity(friend) &&
    !friend.linked_account_id &&
    !friend.linked_account_email &&
    !friend.linked_member_id
  );
}

async function findOwnedInviteTarget(
  ctx: Pick<MutationCtx, "db">,
  creatorEmail: string,
  targetMemberId: string
): Promise<Doc<"account_friends"> | null> {
  const normalizedEmail = creatorEmail.trim().toLowerCase();
  const normalizedTarget = normalizeMemberId(targetMemberId);
  for (const candidateId of new Set([normalizedTarget, targetMemberId.trim()])) {
    const exact = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", normalizedEmail).eq("member_id", candidateId)
      )
      .take(2);
    if (exact.length > 1) {
      throw new Error("Identity maintenance required: duplicate invite target identities");
    }
    if (exact[0]) return exact[0];
  }

  const friends = await ctx.db
    .query("account_friends")
    .withIndex("by_account_email", (q) => q.eq("account_email", normalizedEmail))
    .take(MAX_INVITE_TARGET_FRIENDS + 1);
  if (friends.length > MAX_INVITE_TARGET_FRIENDS) {
    throw new Error("Identity maintenance required: too many friends to resolve invite target");
  }
  const normalizedMatches = friends.filter(
    (friend) => normalizeMemberId(friend.member_id) === normalizedTarget
  );
  if (normalizedMatches.length > 1) {
    throw new Error("Identity maintenance required: duplicate invite target identities");
  }
  return normalizedMatches[0] ?? null;
}

async function validateBoundInviteTarget(
  ctx: Pick<MutationCtx, "db">,
  creator: Doc<"accounts">,
  linkContext: LinkClaimContext
): Promise<Doc<"account_friends">> {
  const targetFriend = await readBoundInviteTarget(ctx, creator, linkContext);
  if (!targetFriend) {
    throw new Error("Invite target is no longer an unlinked friend owned by the creator");
  }
  return targetFriend;
}

async function readBoundInviteTarget(
  ctx: Pick<QueryCtx, "db">,
  creator: Doc<"accounts">,
  linkContext: LinkClaimContext
): Promise<Doc<"account_friends"> | null> {
  const targetFriend = await ctx.db.get(linkContext.targetFriendId);
  if (
    !targetFriend ||
    targetFriend.account_email.trim().toLowerCase() !== creator.email.trim().toLowerCase() ||
    normalizeMemberId(targetFriend.member_id) !== linkContext.targetMemberId ||
    !isUnlinkedInviteTarget(targetFriend)
  ) {
    return null;
  }
  return targetFriend;
}

async function findFriendRecordByMemberId(ctx: any, accountEmail: string, memberId: string) {
  const normalizedEmail = accountEmail.trim().toLowerCase();
  const normalizedMemberId = normalizeMemberId(memberId);
  for (const candidateId of new Set([normalizedMemberId, memberId.trim()])) {
    const exact = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q: any) =>
        q.eq("account_email", normalizedEmail).eq("member_id", candidateId)
      )
      .take(2);
    if (exact.length > 1) {
      throw new Error("Identity maintenance required: duplicate friend identities");
    }
    if (exact[0]) return exact[0];
  }

  const ownerFriends = await ctx.db
    .query("account_friends")
    .withIndex("by_account_email", (q: any) => q.eq("account_email", normalizedEmail))
    .take(MAX_INVITE_TARGET_FRIENDS + 1);
  if (ownerFriends.length > MAX_INVITE_TARGET_FRIENDS) {
    throw new Error("Identity maintenance required: too many friend identities");
  }

  const normalizedMatches = ownerFriends.filter(
    (friend: any) => normalizeMemberId(friend.member_id) === normalizedMemberId
  );
  if (normalizedMatches.length > 1) {
    throw new Error("Identity maintenance required: duplicate friend identities");
  }
  return normalizedMatches[0] ?? null;
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
    if (!user || user.status === "deleted") throw new Error("User not found");
    const normalizedTargetMemberId = normalizeMemberId(args.target_member_id);

    const targetFriend = await findOwnedInviteTarget(ctx, user.email, normalizedTargetMemberId);
    if (!targetFriend || !isUnlinkedInviteTarget(targetFriend)) {
      throw new Error("Target member must be an unlinked friend owned by the creator");
    }

    // Deduplication check
    const existing = await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    if (existing) {
      const isExactReplay =
        existing.creator_id === user.id &&
        normalizeMemberId(existing.target_member_id) === normalizedTargetMemberId &&
        existing.target_friend_id === targetFriend._id;
      if (!isExactReplay) {
        throw new Error("Invite id is already used for a different target");
      }
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
      target_friend_id: targetFriend._id,
      target_member_name: args.target_member_name,
      created_at: now,
      expires_at: expiresAt
    });

    return tokenId;
  }
});

const MAX_PUBLIC_INVITE_PREVIEW_EXPENSES = 128;

const publicInviteTokenValidator = v.object({
  id: v.string(),
  creator_email: v.string(),
  creator_name: v.optional(v.string()),
  creator_profile_image_url: v.optional(v.string()),
  target_member_id: v.string(),
  target_member_name: v.string(),
  created_at: v.number(),
  expires_at: v.number(),
  claimed_at: v.optional(v.number())
});

const publicExpensePreviewValidator = v.object({
  expense_count: v.number(),
  group_names: v.array(v.string()),
  total_balance: v.number()
});

const publicInviteValidationValidator = v.object({
  is_valid: v.boolean(),
  error: v.union(v.string(), v.null()),
  token: v.union(publicInviteTokenValidator, v.null()),
  expense_preview: v.union(publicExpensePreviewValidator, v.null())
});

function publicInviteToken(token: Doc<"invite_tokens">, creator?: Doc<"accounts"> | null) {
  return {
    id: token.id,
    creator_email: token.creator_email,
    creator_name: creator?.display_name,
    creator_profile_image_url: creator?.profile_image_url,
    target_member_id: token.target_member_id,
    target_member_name: token.target_member_name,
    created_at: token.created_at,
    expires_at: token.expires_at,
    claimed_at: token.claimed_at
  };
}

/**
 * Validates an invite token and returns its status.
 * Returns validation info including whether it's valid, expired, or already claimed.
 * Does NOT require authentication - used for preview before login.
 */
export const validate = query({
  args: { id: v.string() },
  returns: publicInviteValidationValidator,
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
      .withIndex("by_auth_id", (q) => q.eq("id", token.creator_id))
      .unique();

    if (
      !creatorAccount ||
      creatorAccount.status === "deleted" ||
      creatorAccount.email.trim().toLowerCase() !== token.creator_email.trim().toLowerCase()
    ) {
      return {
        is_valid: false,
        error: "Invite creator account is unavailable",
        token: null,
        expense_preview: null
      };
    }

    const publicToken = publicInviteToken(token, creatorAccount);
    const now = Date.now();
    if (token.expires_at < now) {
      return {
        is_valid: false,
        error: "Token has expired",
        token: {
          ...publicToken
        },
        expense_preview: null
      };
    }

    if (token.claimed_by) {
      return {
        is_valid: false,
        error: "Token has already been claimed",
        token: {
          ...publicToken
        },
        expense_preview: null
      };
    }

    if (!token.target_friend_id) {
      return {
        is_valid: false,
        error: "Invite target is unavailable",
        token: null,
        expense_preview: null
      };
    }

    const linkContext = normalizeLinkClaimContext({
      targetMemberId: token.target_member_id,
      targetFriendId: token.target_friend_id,
      creatorEmail: token.creator_email,
      creatorId: token.creator_id
    });
    const targetFriend = await readBoundInviteTarget(ctx, creatorAccount, linkContext);
    if (!targetFriend) {
      return {
        is_valid: false,
        error: "Invite target is unavailable",
        token: null,
        expense_preview: null
      };
    }

    const creatorExpenses = await ctx.db
      .query("expenses")
      .withIndex("by_owner_id", (q) => q.eq("owner_id", creatorAccount._id))
      .take(MAX_PUBLIC_INVITE_PREVIEW_EXPENSES + 1);
    let expensePreview: {
      expense_count: number;
      group_names: string[];
      total_balance: number;
    } | null = null;
    if (creatorExpenses.length <= MAX_PUBLIC_INVITE_PREVIEW_EXPENSES) {
      const targetMemberId = normalizeMemberId(token.target_member_id);
      const memberExpenses = creatorExpenses.filter(
        (expense) =>
          expense.involved_member_ids.some(
            (memberId) => normalizeMemberId(memberId) === targetMemberId
          ) || normalizeMemberId(expense.paid_by_member_id) === targetMemberId
      );
      const groupNames = new Set<string>();
      let totalBalance = 0;
      for (const expense of memberExpenses) {
        if (expense.group_ref) {
          const group = await ctx.db.get(expense.group_ref);
          if (group && group.owner_id === creatorAccount._id && group.id === expense.group_id) {
            groupNames.add(group.name);
          }
        }
        if (normalizeMemberId(expense.paid_by_member_id) === targetMemberId) {
          totalBalance += expense.splits
            .filter((split) => normalizeMemberId(split.member_id) !== targetMemberId)
            .reduce((sum, split) => sum + split.amount, 0);
        } else {
          const targetSplit = expense.splits.find(
            (split) => normalizeMemberId(split.member_id) === targetMemberId
          );
          totalBalance -= targetSplit?.amount ?? 0;
        }
      }
      expensePreview = {
        expense_count: memberExpenses.length,
        group_names: Array.from(groupNames),
        total_balance: totalBalance
      };
    }

    return {
      is_valid: true,
      error: null,
      token: {
        ...publicToken
      },
      expense_preview: expensePreview
    };
  }
});

/**
 * Shared logic for claiming a link target for a user.
 * This powers both inviteTokens:claim and linkRequests:accept.
 */
async function claimForUser(ctx: any, user: any, input: LinkClaimContext) {
  await assertIdentityMaterializationReady(ctx.db);
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

  const creatorAccount = linkContext.creatorId
    ? await ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q: any) => q.eq("id", linkContext.creatorId!))
        .unique()
    : await ctx.db
        .query("accounts")
        .withIndex("by_email", (q: any) => q.eq("email", linkContext.creatorEmail))
        .unique();
  if (
    !creatorAccount ||
    creatorAccount.status === "deleted" ||
    creatorAccount.email.trim().toLowerCase() !== linkContext.creatorEmail
  ) {
    throw new Error("Invite creator account is no longer active");
  }
  await validateBoundInviteTarget(ctx, creatorAccount, linkContext);

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
  }

  const updatedAliases = normalizeMemberIds([
    ...(user.alias_member_ids || []),
    linkContext.targetMemberId
  ]).filter((memberId) => memberId !== userCanonicalMemberId);

  if (updatedAliases.length > MAX_LIVE_ACCOUNT_ALIASES) {
    throw new Error(
      `Identity maintenance required: account ${user.id} has too many aliases for a live claim`
    );
  }
  await rewriteClaimedFriendReferences(ctx, creatorAccount, linkContext.targetMemberId, user);

  await ensureAccountAliasMaterialization(
    ctx,
    { id: user.id, email: user.email, member_id: userCanonicalMemberId },
    linkContext.targetMemberId,
    now
  );
  await ctx.db.patch(user._id, {
    alias_member_ids: updatedAliases,
    updated_at: now
  });

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
        link_state: "linked",
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
        link_state: "linked",
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
        link_state: "linked",
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
          link_state: "linked",
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
          link_state: "linked",
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
        link_state: "linked",
        linked_account_id: creatorAccount.id,
        linked_account_email: creatorAccount.email,
        linked_member_id: creatorMemberId,
        profile_image_url: creatorAccount.profile_image_url,
        profile_avatar_color: creatorAccount.profile_avatar_color ?? getRandomAvatarColor(),
        updated_at: now
      });
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

    if (!token.target_friend_id) {
      throw new Error("Invite must be recreated before it can be claimed");
    }

    await ctx.db.patch(token._id, {
      claimed_by: user.id,
      claimed_at: now
    });

    return await claimForUser(ctx, user, {
      targetMemberId: token.target_member_id,
      targetFriendId: token.target_friend_id,
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

    if (!token.target_friend_id) {
      throw new Error("Invite must be recreated before it can be claimed");
    }

    await assertIdentityMaterializationReady(ctx.db);
    await ctx.db.patch(token._id, {
      claimed_by: user.id,
      claimed_at: now
    });

    return await claimForUser(ctx, user, {
      targetMemberId: token.target_member_id,
      targetFriendId: token.target_friend_id,
      creatorEmail: token.creator_email,
      creatorId: token.creator_id
    });
  }
});

export const _internalClaimTargetMemberForAccount = internalMutation({
  args: {
    userAccountId: v.id("accounts"),
    targetMemberId: v.string(),
    targetFriendId: v.id("account_friends"),
    creatorEmail: v.string(),
    creatorId: v.optional(v.string())
  },
  handler: async (ctx, args) => {
    const user = await ctx.db.get(args.userAccountId);
    if (!user) throw new Error("User not found");

    return await claimForUser(ctx, user, {
      targetMemberId: args.targetMemberId,
      targetFriendId: args.targetFriendId,
      creatorEmail: args.creatorEmail,
      creatorId: args.creatorId
    });
  }
});
