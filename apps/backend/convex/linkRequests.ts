import { query, mutation, type MutationCtx } from "./_generated/server";
import { getConvexSize, type Value, v } from "convex/values";
import {
  accountLinkingRows,
  chargeLinkingQueries,
  createLinkingReadBudget,
  reserveMergeWriteValuesForLimit
} from "./aliases";
import { findAccountsByEmailIdentity, normalizeMemberId } from "./identity";
import { isGhostFriendIdentity } from "./friendLinkProvenance";
import {
  assertAccountCanAcceptChanges,
  getCurrentUserOrThrow,
  resolveAuthenticatedAccount
} from "./helpers";
import { checkRateLimit } from "./rateLimit";
import {
  applyClaimForUser,
  assertBudgetedIdentityMaterializationReady,
  prepareClaimForUser
} from "./inviteTokens";

function isUnlinkedFriend(friend: {
  has_linked_account: boolean;
  link_state?: "linked" | "unlinked" | "ghost";
  linked_account_id?: string;
  linked_account_email?: string;
  linked_member_id?: string;
  status?: string;
}) {
  return (
    friend.has_linked_account === false &&
    !isGhostFriendIdentity(friend) &&
    !friend.linked_account_id &&
    !friend.linked_account_email &&
    !friend.linked_member_id
  );
}

const createArgs = {
  id: v.string(),
  recipient_email: v.string(),
  target_member_id: v.string(),
  target_member_name: v.string()
};

type CreateLinkRequestArgs = {
  id: string;
  recipient_email: string;
  target_member_id: string;
  target_member_name: string;
};

const MAX_ACTIVE_DUPLICATE_CANDIDATES = 1;
const LINK_REQUEST_LIST_LIMITS = {
  compatibilityRows: 50,
  pageRows: 5,
  estimatedReadBytes: 8 * 1024 * 1024
} as const;

function convexRowsSize(rows: readonly unknown[]) {
  return rows.reduce<number>((total, row) => total + getConvexSize(row as Value), 0);
}

function clampedLinkRequestPageSize(requested: number) {
  if (!Number.isFinite(requested)) return 1;
  return Math.max(1, Math.min(LINK_REQUEST_LIST_LIMITS.pageRows, Math.trunc(requested)));
}

async function collectCompatibilityLinkRequests<T extends { _id: unknown; created_at: number }>(
  activeRows: T[],
  historyRows: T[]
): Promise<T[]> {
  if (activeRows.length > LINK_REQUEST_LIST_LIMITS.compatibilityRows) {
    throw new Error("Too many active link requests to list safely");
  }
  let readBytes = convexRowsSize(activeRows);
  if (readBytes > LINK_REQUEST_LIST_LIMITS.estimatedReadBytes) {
    throw new Error("Active link request list exceeds the safe read budget");
  }

  activeRows.sort((left, right) => right.created_at - left.created_at);
  const rows = [...activeRows];
  const activeIds = new Set(activeRows.map((row) => String(row._id)));
  for (const row of historyRows) {
    const rowBytes = getConvexSize(row as Value);
    if (readBytes + rowBytes > LINK_REQUEST_LIST_LIMITS.estimatedReadBytes) break;
    readBytes += rowBytes;
    if (!activeIds.has(String(row._id))) rows.push(row);
    if (rows.length === LINK_REQUEST_LIST_LIMITS.compatibilityRows) break;
  }
  return rows;
}

