import { Doc, Id } from "./_generated/dataModel";
import { mutation, query, internalMutation, MutationCtx, QueryCtx } from "./_generated/server";
import type { WithoutSystemFields } from "convex/server";
import { v } from "convex/values";
import { getRandomAvatarColor } from "./utils";
import {
  accountLinkingRows,
  applyCanonicalReferenceRewrite,
  chargeLinkingQueries,
  collectSequentialLinkingRows,
  createLinkingReadBudget,
  prepareClaimedFriendReferenceRewrite,
  type CanonicalReferenceRewritePlan,
  type LinkingReadBudget
} from "./aliases";
import {
  deterministicLinkingError,
  IDENTITY_MATERIALIZATION_KEY,
  LINKING_CONTRACT_VERSION,
  LINKING_ERROR_CODES,
  MAX_ALIAS_ROWS_PER_MEMBER_ID,
  MAX_LIVE_ACCOUNT_ALIASES,
  normalizeMemberId,
  normalizeMemberIds
} from "./identity";
import { isGhostFriendIdentity } from "./friendLinkProvenance";
import { assertAccountCanAcceptChanges, isAccountDeletionFenced } from "./helpers";

// Helper to get current authenticated user
async function getCurrentUser(ctx: any, budget?: LinkingReadBudget) {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) {
    throw new Error("Unauthenticated");
  }
  if (budget) chargeLinkingQueries(budget, 1);
  const user = await ctx.db
    .query("accounts")
    .withIndex("by_email", (q) => q.eq("email", identity.email!))
    .unique();
  if (budget) accountLinkingRows(budget, user ? [user] : []);
  assertAccountCanAcceptChanges(user);

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
  linkContext: LinkClaimContext,
  budget?: LinkingReadBudget
): Promise<Doc<"account_friends">> {
  const targetFriend = await readBoundInviteTarget(ctx, creator, linkContext, budget);
  if (!targetFriend) {
    throw new Error("Invite target is no longer an unlinked friend owned by the creator");
  }
  return targetFriend;
}

async function readBoundInviteTarget(
  ctx: Pick<QueryCtx, "db">,
  creator: Doc<"accounts">,
  linkContext: LinkClaimContext,
  budget?: LinkingReadBudget
): Promise<Doc<"account_friends"> | null> {
  if (budget) chargeLinkingQueries(budget, 1);
  const targetFriend = await ctx.db.get(linkContext.targetFriendId);
  if (budget) accountLinkingRows(budget, targetFriend ? [targetFriend] : [], true);
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

async function findFriendRecordByMemberId(
  ctx: MutationCtx,
  accountEmail: string,
  memberId: string,
  budget: LinkingReadBudget
) {
  const normalizedEmail = accountEmail.trim().toLowerCase();
  const normalizedMemberId = normalizeMemberId(memberId);
  for (const candidateId of new Set([normalizedMemberId, memberId.trim()])) {
    chargeLinkingQueries(budget, 1);
    const exact = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q: any) =>
        q.eq("account_email", normalizedEmail).eq("member_id", candidateId)
      )
      .take(2);
    accountLinkingRows(budget, exact, true);
    if (exact.length > 1) {
      throw new Error("Identity maintenance required: duplicate friend identities");
    }
    if (exact[0]) return exact[0];
  }

  const ownerFriends = await collectSequentialLinkingRows(
    budget,
    async (cursor, limit) =>
      ctx.db
        .query("account_friends")
        .withIndex("by_account_email", (q) => q.eq("account_email", normalizedEmail))
        .order("asc")
        .paginate({ cursor, numItems: Math.min(limit, MAX_INVITE_TARGET_FRIENDS + 1) }),
    true
  );
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

export async function assertBudgetedIdentityMaterializationReady(
  ctx: MutationCtx,
  budget: LinkingReadBudget
) {
  chargeLinkingQueries(budget, 1);
  const state = await ctx.db
    .query("identity_materialization_state")
    .withIndex("by_key", (q) => q.eq("key", IDENTITY_MATERIALIZATION_KEY))
    .unique();
  accountLinkingRows(budget, state ? [state] : []);
  if (state?.status !== "ready") {
    throw new Error(
      "Identity maintenance required: indexed identity migration is not complete; try again later"
    );
  }
}

