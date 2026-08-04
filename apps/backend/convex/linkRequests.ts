import { query, mutation, type MutationCtx } from "./_generated/server";
import { v } from "convex/values";
import { internal } from "./_generated/api";
import { assertIdentityMaterializationReady, normalizeMemberId } from "./identity";

function isUnlinkedFriend(friend: {
  has_linked_account: boolean;
  link_state?: "linked" | "unlinked" | "ghost";
  linked_account_id?: string;
  linked_account_email?: string;
  linked_member_id?: string;
}) {
  return (
    friend.has_linked_account === false &&
    friend.link_state !== "ghost" &&
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

async function createCanonicalLinkRequest(ctx: MutationCtx, args: CreateLinkRequestArgs) {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) throw new Error("Unauthenticated");

  const user = await ctx.db
    .query("accounts")
    .withIndex("by_email", (q) => q.eq("email", identity.email!))
    .unique();

  if (!user) throw new Error("User not found");

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
  const duplicate = await ctx.db
    .query("link_requests")
    .withIndex("by_requester_id_and_recipient_email", (q) =>
      q.eq("requester_id", user.id).eq("recipient_email", recipientEmail)
    )
    .collect();
  const activeDuplicate = duplicate.find(
    (request) => request.status === "pending" && request.expires_at > now
  );
  if (activeDuplicate) {
    if (normalizeMemberId(activeDuplicate.target_member_id) === targetMemberId) {
      return activeDuplicate;
    }
    throw new Error("An active link request already exists for this recipient");
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

    return await ctx.db
      .query("link_requests")
      .withIndex("by_recipient_email", (q) => q.eq("recipient_email", identity.email!))
      .collect();
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

    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", identity.email!))
      .unique();

    if (!user) return [];

    return await ctx.db
      .query("link_requests")
      .withIndex("by_requester_id", (q) => q.eq("requester_id", user.id))
      .collect();
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
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", identity.email!))
      .unique();

    if (!user) throw new Error("User not found");

    const request = await ctx.db
      .query("link_requests")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    if (!request) throw new Error("Request not found");

    // Verify recipient
    if (request.recipient_email.toLowerCase() !== identity.email!.toLowerCase()) {
      throw new Error("Not authorized to accept this request");
    }

    if (request.status !== "pending") {
      throw new Error("Request is no longer pending");
    }

    const now = Date.now();

    if (request.expires_at < now) {
      throw new Error("Request has expired");
    }

    const requester = await ctx.db
      .query("accounts")
      .withIndex("by_auth_id", (q) => q.eq("id", request.requester_id))
      .unique();
    if (!requester || requester.status === "deleted") {
      throw new Error("Requester account is no longer active");
    }

    await assertIdentityMaterializationReady(ctx.db);
    const targetFriend = request.target_friend_id
      ? await ctx.db.get(request.target_friend_id)
      : await ctx.db
          .query("account_friends")
          .withIndex("by_account_email_and_member_id", (q) =>
            q
              .eq("account_email", requester.email.toLowerCase().trim())
              .eq("member_id", normalizeMemberId(request.target_member_id))
          )
          .unique();
    if (
      !targetFriend ||
      targetFriend.account_email !== requester.email.toLowerCase().trim() ||
      normalizeMemberId(targetFriend.member_id) !== normalizeMemberId(request.target_member_id) ||
      !isUnlinkedFriend(targetFriend)
    ) {
      throw new Error("Target member is no longer an unlinked friend owned by the requester");
    }

    // Update request status first to preserve idempotency semantics.
    await ctx.db.patch(request._id, {
      status: "accepted"
    });

    // Delegate to the shared invite claim core.
    return await ctx.runMutation(internal.inviteTokens._internalClaimTargetMemberForAccount, {
      userAccountId: user._id,
      targetMemberId: request.target_member_id,
      creatorEmail: request.requester_email,
      creatorId: request.requester_id
    });
  }
});

/**
 * Declines a link request.
 */
export const decline = mutation({
  args: { id: v.string() },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const request = await ctx.db
      .query("link_requests")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    if (!request) throw new Error("Request not found");

    // Verify recipient
    if (request.recipient_email.toLowerCase() !== identity.email!.toLowerCase()) {
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
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", identity.email!))
      .unique();

    if (!user) throw new Error("User not found");

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