async function createCanonicalLinkRequest(ctx: MutationCtx, args: CreateLinkRequestArgs) {
  const { user } = await getCurrentUserOrThrow(ctx);

  const recipientEmail = args.recipient_email.trim().toLowerCase();
  const targetMemberId = normalizeMemberId(args.target_member_id);
  const targetMemberName = args.target_member_name.trim();
  if (!recipientEmail.includes("@")) {
    throw new Error("Invalid recipient email");
  }
  if (recipientEmail === user.email.trim().toLowerCase()) {
    throw new Error("You cannot send a link request to yourself");
  }
  if (!targetMemberName) {
    throw new Error("Friend name is required");
  }

  const existing = await ctx.db
    .query("link_requests")
    .withIndex("by_client_id", (q) => q.eq("id", args.id))
    .unique();

  if (existing) {
    const isExactReplay =
      existing.requester_id === user.id &&
      existing.recipient_email.trim().toLowerCase() === recipientEmail &&
      normalizeMemberId(existing.target_member_id) === targetMemberId;
    if (!isExactReplay) {
      throw new Error("Link request id is already used for a different request");
    }

    return existing;
  }

  await checkRateLimit(ctx, user.id, "linkRequests:create", 10);

  const recipientMatches = await findAccountsByEmailIdentity(ctx.db, recipientEmail);
  if (recipientMatches.length > 1) {
    throw new Error("Recipient account identity requires maintenance");
  }
  assertAccountCanAcceptChanges(recipientMatches[0] ?? null);

  const targetFriend = await ctx.db
    .query("account_friends")
    .withIndex("by_account_email_and_member_id", (q) =>
      q.eq("account_email", user.email.toLowerCase().trim()).eq("member_id", targetMemberId)
    )
    .unique();
  if (!targetFriend || !isUnlinkedFriend(targetFriend)) {
    throw new Error("Target member must be an unlinked friend owned by the requester");
  }

  const now = Date.now();
  const activeCandidates = await ctx.db
    .query("link_requests")
    .withIndex("by_requester_recipient_status_and_expiry", (q) =>
      q
        .eq("requester_id", user.id)
        .eq("recipient_email", recipientEmail)
        .eq("status", "pending")
        .gt("expires_at", now)
    )
    .order("asc")
    .take(MAX_ACTIVE_DUPLICATE_CANDIDATES + 1);
  if (activeCandidates.length > MAX_ACTIVE_DUPLICATE_CANDIDATES) {
    throw new Error("Too many active link requests for this recipient");
  }
  const activeDuplicate =
    activeCandidates.find(
      (request) => normalizeMemberId(request.target_member_id) === targetMemberId
    ) ?? activeCandidates[0];
  if (activeDuplicate) {
    if (normalizeMemberId(activeDuplicate.target_member_id) === targetMemberId) {
      return activeDuplicate;
    }
    throw new Error("An active link request already exists for this recipient");
  }

  const activeTargetRequests = await ctx.db
    .query("link_requests")
    .withIndex("by_requester_target_status_and_expiry", (q) =>
      q
        .eq("requester_id", user.id)
        .eq("target_member_id", targetMemberId)
        .eq("status", "pending")
        .gt("expires_at", now)
    )
    .take(2);
  if (activeTargetRequests.length > 0) {
    throw new Error("An active link request already exists for this friend");
  }

  const storedRequest = {
    id: args.id,
    requester_id: user.id,
    requester_email: user.email.trim().toLowerCase(),
    requester_name: user.display_name,
    recipient_email: recipientEmail,
    target_member_id: targetMemberId,
    target_friend_id: targetFriend._id,
    target_member_name: targetFriend.name,
    created_at: now,
    status: "pending",
    expires_at: now + 7 * 24 * 60 * 60 * 1000
  };
  await ctx.db.insert("link_requests", storedRequest);

  return storedRequest;
}

/**
 * Lists all incoming link requests for the current user.
 */
export const listIncoming = query({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) return [];

    const { user } = await resolveAuthenticatedAccount(ctx);
    if (!user) return [];
    const recipientEmail = user.email.trim().toLowerCase();
    const now = Date.now();
    const activeRows = await ctx.db
      .query("link_requests")
      .withIndex("by_recipient_email_status_and_expiry", (q) =>
        q.eq("recipient_email", recipientEmail).eq("status", "pending").gt("expires_at", now)
      )
      .take(LINK_REQUEST_LIST_LIMITS.compatibilityRows + 1);
    const historyRows = await ctx.db
      .query("link_requests")
      .withIndex("by_recipient_email_and_created_at", (q) =>
        q.eq("recipient_email", recipientEmail)
      )
      .order("desc")
      .take(LINK_REQUEST_LIST_LIMITS.compatibilityRows);
    return await collectCompatibilityLinkRequests(activeRows, historyRows);
  }
});

export const listIncomingPage = query({
  args: {
    cursor: v.union(v.string(), v.null()),
    numItems: v.number()
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) return { page: [], continueCursor: "", isDone: true };

    const { user } = await resolveAuthenticatedAccount(ctx);
    if (!user) return { page: [], continueCursor: "", isDone: true };
    const recipientEmail = user.email.trim().toLowerCase();
    return await ctx.db
      .query("link_requests")
      .withIndex("by_recipient_email_and_created_at", (q) =>
        q.eq("recipient_email", recipientEmail)
      )
      .order("desc")
      .paginate({ cursor: args.cursor, numItems: clampedLinkRequestPageSize(args.numItems) });
  }
});

/**
 * Lists all outgoing link requests from the current user.
 */