async function findBudgetedMaterializedAlias(
  ctx: MutationCtx,
  memberId: string,
  budget: LinkingReadBudget
) {
  const normalized = normalizeMemberId(memberId);
  chargeLinkingQueries(budget, 1);
  const alias = await ctx.db
    .query("member_aliases")
    .withIndex("by_alias_member_id_and_source", (q) =>
      q.eq("alias_member_id", normalized).eq("materialization_source", "account_alias")
    )
    .first();
  accountLinkingRows(budget, alias ? [alias] : []);
  return alias;
}

async function findBudgetedAccountByMemberId(
  ctx: MutationCtx,
  memberId: string,
  budget: LinkingReadBudget
): Promise<Doc<"accounts"> | null> {
  let currentMemberId = normalizeMemberId(memberId);
  const visited = new Set<string>();
  for (let depth = 0; depth < 20; depth += 1) {
    if (!currentMemberId || visited.has(currentMemberId)) return null;
    visited.add(currentMemberId);

    chargeLinkingQueries(budget, 1);
    const account = await ctx.db
      .query("accounts")
      .withIndex("by_member_id", (q) => q.eq("member_id", currentMemberId))
      .first();
    accountLinkingRows(budget, account ? [account] : []);
    if (account) return account;

    const alias = await findBudgetedMaterializedAlias(ctx, currentMemberId, budget);
    if (!alias) return null;
    currentMemberId = normalizeMemberId(alias.canonical_member_id);
  }
  return null;
}

async function resolveBudgetedCanonicalMemberId(
  ctx: MutationCtx,
  memberId: string,
  budget: LinkingReadBudget
) {
  let currentMemberId = normalizeMemberId(memberId);
  const visited = new Set<string>();
  for (let depth = 0; depth < 20; depth += 1) {
    if (!currentMemberId || visited.has(currentMemberId)) return currentMemberId;
    visited.add(currentMemberId);

    chargeLinkingQueries(budget, 1);
    const account = await ctx.db
      .query("accounts")
      .withIndex("by_member_id", (q) => q.eq("member_id", currentMemberId))
      .first();
    accountLinkingRows(budget, account ? [account] : []);
    if (account?.member_id) return normalizeMemberId(account.member_id);

    const alias = await findBudgetedMaterializedAlias(ctx, currentMemberId, budget);
    if (!alias) return currentMemberId;
    currentMemberId = normalizeMemberId(alias.canonical_member_id);
  }
  return currentMemberId;
}

type AliasInsertPlan = {
  canonical_member_id: string;
  alias_member_id: string;
  account_email: string;
  materialization_source: "account_alias";
  source_account_id: string;
  created_at: number;
};

