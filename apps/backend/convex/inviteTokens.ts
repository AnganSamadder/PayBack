import { Doc, Id } from "./_generated/dataModel";
import { mutation, query, internalMutation, MutationCtx, QueryCtx } from "./_generated/server";
import type { WithoutSystemFields } from "convex/server";
import { getConvexSize, type Value, v } from "convex/values";
import { getRandomAvatarColor } from "./utils";
import {
  accountLinkingRows,
  applyCanonicalReferenceRewrite,
  assertMergeWorstCaseReadWithinLimit,
  chargeLinkingQueries,
  collectSequentialLinkingRows,
  createLinkingReadBudget,
  prepareClaimedFriendReferenceRewrite,
  prepareInviteMergeSourceInternal,
  reserveMergeWriteValuesForLimit,
  type CanonicalReferenceRewritePlan,
  type LinkingReadBudget,
  type PreparedInviteMergeSource
} from "./aliases";
import {
  assertMemberIdentityNotCleanupFenced,
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
import {
  assertAccountCanAcceptChanges,
  getCurrentUserOrThrow,
  isAccountDeletionFenced
} from "./helpers";

// Helper to get current authenticated user
async function getCurrentUser(ctx: any, budget?: LinkingReadBudget) {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) {
    throw new Error("Unauthenticated");
  }
  if (budget) chargeLinkingQueries(budget, 1);
  const { user } = await getCurrentUserOrThrow(ctx);
  if (budget) accountLinkingRows(budget, user ? [user] : []);

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

function missingFriendMetadata(primary: Doc<"account_friends">, fallback: Doc<"account_friends">) {
  return {
    nickname: primary.nickname ?? fallback.nickname,
    original_name: primary.original_name ?? fallback.original_name,
    original_nickname: primary.original_nickname ?? fallback.original_nickname,
    prefer_nickname: primary.prefer_nickname ?? fallback.prefer_nickname,
    first_name: primary.first_name ?? fallback.first_name,
    last_name: primary.last_name ?? fallback.last_name,
    display_preference: primary.display_preference ?? fallback.display_preference,
    profile_image_url: primary.profile_image_url ?? fallback.profile_image_url
  };
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
    throw new Error("Friend merge is too large to complete safely");
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

  await assertMemberIdentityNotCleanupFenced(ctx, normalizedAlias, (rows) => {
    chargeLinkingQueries(budget, 1);
    accountLinkingRows(budget, rows);
  });

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
      creator_email: user.email.trim().toLowerCase(),
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

const publicInvitePreviewLimits = {
  aliases: MAX_LIVE_ACCOUNT_ALIASES,
  queryWork: 512,
  readRows: 768,
  encodedReadBytes: 8 * 1024 * 1024,
  // Convex documents are capped at 1 MiB. Reserving twice that amount before every
  // sequential read leaves six MiB below the platform's 16 MiB transaction limit.
  maximumDocumentReservationBytes: 2 * 1024 * 1024,
  hardReadSafetyBytes: 10 * 1024 * 1024,
  maximumPageRows: 5
} as const;

type PublicInvitePreviewBudget = {
  queryWork: number;
  readRows: number;
  encodedReadBytes: number;
};

function createPublicInvitePreviewBudget(): PublicInvitePreviewBudget {
  return { queryWork: 0, readRows: 0, encodedReadBytes: 0 };
}

function reservePublicInvitePreviewRead(budget: PublicInvitePreviewBudget, maximumRows: number) {
  const remainingRows = publicInvitePreviewLimits.readRows - budget.readRows;
  const remainingHardReadBytes =
    publicInvitePreviewLimits.hardReadSafetyBytes - budget.encodedReadBytes;
  const byteReservedRows = Math.floor(
    remainingHardReadBytes / publicInvitePreviewLimits.maximumDocumentReservationBytes
  );
  const reservedRows = Math.min(
    publicInvitePreviewLimits.maximumPageRows,
    maximumRows,
    remainingRows,
    byteReservedRows
  );
  if (reservedRows <= 0 || budget.queryWork + 1 > publicInvitePreviewLimits.queryWork) {
    return 0;
  }
  budget.queryWork += 1;
  return reservedRows;
}

function accountPublicInvitePreviewRows(
  budget: PublicInvitePreviewBudget,
  rows: readonly unknown[]
) {
  budget.readRows += rows.length;
  budget.encodedReadBytes += rows.reduce<number>(
    (total, row) => total + getConvexSize(row as Value),
    0
  );
  return (
    budget.readRows <= publicInvitePreviewLimits.readRows &&
    budget.encodedReadBytes <= publicInvitePreviewLimits.encodedReadBytes
  );
}

async function collectSequentialPublicInvitePreviewRows<T>(
  budget: PublicInvitePreviewBudget,
  readPage: (
    cursor: string | null,
    limit: number
  ) => Promise<{ page: T[]; continueCursor: string; isDone: boolean }>,
  stopAfterRows: number
): Promise<T[] | null> {
  const rows: T[] = [];
  let cursor: string | null = null;

  while (true) {
    const pageSize = reservePublicInvitePreviewRead(budget, stopAfterRows - rows.length);
    if (pageSize === 0) return null;

    const result = await readPage(cursor, pageSize);
    if (!accountPublicInvitePreviewRows(budget, result.page)) return null;
    rows.push(...result.page);
    if (rows.length >= stopAfterRows) return rows.slice(0, stopAfterRows);
    if (result.isDone) return rows;
    if (result.continueCursor === cursor) return null;
    cursor = result.continueCursor;
  }
}

async function readPublicInvitePreviewDocument<T>(
  budget: PublicInvitePreviewBudget,
  read: () => Promise<T | null>
): Promise<{ completed: boolean; document: T | null }> {
  if (reservePublicInvitePreviewRead(budget, 1) === 0) {
    return { completed: false, document: null };
  }
  const document = await read();
  if (!accountPublicInvitePreviewRows(budget, document ? [document] : [])) {
    return { completed: false, document: null };
  }
  return { completed: true, document };
}

type PreviewOwnerIdentity = {
  owner_id?: Doc<"accounts">["_id"];
  owner_account_id?: string;
  owner_email?: string;
};

function isPreviewRowOwnedByAccount(
  row: PreviewOwnerIdentity,
  account: Pick<Doc<"accounts">, "_id" | "id" | "email">
) {
  const ownerAccountId = row.owner_account_id?.trim();
  const ownerEmail = row.owner_email?.trim().toLowerCase();
  const hasOwnerDocumentId = Boolean(row.owner_id);
  const hasOwnerAccountId = Boolean(ownerAccountId);
  const hasOwnerEmail = Boolean(ownerEmail);

  return (
    (!hasOwnerDocumentId || row.owner_id === account._id) &&
    (!hasOwnerAccountId || ownerAccountId === account.id) &&
    (!hasOwnerEmail || ownerEmail === account.email.trim().toLowerCase()) &&
    (hasOwnerDocumentId || hasOwnerAccountId || hasOwnerEmail)
  );
}

async function collectCreatorExpensesForPreview(
  ctx: Pick<QueryCtx, "db">,
  creator: Doc<"accounts">,
  budget: PublicInvitePreviewBudget
) {
  const creatorExpenses = new Map<string, Doc<"expenses">>();
  const indexedReads = [
    (cursor: string | null, limit: number) =>
      ctx.db
        .query("expenses")
        .withIndex("by_owner_id", (q) => q.eq("owner_id", creator._id))
        .order("asc")
        .paginate({ cursor, numItems: limit }),
    (cursor: string | null, limit: number) =>
      ctx.db
        .query("expenses")
        .withIndex("by_owner_account_id", (q) => q.eq("owner_account_id", creator.id))
        .order("asc")
        .paginate({ cursor, numItems: limit }),
    (cursor: string | null, limit: number) =>
      ctx.db
        .query("expenses")
        .withIndex("by_owner_email", (q) => q.eq("owner_email", creator.email))
        .order("asc")
        .paginate({ cursor, numItems: limit })
  ];

  for (const readPage of indexedReads) {
    const indexedRows = await collectSequentialPublicInvitePreviewRows(
      budget,
      readPage,
      MAX_PUBLIC_INVITE_PREVIEW_EXPENSES + 1
    );
    if (!indexedRows || indexedRows.length > MAX_PUBLIC_INVITE_PREVIEW_EXPENSES) {
      return null;
    }
    for (const expense of indexedRows) {
      if (isPreviewRowOwnedByAccount(expense, creator)) {
        creatorExpenses.set(String(expense._id), expense);
      }
    }
  }

  if (creatorExpenses.size > MAX_PUBLIC_INVITE_PREVIEW_EXPENSES) return null;
  return Array.from(creatorExpenses.values());
}

async function resolveCreatorGroupNameForPreview(
  ctx: Pick<QueryCtx, "db">,
  expense: Doc<"expenses">,
  creator: Doc<"accounts">,
  budget: PublicInvitePreviewBudget
): Promise<{ completed: boolean; groupName: string | null }> {
  if (expense.group_ref) {
    const result = await readPublicInvitePreviewDocument(budget, () =>
      ctx.db.get(expense.group_ref!)
    );
    if (!result.completed) return { completed: false, groupName: null };
    const group = result.document;
    if (group && group.id === expense.group_id && isPreviewRowOwnedByAccount(group, creator)) {
      return { completed: true, groupName: group.name };
    }
    return { completed: true, groupName: null };
  }

  const candidates = await collectSequentialPublicInvitePreviewRows(
    budget,
    (cursor, limit) =>
      ctx.db
        .query("groups")
        .withIndex("by_client_id", (q) => q.eq("id", expense.group_id))
        .order("asc")
        .paginate({ cursor, numItems: limit }),
    2
  );
  if (!candidates) return { completed: false, groupName: null };
  const ownedGroups = candidates.filter((group) => isPreviewRowOwnedByAccount(group, creator));
  return {
    completed: true,
    groupName: ownedGroups.length === 1 ? ownedGroups[0].name : null
  };
}

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

    let expensePreview: {
      expense_count: number;
      group_names: string[];
      total_balance: number;
    } | null = null;
    const targetAliases = normalizeMemberIds(targetFriend.local_alias_member_ids);
    if (targetAliases.length <= publicInvitePreviewLimits.aliases) {
      const previewBudget = createPublicInvitePreviewBudget();
      const creatorExpenses = await collectCreatorExpensesForPreview(
        ctx,
        creatorAccount,
        previewBudget
      );
      if (!creatorExpenses) {
        return {
          is_valid: true,
          error: null,
          token: { ...publicToken },
          expense_preview: null
        };
      }
      const targetIdentityMemberIds = new Set(
        normalizeMemberIds([token.target_member_id, ...targetAliases])
      );
      const matchesTargetIdentity = (memberId: string) =>
        targetIdentityMemberIds.has(normalizeMemberId(memberId));
      const memberExpenses = creatorExpenses.filter(
        (expense) =>
          matchesTargetIdentity(expense.paid_by_member_id) ||
          expense.involved_member_ids.some(matchesTargetIdentity) ||
          expense.splits.some((split) => matchesTargetIdentity(split.member_id)) ||
          expense.participant_member_ids.some(matchesTargetIdentity) ||
          expense.participants.some((participant) => matchesTargetIdentity(participant.member_id))
      );
      const groupNames = new Set<string>();
      let totalBalance = 0;
      for (const expense of memberExpenses) {
        const groupResult = await resolveCreatorGroupNameForPreview(
          ctx,
          expense,
          creatorAccount,
          previewBudget
        );
        if (!groupResult.completed) {
          return {
            is_valid: true,
            error: null,
            token: { ...publicToken },
            expense_preview: null
          };
        }
        if (groupResult.groupName) {
          groupNames.add(groupResult.groupName);
        }
        if (matchesTargetIdentity(expense.paid_by_member_id)) {
          totalBalance += expense.splits
            .filter((split) => !matchesTargetIdentity(split.member_id) && !split.is_settled)
            .reduce((sum, split) => sum + split.amount, 0);
        } else {
          totalBalance -= expense.splits
            .filter((split) => matchesTargetIdentity(split.member_id) && !split.is_settled)
            .reduce((sum, split) => sum + split.amount, 0);
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

function definedConvexValue(value: Record<string, unknown>): Value {
  return Object.fromEntries(
    Object.entries(value).filter(([, field]) => field !== undefined)
  ) as Value;
}

export type LinkClaimPlan = {
  selectedFriendMerge?: PreparedInviteMergeSource;
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
  budget: LinkingReadBudget,
  mergeLocalFriendMemberId?: string
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

  const ownerLocalTargetAliases = normalizeMemberIds(targetFriend.local_alias_member_ids);
  if (ownerLocalTargetAliases.length > MAX_LIVE_ACCOUNT_ALIASES) {
    throw new Error("Friend merge is too large to complete safely");
  }
  for (const localAliasMemberId of ownerLocalTargetAliases) {
    const linkedAccount = await findBudgetedAccountByMemberId(ctx, localAliasMemberId, budget);
    if (linkedAccount && linkedAccount.id !== user.id) {
      throw deterministicLinkingError(
        LINKING_ERROR_CODES.aliasConflict,
        `local_alias_member_id=${localAliasMemberId},existing_account_id=${linkedAccount.id},claimer_account_id=${user.id}`
      );
    }
    const resolvedLocalAlias = await resolveBudgetedCanonicalMemberId(
      ctx,
      localAliasMemberId,
      budget
    );
    if (!linkedAccount && normalizeMemberId(resolvedLocalAlias) !== localAliasMemberId) {
      throw deterministicLinkingError(
        LINKING_ERROR_CODES.aliasConflict,
        `local_alias_member_id=${localAliasMemberId},canonical_member_id=${resolvedLocalAlias}`
      );
    }
  }

  const creatorMemberId = creatorAccount.member_id
    ? normalizeMemberId(creatorAccount.member_id)
    : undefined;
  const requestedMergeMemberId = mergeLocalFriendMemberId
    ? normalizeMemberId(mergeLocalFriendMemberId)
    : undefined;
  if (requestedMergeMemberId && !creatorMemberId) {
    throw new Error("Creator account is missing a canonical member_id");
  }

  const claimantIdentityClosure = new Set(
    normalizeMemberIds([
      linkContext.targetMemberId,
      userCanonicalMemberId,
      ...(user.alias_member_ids ?? [])
    ])
  );
  if (requestedMergeMemberId && claimantIdentityClosure.has(requestedMergeMemberId)) {
    throw new Error("Cannot merge the claimant identity into the inviter");
  }

  const selectedFriendMerge =
    requestedMergeMemberId && creatorMemberId && requestedMergeMemberId !== creatorMemberId
      ? await prepareInviteMergeSourceInternal(ctx, {
          accountEmail: user.email,
          sourceMemberId: requestedMergeMemberId,
          targetMemberId: creatorMemberId,
          targetName: creatorAccount.display_name ?? creatorAccount.email ?? "Unknown",
          targetLinkedAccountId: creatorAccount.id,
          targetLinkedAccountEmail: creatorAccount.email.trim().toLowerCase(),
          readBudget: budget
        })
      : undefined;
  if (selectedFriendMerge?.localAliases.some((memberId) => claimantIdentityClosure.has(memberId))) {
    throw new Error("Cannot merge the claimant identity into the inviter");
  }

  const referenceRewrite = await prepareClaimedFriendReferenceRewrite(
    ctx,
    creatorAccount,
    normalizeMemberIds([linkContext.targetMemberId, ...ownerLocalTargetAliases]),
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
  const retainedLocalAliases = normalizeMemberIds([
    ...(canonicalRow?.local_alias_member_ids ?? []),
    ...ownerLocalTargetAliases
  ]).filter((memberId) => memberId !== userCanonicalMemberId);
  if (retainedLocalAliases.length > MAX_LIVE_ACCOUNT_ALIASES) {
    throw new Error("Friend merge is too large to complete safely");
  }
  if (canonicalRow && canonicalRow._id !== targetFriend._id) {
    friendWrites.push(
      {
        kind: "patch",
        id: canonicalRow._id,
        value: {
          has_linked_account: true,
          link_state: "linked",
          status: "friend",
          linked_account_id: user.id,
          linked_account_email: user.email.trim().toLowerCase(),
          linked_member_id: userCanonicalMemberId,
          local_alias_member_ids: retainedLocalAliases,
          name: user.display_name ?? user.email ?? "Unknown",
          ...missingFriendMetadata(canonicalRow, targetFriend),
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
        status: "friend",
        linked_account_id: user.id,
        linked_account_email: user.email.trim().toLowerCase(),
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
        status: "friend",
        linked_account_id: user.id,
        linked_account_email: user.email.trim().toLowerCase(),
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

  let plannedReciprocalFriend: Doc<"account_friends"> | null = null;
  if (creatorMemberId) {
    const claimantFriendRecord = selectedFriendMerge
      ? selectedFriendMerge.targetFriend
      : await findFriendRecordByMemberId(ctx, user.email, creatorMemberId, budget);
    const selectedSourceFriend = selectedFriendMerge?.sourceFriend;
    const reciprocalFriend = claimantFriendRecord ?? selectedSourceFriend ?? null;
    plannedReciprocalFriend = reciprocalFriend;

    if (reciprocalFriend) {
      const reciprocalMetadata = selectedSourceFriend
        ? missingFriendMetadata(reciprocalFriend, selectedSourceFriend)
        : missingFriendMetadata(reciprocalFriend, reciprocalFriend);
      const nicknameMatches =
        reciprocalMetadata.nickname &&
        reciprocalMetadata.nickname.trim().toLowerCase() ===
          creatorAccount.display_name.trim().toLowerCase();
      if (nicknameMatches) {
        const { nickname: _nickname, ...rest } = storedAccountFriend(reciprocalFriend);
        const { nickname: _mergedNickname, ...metadataWithoutNickname } = reciprocalMetadata;
        friendWrites.push({
          kind: "replace",
          id: reciprocalFriend._id,
          value: {
            ...rest,
            ...metadataWithoutNickname,
            member_id: creatorMemberId,
            has_linked_account: true,
            link_state: "linked",
            status: "friend",
            linked_account_id: creatorAccount.id,
            linked_account_email: creatorAccount.email.trim().toLowerCase(),
            linked_member_id: creatorMemberId,
            local_alias_member_ids:
              selectedFriendMerge?.localAliases ?? reciprocalFriend.local_alias_member_ids,
            name: creatorAccount.display_name ?? creatorAccount.email ?? "Unknown",
            first_name: creatorAccount.first_name,
            last_name: creatorAccount.last_name,
            updated_at: now
          }
        });
      } else {
        friendWrites.push({
          kind: "patch",
          id: reciprocalFriend._id,
          value: {
            ...reciprocalMetadata,
            member_id: creatorMemberId,
            has_linked_account: true,
            link_state: "linked",
            status: "friend",
            linked_account_id: creatorAccount.id,
            linked_account_email: creatorAccount.email.trim().toLowerCase(),
            linked_member_id: creatorMemberId,
            local_alias_member_ids:
              selectedFriendMerge?.localAliases ?? reciprocalFriend.local_alias_member_ids,
            name: creatorAccount.display_name ?? creatorAccount.email ?? "Unknown",
            first_name: creatorAccount.first_name,
            last_name: creatorAccount.last_name,
            updated_at: now
          }
        });
      }
      if (selectedSourceFriend && selectedSourceFriend._id !== reciprocalFriend._id) {
        friendWrites.push({ kind: "delete", id: selectedSourceFriend._id });
      }
    } else {
      friendWrites.push({
        kind: "insert",
        value: {
          account_email: user.email.trim().toLowerCase(),
          member_id: creatorMemberId,
          name: creatorAccount.display_name ?? creatorAccount.email ?? "Unknown",
          first_name: creatorAccount.first_name,
          last_name: creatorAccount.last_name,
          has_linked_account: true,
          link_state: "linked",
          status: "friend",
          linked_account_id: creatorAccount.id,
          linked_account_email: creatorAccount.email.trim().toLowerCase(),
          linked_member_id: creatorMemberId,
          profile_image_url: creatorAccount.profile_image_url,
          profile_avatar_color: creatorAccount.profile_avatar_color ?? getRandomAvatarColor(),
          updated_at: now
        }
      });
    }
  }

  const knownFriendRows = new Map(
    [
      targetFriend,
      canonicalRow,
      selectedFriendMerge?.sourceFriend,
      selectedFriendMerge?.targetFriend,
      plannedReciprocalFriend
    ]
      .filter((friend): friend is Doc<"account_friends"> => Boolean(friend))
      .map((friend) => [String(friend._id), friend])
  );
  let insertedDocuments = aliasInsert ? 1 : 0;
  const plannedWriteValues: Value[] = [
    definedConvexValue({
      ...user,
      alias_member_ids: updatedAliases,
      updated_at: now
    })
  ];
  if (aliasInsert) plannedWriteValues.push(definedConvexValue(aliasInsert));
  for (const write of friendWrites) {
    if (write.kind === "insert") {
      insertedDocuments += 1;
      plannedWriteValues.push(definedConvexValue(write.value));
      continue;
    }
    const current = knownFriendRows.get(String(write.id));
    if (!current) {
      throw new Error("Friend merge plan is missing a write target");
    }
    plannedWriteValues.push(
      write.kind === "delete"
        ? (current as Value)
        : definedConvexValue({ ...current, ...write.value })
    );
  }
  reserveMergeWriteValuesForLimit(budget, plannedWriteValues, insertedDocuments);
  assertMergeWorstCaseReadWithinLimit(budget);

  return {
    selectedFriendMerge,
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
      linked_account_email: user.email.trim().toLowerCase()
    }
  };
}

export async function applyClaimForUser(ctx: MutationCtx, plan: LinkClaimPlan) {
  await plan.selectedFriendMerge?.applyCanonicalRewrite();
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
  args: {
    id: v.string(),
    mergeLocalFriendMemberId: v.optional(v.string())
  },
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
    const requestedMergeMemberId = args.mergeLocalFriendMemberId
      ? normalizeMemberId(args.mergeLocalFriendMemberId)
      : undefined;

    if (token.claimed_by) {
      if (token.claimed_by !== user.id) {
        throw new Error("Token has already been claimed");
      }
      if (token.claim_merge_local_friend_member_id !== requestedMergeMemberId) {
        throw new Error("Token was already claimed with a different merge selection");
      }

      await assertBudgetedIdentityMaterializationReady(ctx, budget);
      const canonicalMemberId = user.member_id ? normalizeMemberId(user.member_id) : undefined;
      if (!canonicalMemberId) {
        throw new Error("User account does not have a member_id assigned");
      }
      return {
        contract_version: LINKING_CONTRACT_VERSION,
        target_member_id: normalizeMemberId(token.target_member_id),
        canonical_member_id: canonicalMemberId,
        alias_member_ids: normalizeMemberIds(user.alias_member_ids || []).filter(
          (memberId) => memberId !== canonicalMemberId
        ),
        linked_member_id: canonicalMemberId,
        linked_account_id: user.id,
        linked_account_email: user.email.trim().toLowerCase()
      };
    }

    if (token.expires_at < now) {
      throw new Error("Token has expired");
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
      budget,
      requestedMergeMemberId
    );

    const tokenPatch = {
      claimed_by: user.id,
      claimed_at: now,
      claim_merge_local_friend_member_id: requestedMergeMemberId
    };
    reserveMergeWriteValuesForLimit(budget, [definedConvexValue({ ...token, ...tokenPatch })]);
    await ctx.db.patch(token._id, tokenPatch);
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
    const tokenPatch = {
      claimed_by: user.id,
      claimed_at: now
    };
    reserveMergeWriteValuesForLimit(budget, [definedConvexValue({ ...token, ...tokenPatch })]);
    await ctx.db.patch(token._id, tokenPatch);
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
