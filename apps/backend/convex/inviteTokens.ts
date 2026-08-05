import { Doc, Id } from "./_generated/dataModel";
import { mutation, query, internalMutation, MutationCtx, QueryCtx } from "./_generated/server";
import { getConvexSize, type Value, v } from "convex/values";
import { getRandomAvatarColor } from "./utils";
import {
  accountMergeQueriesForLimit,
  accountMergeRowsForLimit,
  assertMergeIdentityMaterializationReady,
  assertMergeWorstCaseReadWithinLimit,
  collectSequentialMergeIndexRows,
  createMergeReadBudget,
  findMergeFriendRecordByMemberId,
  prepareClaimedFriendReferenceRewrite,
  prepareInviteMergeSourceInternal,
  resolveMergeAccountByMemberId,
  type MergeReadBudget,
  type PreparedInviteMergeSource
} from "./aliases";
import {
  deterministicLinkingError,
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
const MAX_CLAIM_ALIAS_ROWS = 8;

async function prepareClaimAliasMaterialization(
  ctx: MutationCtx,
  account: Pick<Doc<"accounts">, "id" | "email" | "member_id">,
  aliasMemberId: string,
  readBudget: MergeReadBudget,
  now: number
) {
  const canonicalMemberId = account.member_id ? normalizeMemberId(account.member_id) : undefined;
  const normalizedAlias = normalizeMemberId(aliasMemberId);
  if (!canonicalMemberId) {
    throw new Error("Cannot materialize aliases without a canonical member_id");
  }
  if (!normalizedAlias || normalizedAlias === canonicalMemberId) return async () => {};

  const aliasResolution = await resolveMergeAccountByMemberId(ctx, normalizedAlias, readBudget);
  if (aliasResolution.account && aliasResolution.account.id !== account.id) {
    throw deterministicLinkingError(
      LINKING_ERROR_CODES.aliasConflict,
      `alias_member_id=${normalizedAlias},canonical_account_id=${aliasResolution.account.id}`
    );
  }

  const aliasRows = await collectSequentialMergeIndexRows(
    readBudget,
    async (cursor, limit) =>
      await ctx.db
        .query("member_aliases")
        .withIndex("by_alias_member_id", (q) => q.eq("alias_member_id", normalizedAlias))
        .order("asc")
        .paginate({ cursor, numItems: limit }),
    () => accountMergeQueriesForLimit(readBudget, 1),
    MAX_CLAIM_ALIAS_ROWS + 1
  );
  if (aliasRows.length > MAX_CLAIM_ALIAS_ROWS) {
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

  const sourceRows = await collectSequentialMergeIndexRows(
    readBudget,
    async (cursor, limit) =>
      await ctx.db
        .query("member_aliases")
        .withIndex("by_source_account_and_alias", (q) =>
          q.eq("source_account_id", account.id).eq("alias_member_id", normalizedAlias)
        )
        .order("asc")
        .paginate({ cursor, numItems: limit }),
    () => accountMergeQueriesForLimit(readBudget, 1),
    2
  );
  if (sourceRows.length > 1) {
    throw new Error(
      `Identity maintenance required: duplicate account materializations for ${normalizedAlias}`
    );
  }
  if (sourceRows.length === 1) return async () => {};

  return async () => {
    await ctx.db.insert("member_aliases", {
      canonical_member_id: canonicalMemberId,
      alias_member_id: normalizedAlias,
      account_email: account.email.toLowerCase().trim(),
      materialization_source: "account_alias",
      source_account_id: account.id,
      created_at: now
    });
  };
}

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
async function claimForUser(
  ctx: any,
  user: any,
  input: LinkClaimContext,
  mergeReadBudget?: MergeReadBudget,
  preparedSelectedFriendMerge?: PreparedInviteMergeSource,
  identityMaterializationReady = false
) {
  const readBudget = mergeReadBudget ?? createMergeReadBudget();
  if (!identityMaterializationReady) {
    await assertMergeIdentityMaterializationReady(ctx, readBudget);
  }
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

  accountMergeQueriesForLimit(readBudget, 1);
  const creatorAccount = linkContext.creatorId
    ? await ctx.db
        .query("accounts")
        .withIndex("by_auth_id", (q: any) => q.eq("id", linkContext.creatorId!))
        .unique()
    : await ctx.db
        .query("accounts")
        .withIndex("by_email", (q: any) => q.eq("email", linkContext.creatorEmail))
        .unique();
  accountMergeRowsForLimit(readBudget, creatorAccount ? [creatorAccount] : []);
  if (
    !creatorAccount ||
    creatorAccount.status === "deleted" ||
    creatorAccount.email.trim().toLowerCase() !== linkContext.creatorEmail
  ) {
    throw new Error("Invite creator account is no longer active");
  }
  accountMergeQueriesForLimit(readBudget, 1);
  const targetFriend = await validateBoundInviteTarget(ctx, creatorAccount, linkContext);
  accountMergeRowsForLimit(readBudget, [targetFriend]);

  const userCanonicalMemberId = user.member_id ? normalizeMemberId(user.member_id) : undefined;
  if (!userCanonicalMemberId) {
    throw new Error("User account does not have a member_id assigned");
  }

  const targetResolution = await resolveMergeAccountByMemberId(
    ctx,
    linkContext.targetMemberId,
    readBudget
  );
  const alreadyLinkedAccount = targetResolution.account;
  if (alreadyLinkedAccount && alreadyLinkedAccount._id !== user._id) {
    throw deterministicLinkingError(
      LINKING_ERROR_CODES.aliasConflict,
      `target_member_id=${linkContext.targetMemberId},existing_account_id=${alreadyLinkedAccount.id}`
    );
  }

  const normalizedResolvedTarget = targetResolution.canonicalMemberId;

  if (
    normalizedResolvedTarget !== userCanonicalMemberId &&
    normalizedResolvedTarget !== linkContext.targetMemberId
  ) {
    throw deterministicLinkingError(
      LINKING_ERROR_CODES.aliasConflict,
      `target_member_id=${linkContext.targetMemberId},resolved_canonical=${normalizedResolvedTarget},claimer_canonical=${userCanonicalMemberId}`
    );
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
    const localAliasResolution = await resolveMergeAccountByMemberId(
      ctx,
      localAliasMemberId,
      readBudget
    );
    const linkedAccount = localAliasResolution.account;
    if (linkedAccount && linkedAccount.id !== user.id) {
      throw deterministicLinkingError(
        LINKING_ERROR_CODES.aliasConflict,
        `local_alias_member_id=${localAliasMemberId},existing_account_id=${linkedAccount.id},claimer_account_id=${user.id}`
      );
    }
    if (localAliasResolution.hasMaterializedAlias && !linkedAccount) {
      throw deterministicLinkingError(
        LINKING_ERROR_CODES.aliasConflict,
        `local_alias_member_id=${localAliasMemberId},canonical_member_id=${localAliasResolution.canonicalMemberId}`
      );
    }
  }
  const targetIdentityClosure = normalizeMemberIds([
    linkContext.targetMemberId,
    ...ownerLocalTargetAliases
  ]);
  const applyClaimedReferenceRewrite = await prepareClaimedFriendReferenceRewrite(
    ctx,
    creatorAccount,
    targetIdentityClosure,
    user,
    readBudget
  );

  const canonicalRow = await findMergeFriendRecordByMemberId(
    ctx,
    linkContext.creatorEmail,
    userCanonicalMemberId,
    readBudget
  );
  const retainedLocalAliases = normalizeMemberIds([
    ...(canonicalRow?.local_alias_member_ids ?? []),
    ...ownerLocalTargetAliases
  ]).filter((memberId) => memberId !== userCanonicalMemberId);
  if (retainedLocalAliases.length > MAX_LIVE_ACCOUNT_ALIASES) {
    throw new Error("Friend merge is too large to complete safely");
  }

  const creatorMemberId = creatorAccount.member_id
    ? normalizeMemberId(creatorAccount.member_id)
    : undefined;
  const claimantFriendRecord = preparedSelectedFriendMerge
    ? preparedSelectedFriendMerge.targetFriend
    : creatorMemberId
      ? await findMergeFriendRecordByMemberId(ctx, user.email, creatorMemberId, readBudget)
      : null;
  const applyAccountAliasMaterialization = await prepareClaimAliasMaterialization(
    ctx,
    { id: user.id, email: user.email, member_id: userCanonicalMemberId },
    linkContext.targetMemberId,
    readBudget,
    now
  );

  assertMergeWorstCaseReadWithinLimit(readBudget);
  await preparedSelectedFriendMerge?.applyCanonicalRewrite();
  await applyClaimedReferenceRewrite();
  await applyAccountAliasMaterialization();
  await ctx.db.patch(user._id, {
    alias_member_ids: updatedAliases,
    updated_at: now
  });

  const shouldStoreOriginalName = targetFriend.name !== user.display_name;

  // If both canonical and target rows exist, keep canonical and preserve the target's owner-local
  // aliases. These aliases stay scoped to the creator and are never materialized globally.
  if (canonicalRow && canonicalRow._id !== targetFriend._id) {
    await ctx.db.patch(canonicalRow._id, {
      has_linked_account: true,
      link_state: "linked",
      status: "friend",
      linked_account_id: user.id,
      linked_account_email: user.email,
      linked_member_id: userCanonicalMemberId,
      local_alias_member_ids: retainedLocalAliases,
      name: user.display_name ?? user.email ?? "Unknown",
      ...missingFriendMetadata(canonicalRow, targetFriend),
      updated_at: now
    });
    await ctx.db.delete(targetFriend._id);
  } else {
    const userFirstName = user.first_name;
    const userLastName = user.last_name;

    const nicknameMatches =
      targetFriend.nickname &&
      targetFriend.nickname.trim().toLowerCase() === user.display_name.trim().toLowerCase();
    if (nicknameMatches) {
      const { nickname, ...rest } = targetFriend;
      await ctx.db.replace(targetFriend._id, {
        ...rest,
        member_id: normalizeMemberId(targetFriend.member_id),
        has_linked_account: true,
        link_state: "linked",
        status: "friend",
        linked_account_id: user.id,
        linked_account_email: user.email,
        linked_member_id: userCanonicalMemberId,
        name: user.display_name ?? user.email ?? "Unknown",
        first_name: userFirstName,
        last_name: userLastName,
        original_name: shouldStoreOriginalName ? targetFriend.name : undefined,
        updated_at: now
      });
    } else {
      await ctx.db.patch(targetFriend._id, {
        member_id: normalizeMemberId(targetFriend.member_id),
        has_linked_account: true,
        link_state: "linked",
        status: "friend",
        linked_account_id: user.id,
        linked_account_email: user.email,
        linked_member_id: userCanonicalMemberId,
        name: user.display_name ?? user.email ?? "Unknown",
        first_name: userFirstName,
        last_name: userLastName,
        nickname: targetFriend.nickname,
        original_name: shouldStoreOriginalName ? targetFriend.name : undefined,
        updated_at: now
      });
    }
  }

  // 2. Create/update friend record for the claimant to see the creator
  if (creatorMemberId) {
    // Use the creator's first/last name directly from their account
    const creatorFirstName = creatorAccount.first_name;
    const creatorLastName = creatorAccount.last_name;

    const selectedSourceFriend = preparedSelectedFriendMerge?.sourceFriend;
    const reciprocalFriend = claimantFriendRecord ?? selectedSourceFriend ?? null;

    if (reciprocalFriend) {
      const reciprocalMetadata = selectedSourceFriend
        ? missingFriendMetadata(reciprocalFriend, selectedSourceFriend)
        : missingFriendMetadata(reciprocalFriend, reciprocalFriend);
      const nicknameMatches =
        reciprocalMetadata.nickname &&
        reciprocalMetadata.nickname.trim().toLowerCase() ===
          creatorAccount.display_name.trim().toLowerCase();

      if (nicknameMatches) {
        const { nickname: _nickname, ...rest } = reciprocalFriend;
        const { nickname: _mergedNickname, ...metadataWithoutNickname } = reciprocalMetadata;
        await ctx.db.replace(reciprocalFriend._id, {
          ...rest,
          ...metadataWithoutNickname,
          member_id: creatorMemberId,
          has_linked_account: true,
          link_state: "linked",
          status: "friend",
          linked_account_id: creatorAccount.id,
          linked_account_email: creatorAccount.email,
          linked_member_id: creatorMemberId,
          local_alias_member_ids:
            preparedSelectedFriendMerge?.localAliases ?? reciprocalFriend.local_alias_member_ids,
          name: creatorAccount.display_name ?? creatorAccount.email ?? "Unknown",
          first_name: creatorFirstName,
          last_name: creatorLastName,
          updated_at: now
        });
      } else {
        await ctx.db.patch(reciprocalFriend._id, {
          ...reciprocalMetadata,
          member_id: creatorMemberId,
          has_linked_account: true,
          link_state: "linked",
          status: "friend",
          linked_account_id: creatorAccount.id,
          linked_account_email: creatorAccount.email,
          linked_member_id: creatorMemberId,
          local_alias_member_ids:
            preparedSelectedFriendMerge?.localAliases ?? reciprocalFriend.local_alias_member_ids,
          name: creatorAccount.display_name ?? creatorAccount.email ?? "Unknown",
          first_name: creatorFirstName,
          last_name: creatorLastName,
          updated_at: now
        });
      }
      if (selectedSourceFriend && selectedSourceFriend._id !== reciprocalFriend._id) {
        await ctx.db.delete(selectedSourceFriend._id);
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
        status: "friend",
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
  args: {
    id: v.string(),
    mergeLocalFriendMemberId: v.optional(v.string())
  },
  handler: async (ctx, args) => {
    const mergeReadBudget = createMergeReadBudget();
    accountMergeQueriesForLimit(mergeReadBudget, 1);
    const { user } = await getCurrentUser(ctx);
    if (!user) throw new Error("User not found");
    accountMergeRowsForLimit(mergeReadBudget, [user]);

    accountMergeQueriesForLimit(mergeReadBudget, 1);
    const token = await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    if (!token) {
      throw new Error("Token not found");
    }
    accountMergeRowsForLimit(mergeReadBudget, [token]);

    const now = Date.now();
    const requestedMergeMemberId = args.mergeLocalFriendMemberId
      ? normalizeMemberId(args.mergeLocalFriendMemberId)
      : undefined;
    const claimantIdentityClosure = new Set(
      normalizeMemberIds([
        token.target_member_id,
        ...(user.member_id ? [user.member_id] : []),
        ...(user.alias_member_ids ?? [])
      ])
    );
    if (requestedMergeMemberId && claimantIdentityClosure.has(requestedMergeMemberId)) {
      throw new Error("Cannot merge the claimant identity into the inviter");
    }
    await assertMergeIdentityMaterializationReady(ctx, mergeReadBudget);
    if (token.claimed_by) {
      if (token.claimed_by !== user.id) {
        throw new Error("Token has already been claimed");
      }
      if (token.claim_merge_local_friend_member_id !== requestedMergeMemberId) {
        throw new Error("Token was already claimed with a different merge selection");
      }

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
        linked_account_email: user.email
      };
    }

    if (token.expires_at < now) {
      throw new Error("Token has expired");
    }
    if (!token.target_friend_id) {
      throw new Error("Invite must be recreated before it can be claimed");
    }

    accountMergeQueriesForLimit(mergeReadBudget, 1);
    const creatorAccount = await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", token.creator_id))
      .unique();
    accountMergeRowsForLimit(mergeReadBudget, creatorAccount ? [creatorAccount] : []);
    if (
      !creatorAccount ||
      creatorAccount.status === "deleted" ||
      creatorAccount.email.trim().toLowerCase() !== token.creator_email.trim().toLowerCase()
    ) {
      throw new Error("Invite creator account is no longer active");
    }

    const linkContext = normalizeLinkClaimContext({
      targetMemberId: token.target_member_id,
      targetFriendId: token.target_friend_id,
      creatorEmail: token.creator_email,
      creatorId: token.creator_id
    });
    accountMergeQueriesForLimit(mergeReadBudget, 1);
    const boundTargetFriend = await validateBoundInviteTarget(ctx, creatorAccount, linkContext);
    accountMergeRowsForLimit(mergeReadBudget, [boundTargetFriend]);

    const creatorMemberId = creatorAccount.member_id
      ? normalizeMemberId(creatorAccount.member_id)
      : undefined;
    if (requestedMergeMemberId && !creatorMemberId) {
      throw new Error("Creator account is missing a canonical member_id");
    }

    const preparedSelectedFriendMerge =
      requestedMergeMemberId &&
      creatorMemberId &&
      (!token.claimed_by || requestedMergeMemberId !== creatorMemberId)
        ? await prepareInviteMergeSourceInternal(ctx, {
            accountEmail: user.email,
            sourceMemberId: requestedMergeMemberId,
            targetMemberId: creatorMemberId,
            targetName: creatorAccount.display_name ?? creatorAccount.email ?? "Unknown",
            targetLinkedAccountId: creatorAccount.id,
            targetLinkedAccountEmail: creatorAccount.email,
            allowMissingSource: Boolean(token.claimed_by),
            readBudget: mergeReadBudget
          })
        : undefined;
    if (
      preparedSelectedFriendMerge?.localAliases.some((memberId) =>
        claimantIdentityClosure.has(memberId)
      )
    ) {
      throw new Error("Cannot merge the claimant identity into the inviter");
    }
    const claimResult = await claimForUser(
      ctx,
      user,
      {
        targetMemberId: token.target_member_id,
        targetFriendId: token.target_friend_id,
        creatorEmail: token.creator_email,
        creatorId: token.creator_id
      },
      mergeReadBudget,
      preparedSelectedFriendMerge,
      true
    );

    await ctx.db.patch(token._id, {
      claimed_by: user.id,
      claimed_at: now,
      claim_merge_local_friend_member_id: requestedMergeMemberId
    });

    return claimResult;
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
    const readBudget = createMergeReadBudget();
    accountMergeQueriesForLimit(readBudget, 1);
    const user = await ctx.db.get(args.userAccountId);
    if (!user) throw new Error("User not found");
    accountMergeRowsForLimit(readBudget, [user]);

    accountMergeQueriesForLimit(readBudget, 1);
    const token = await ctx.db
      .query("invite_tokens")
      .withIndex("by_client_id", (q) => q.eq("id", args.tokenId))
      .unique();

    if (!token) throw new Error("Token not found");
    accountMergeRowsForLimit(readBudget, [token]);

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

    await assertMergeIdentityMaterializationReady(ctx, readBudget);
    const result = await claimForUser(
      ctx,
      user,
      {
        targetMemberId: token.target_member_id,
        targetFriendId: token.target_friend_id,
        creatorEmail: token.creator_email,
        creatorId: token.creator_id
      },
      readBudget,
      undefined,
      true
    );
    await ctx.db.patch(token._id, {
      claimed_by: user.id,
      claimed_at: now
    });
    return result;
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
    const readBudget = createMergeReadBudget();
    accountMergeQueriesForLimit(readBudget, 1);
    const user = await ctx.db.get(args.userAccountId);
    if (!user) throw new Error("User not found");
    accountMergeRowsForLimit(readBudget, [user]);

    return await claimForUser(
      ctx,
      user,
      {
        targetMemberId: args.targetMemberId,
        targetFriendId: args.targetFriendId,
        creatorEmail: args.creatorEmail,
        creatorId: args.creatorId
      },
      readBudget
    );
  }
});