async function prepareBudgetedAliasInsert(
  ctx: MutationCtx,
  account: Pick<Doc<"accounts">, "id" | "email" | "member_id">,
  aliasMemberId: string,
  now: number,
  budget: LinkingReadBudget
): Promise<AliasInsertPlan | null> {
  const canonicalMemberId = account.member_id ? normalizeMemberId(account.member_id) : undefined;
  const normalizedAlias = normalizeMemberId(aliasMemberId);
  if (!canonicalMemberId) {
    throw new Error("Cannot materialize aliases without a canonical member_id");
  }
  if (!normalizedAlias || normalizedAlias === canonicalMemberId) return null;

  chargeLinkingQueries(budget, 1);
  const canonicalShadows = await ctx.db
    .query("accounts")
    .withIndex("by_member_id", (q) => q.eq("member_id", normalizedAlias))
    .take(2);
  accountLinkingRows(budget, canonicalShadows);
  if (canonicalShadows[0]) {
    throw deterministicLinkingError(
      LINKING_ERROR_CODES.aliasConflict,
      `alias_member_id=${normalizedAlias},canonical_account_id=${canonicalShadows[0].id}`
    );
  }

  chargeLinkingQueries(budget, 1);
  const aliasRows = await ctx.db
    .query("member_aliases")
    .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", normalizedAlias))
    .take(MAX_ALIAS_ROWS_PER_MEMBER_ID + 1);
  accountLinkingRows(budget, aliasRows);
  if (aliasRows.length > MAX_ALIAS_ROWS_PER_MEMBER_ID) {
    throw new Error(`Identity maintenance required: too many mappings for ${normalizedAlias}`);
  }
  const conflictingRow = aliasRows.find(
    (row) => normalizeMemberId(row.canonical_member_id) !== canonicalMemberId
  );
  if (conflictingRow) {
    throw deterministicLinkingError(
      LINKING_ERROR_CODES.aliasConflict,
      `alias_member_id=${normalizedAlias},existing_canonical=${conflictingRow.canonical_member_id}`
    );
  }

  chargeLinkingQueries(budget, 1);
  const sourceRows = await ctx.db
    .query("member_aliases")
    .withIndex("by_source_account_and_alias", (q) =>
      q.eq("source_account_id", account.id).eq("alias_member_id", normalizedAlias)
    )
    .take(2);
  accountLinkingRows(budget, sourceRows);
  if (sourceRows.length > 1) {
    throw new Error(
      `Identity maintenance required: duplicate account materializations for ${normalizedAlias}`
    );
  }
  if (sourceRows.length === 1) return null;

  return {
    canonical_member_id: canonicalMemberId,
    alias_member_id: normalizedAlias,
    account_email: account.email.toLowerCase().trim(),
    materialization_source: "account_alias",
    source_account_id: account.id,
    created_at: now
  };
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
      isAccountDeletionFenced(creatorAccount) ||
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
type StoredAccountFriend = WithoutSystemFields<Doc<"account_friends">>;

type AccountFriendWrite =
  | { kind: "patch"; id: Id<"account_friends">; value: Partial<StoredAccountFriend> }
  | { kind: "replace"; id: Id<"account_friends">; value: StoredAccountFriend }
  | { kind: "delete"; id: Id<"account_friends"> }
  | { kind: "insert"; value: StoredAccountFriend };

function storedAccountFriend(friend: Doc<"account_friends">): StoredAccountFriend {
  const fields: Partial<Doc<"account_friends">> = { ...friend };
  delete fields._id;
  delete fields._creationTime;
  return fields as StoredAccountFriend;
}

export type LinkClaimPlan = {
  referenceRewrite: CanonicalReferenceRewritePlan;
  aliasInsert: AliasInsertPlan | null;
  claimantAccountId: Id<"accounts">;
  claimantAliases: string[];
  updatedAt: number;
  friendWrites: AccountFriendWrite[];
  result: {
    contract_version: number;
    target_member_id: string;
    canonical_member_id: string;
    alias_member_ids: string[];
    linked_member_id: string;
    linked_account_id: string;
    linked_account_email: string;
  };
};

export async function prepareClaimForUser(
  ctx: MutationCtx,
  user: Doc<"accounts">,
  input: LinkClaimContext,
  budget: LinkingReadBudget
): Promise<LinkClaimPlan> {
  await assertBudgetedIdentityMaterializationReady(ctx, budget);
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

  chargeLinkingQueries(budget, 1);
  const creatorAccount = linkContext.creatorId
    ? await ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q) => q.eq("id", linkContext.creatorId!))
        .unique()
    : await ctx.db
        .query("accounts")
        .withIndex("by_email", (q) => q.eq("email", linkContext.creatorEmail))
        .unique();
  accountLinkingRows(budget, creatorAccount ? [creatorAccount] : []);
  if (
    !creatorAccount ||
    isAccountDeletionFenced(creatorAccount) ||
    creatorAccount.email.trim().toLowerCase() !== linkContext.creatorEmail
  ) {
    throw new Error("Invite creator account is no longer active");
  }
  const targetFriend = await validateBoundInviteTarget(ctx, creatorAccount, linkContext, budget);

  const userCanonicalMemberId = user.member_id ? normalizeMemberId(user.member_id) : undefined;
  if (!userCanonicalMemberId) {
    throw new Error("User account does not have a member_id assigned");
  }

  const alreadyLinkedAccount = await findBudgetedAccountByMemberId(
    ctx,
    linkContext.targetMemberId,
    budget
  );
  if (alreadyLinkedAccount && alreadyLinkedAccount._id !== user._id) {
    throw deterministicLinkingError(
      LINKING_ERROR_CODES.aliasConflict,
      `target_member_id=${linkContext.targetMemberId},existing_account_id=${alreadyLinkedAccount.id}`
    );
  }

  const resolvedTarget = await resolveBudgetedCanonicalMemberId(
    ctx,
    linkContext.targetMemberId,
    budget
  );
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
    const existingAlias = await findBudgetedMaterializedAlias(
      ctx,
      linkContext.targetMemberId,
      budget
    );
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
  const referenceRewrite = await prepareClaimedFriendReferenceRewrite(
    ctx,
    creatorAccount,
    linkContext.targetMemberId,
    user,
    budget
  );
  const aliasInsert = await prepareBudgetedAliasInsert(
    ctx,
    { id: user.id, email: user.email, member_id: userCanonicalMemberId },
    linkContext.targetMemberId,
    now,
    budget
  );

  const friendWrites: AccountFriendWrite[] = [];
  const normalizedCreatorEmail = linkContext.creatorEmail.toLowerCase().trim();
  const shouldStoreOriginalName = targetFriend.name !== user.display_name;
  const nicknameMatches =
    targetFriend.nickname &&
    targetFriend.nickname.trim().toLowerCase() === user.display_name.trim().toLowerCase();

  const canonicalRow = await findFriendRecordByMemberId(
    ctx,
    normalizedCreatorEmail,
    userCanonicalMemberId,
    budget
  );
  if (canonicalRow && canonicalRow._id !== targetFriend._id) {
    friendWrites.push(
      {
        kind: "patch",
        id: canonicalRow._id,
        value: {
          has_linked_account: true,
          link_state: "linked",
          linked_account_id: user.id,
          linked_account_email: user.email,
          linked_member_id: userCanonicalMemberId,
          name: user.display_name ?? user.email ?? "Unknown",
          updated_at: now
        }
      },
      { kind: "delete", id: targetFriend._id }
    );
  } else if (nicknameMatches) {
    const { nickname, ...rest } = storedAccountFriend(targetFriend);
    friendWrites.push({
      kind: "replace",
      id: targetFriend._id,
      value: {
        ...rest,
        member_id: normalizeMemberId(targetFriend.member_id),
        has_linked_account: true,
        link_state: "linked",
        linked_account_id: user.id,
        linked_account_email: user.email,
        linked_member_id: userCanonicalMemberId,
        name: user.display_name ?? user.email ?? "Unknown",
        first_name: user.first_name,
        last_name: user.last_name,
        original_name: shouldStoreOriginalName ? targetFriend.name : undefined,
        updated_at: now
      }
    });
  } else {
    friendWrites.push({
      kind: "patch",
      id: targetFriend._id,
      value: {
        member_id: normalizeMemberId(targetFriend.member_id),
        has_linked_account: true,
        link_state: "linked",
        linked_account_id: user.id,
        linked_account_email: user.email,
        linked_member_id: userCanonicalMemberId,
        name: user.display_name ?? user.email ?? "Unknown",
        first_name: user.first_name,
        last_name: user.last_name,
        nickname: targetFriend.nickname,
        original_name: shouldStoreOriginalName ? targetFriend.name : undefined,
        updated_at: now
      }
    });
  }

  if (creatorAccount.member_id) {
    const creatorMemberId = normalizeMemberId(creatorAccount.member_id);
    const claimantFriendRecord = await findFriendRecordByMemberId(
      ctx,
      user.email,
      creatorMemberId,
      budget
    );
    if (claimantFriendRecord) {
      const nicknameMatches =
        claimantFriendRecord.nickname &&
        claimantFriendRecord.nickname.trim().toLowerCase() ===
          creatorAccount.display_name.trim().toLowerCase();
      if (nicknameMatches) {
        const { nickname, ...rest } = storedAccountFriend(claimantFriendRecord);
        friendWrites.push({
          kind: "replace",
          id: claimantFriendRecord._id,
          value: {
            ...rest,
            member_id: normalizeMemberId(claimantFriendRecord.member_id),
            has_linked_account: true,
            link_state: "linked",
            linked_account_id: creatorAccount.id,
            linked_account_email: creatorAccount.email,
            linked_member_id: creatorMemberId,
            name: creatorAccount.display_name ?? creatorAccount.email ?? "Unknown",
            first_name: creatorAccount.first_name,
            last_name: creatorAccount.last_name,
            updated_at: now
          }
        });
      } else {
        friendWrites.push({
          kind: "patch",
          id: claimantFriendRecord._id,
          value: {
            member_id: normalizeMemberId(claimantFriendRecord.member_id),
            has_linked_account: true,
            link_state: "linked",
            linked_account_id: creatorAccount.id,
            linked_account_email: creatorAccount.email,
            linked_member_id: creatorMemberId,
            name: creatorAccount.display_name ?? creatorAccount.email ?? "Unknown",
            first_name: creatorAccount.first_name,
            last_name: creatorAccount.last_name,
            nickname: claimantFriendRecord.nickname,
            updated_at: now
          }
        });
      }
    } else {
      friendWrites.push({
        kind: "insert",
        value: {
          account_email: user.email,
          member_id: creatorMemberId,
          name: creatorAccount.display_name ?? creatorAccount.email ?? "Unknown",
          first_name: creatorAccount.first_name,
          last_name: creatorAccount.last_name,
          has_linked_account: true,
          link_state: "linked",
          linked_account_id: creatorAccount.id,
          linked_account_email: creatorAccount.email,
          linked_member_id: creatorMemberId,
          profile_image_url: creatorAccount.profile_image_url,
          profile_avatar_color: creatorAccount.profile_avatar_color ?? getRandomAvatarColor(),
          updated_at: now
        }
      });
    }
  }

  return {
    referenceRewrite,
    aliasInsert,
    claimantAccountId: user._id,
    claimantAliases: updatedAliases,
    updatedAt: now,
    friendWrites,
    result: {
      contract_version: LINKING_CONTRACT_VERSION,
      target_member_id: linkContext.targetMemberId,
      canonical_member_id: userCanonicalMemberId,
      alias_member_ids: updatedAliases,
      linked_member_id: userCanonicalMemberId,
      linked_account_id: user.id,
      linked_account_email: user.email
    }
  };
}