export const listOutgoing = query({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) return [];

    const { user } = await resolveAuthenticatedAccount(ctx);
    if (!user) return [];

    const now = Date.now();
    const activeRows = await ctx.db
      .query("link_requests")
      .withIndex("by_requester_id_status_and_expiry", (q) =>
        q.eq("requester_id", user.id).eq("status", "pending").gt("expires_at", now)
      )
      .take(LINK_REQUEST_LIST_LIMITS.compatibilityRows + 1);
    const historyRows = await ctx.db
      .query("link_requests")
      .withIndex("by_requester_id_and_created_at", (q) => q.eq("requester_id", user.id))
      .order("desc")
      .take(LINK_REQUEST_LIST_LIMITS.compatibilityRows);
    return await collectCompatibilityLinkRequests(activeRows, historyRows);
  }
});

export const listOutgoingPage = query({
  args: {
    cursor: v.union(v.string(), v.null()),
    numItems: v.number()
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) return { page: [], continueCursor: "", isDone: true };

    const { user } = await resolveAuthenticatedAccount(ctx);
    if (!user) return { page: [], continueCursor: "", isDone: true };

    return await ctx.db
      .query("link_requests")
      .withIndex("by_requester_id_and_created_at", (q) => q.eq("requester_id", user.id))
      .order("desc")
      .paginate({ cursor: args.cursor, numItems: clampedLinkRequestPageSize(args.numItems) });
  }
});

/**
 * Creates a new link request to a recipient email for a target member.
 */
export const create = mutation({
  args: createArgs,
  handler: async (ctx, args) => {
    return (await createCanonicalLinkRequest(ctx, args)).id;
  }
});

/**
 * Creates a link request and returns the canonical stored payload.
 */
export const createV2 = mutation({
  args: createArgs,
  handler: async (ctx, args) => {
    return await createCanonicalLinkRequest(ctx, args);
  }
});

/**
 * Accepts a link request and links the accounts.
 */
export const accept = mutation({
  args: { id: v.string() },
  handler: async (ctx, args) => {
    const budget = createLinkingReadBudget();

    chargeLinkingQueries(budget, 1);
    const { user } = await getCurrentUserOrThrow(ctx);
    accountLinkingRows(budget, [user]);

    chargeLinkingQueries(budget, 1);
    const request = await ctx.db
      .query("link_requests")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();
    accountLinkingRows(budget, request ? [request] : []);

    if (!request) throw new Error("Request not found");

    // Verify recipient
    if (request.recipient_email.trim().toLowerCase() !== user.email.trim().toLowerCase()) {
      throw new Error("Not authorized to accept this request");
    }

    if (request.status !== "pending") {
      throw new Error("Request is no longer pending");
    }

    const now = Date.now();

    if (request.expires_at < now) {
      throw new Error("Request has expired");
    }

    await assertBudgetedIdentityMaterializationReady(ctx, budget);

    let targetFriendId = request.target_friend_id;
    if (!targetFriendId) {
      chargeLinkingQueries(budget, 1);
      const targetFriends = await ctx.db
        .query("account_friends")
        .withIndex("by_account_email_and_member_id", (q) =>
          q
            .eq("account_email", request.requester_email.toLowerCase().trim())
            .eq("member_id", normalizeMemberId(request.target_member_id))
        )
        .take(2);
      accountLinkingRows(budget, targetFriends, true);
      if (targetFriends.length !== 1) {
        throw new Error("Target member is no longer an unlinked friend owned by the requester");
      }
      targetFriendId = targetFriends[0]._id;
    }

    const claimPlan = await prepareClaimForUser(
      ctx,
      user,
      {
        targetMemberId: request.target_member_id,
        targetFriendId,
        creatorEmail: request.requester_email.trim().toLowerCase(),
        creatorId: request.requester_id
      },
      budget
    );

    reserveMergeWriteValuesForLimit(budget, [{ ...request, status: "accepted" } as Value]);
    await ctx.db.patch(request._id, { status: "accepted" });
    return await applyClaimForUser(ctx, claimPlan);
  }
});

/**
 * Declines a link request.
 */
export const decline = mutation({
  args: { id: v.string() },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUserOrThrow(ctx);

    const request = await ctx.db
      .query("link_requests")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    if (!request) throw new Error("Request not found");

    // Verify recipient
    if (request.recipient_email.trim().toLowerCase() !== user.email.trim().toLowerCase()) {
      throw new Error("Not authorized to decline this request");
    }

    const now = Date.now();

    // Update request status
    await ctx.db.patch(request._id, {
      status: "declined",
      rejected_at: now
    });
  }
});

/**
 * Cancels an outgoing link request.
 */
export const cancel = mutation({
  args: { id: v.string() },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUserOrThrow(ctx);

    const request = await ctx.db
      .query("link_requests")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    if (!request) throw new Error("Request not found");

    // Verify requester
    if (request.requester_id !== user.id) {
      throw new Error("Not authorized to cancel this request");
    }

    // Delete the request
    await ctx.db.delete(request._id);
  }
});