export async function applyClaimForUser(ctx: MutationCtx, plan: LinkClaimPlan) {
  await applyCanonicalReferenceRewrite(ctx, plan.referenceRewrite);
  if (plan.aliasInsert) {
    await ctx.db.insert("member_aliases", plan.aliasInsert);
  }
  await ctx.db.patch(plan.claimantAccountId, {
    alias_member_ids: plan.claimantAliases,
    updated_at: plan.updatedAt
  });
  for (const write of plan.friendWrites) {
    if (write.kind === "patch") {
      await ctx.db.patch(write.id, write.value);
    } else if (write.kind === "replace") {
      await ctx.db.replace(write.id, write.value);
    } else if (write.kind === "delete") {
      await ctx.db.delete(write.id);
    } else {
      await ctx.db.insert("account_friends", write.value);
    }
  }
  return plan.result;
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
    const budget = createLinkingReadBudget();
    const { user } = await getCurrentUser(ctx, budget);
    if (!user) throw new Error("User not found");

    chargeLinkingQueries(budget, 1);
    const token = await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();
    accountLinkingRows(budget, token ? [token] : []);

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

    const claimPlan = await prepareClaimForUser(
      ctx,
      user,
      {
        targetMemberId: token.target_member_id,
        targetFriendId: token.target_friend_id,
        creatorEmail: token.creator_email,
        creatorId: token.creator_id
      },
      budget
    );

    await ctx.db.patch(token._id, {
      claimed_by: user.id,
      claimed_at: now
    });
    return await applyClaimForUser(ctx, claimPlan);
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
    const budget = createLinkingReadBudget();
    chargeLinkingQueries(budget, 1);
    const user = await ctx.db.get(args.userAccountId);
    accountLinkingRows(budget, user ? [user] : []);
    if (!user) throw new Error("User not found");
    assertAccountCanAcceptChanges(user);

    chargeLinkingQueries(budget, 1);
    const token = await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", args.tokenId))
      .unique();
    accountLinkingRows(budget, token ? [token] : []);

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

    const claimPlan = await prepareClaimForUser(
      ctx,
      user,
      {
        targetMemberId: token.target_member_id,
        targetFriendId: token.target_friend_id,
        creatorEmail: token.creator_email,
        creatorId: token.creator_id
      },
      budget
    );
    await ctx.db.patch(token._id, {
      claimed_by: user.id,
      claimed_at: now
    });
    return await applyClaimForUser(ctx, claimPlan);
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
    const budget = createLinkingReadBudget();
    chargeLinkingQueries(budget, 1);
    const user = await ctx.db.get(args.userAccountId);
    accountLinkingRows(budget, user ? [user] : []);
    if (!user) throw new Error("User not found");
    assertAccountCanAcceptChanges(user);

    const claimPlan = await prepareClaimForUser(
      ctx,
      user,
      {
        targetMemberId: args.targetMemberId,
        targetFriendId: args.targetFriendId,
        creatorEmail: args.creatorEmail,
        creatorId: args.creatorId
      },
      budget
    );
    return await applyClaimForUser(ctx, claimPlan);
  }
});
