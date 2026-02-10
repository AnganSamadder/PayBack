import { query, mutation } from "./_generated/server";
import { v } from "convex/values";
import { internal } from "./_generated/api";
import { normalizeMemberId } from "./identity";

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
  },
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
  },
});

/**
 * Creates a new link request to a recipient email for a target member.
 */
export const create = mutation({
  args: {
    id: v.string(), // Client-generated UUID
    recipient_email: v.string(),
    target_member_id: v.string(),
    target_member_name: v.string(),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Unauthenticated");

    const user = await ctx.db
      .query("accounts")
      .withIndex("by_email", (q) => q.eq("email", identity.email!))
      .unique();

    if (!user) throw new Error("User not found");

    // Deduplication check
    const existing = await ctx.db
      .query("link_requests")
      .withIndex("by_client_id", (q) => q.eq("id", args.id))
      .unique();

    if (existing) {
      return existing._id;
    }

    // Create request with 7-day expiry
    const now = Date.now();
    const expiresAt = now + 7 * 24 * 60 * 60 * 1000;

    const requestId = await ctx.db.insert("link_requests", {
      id: args.id,
      requester_id: user.id,
      requester_email: user.email,
      requester_name: user.display_name,
      recipient_email: args.recipient_email.toLowerCase(),
      target_member_id: normalizeMemberId(args.target_member_id),
      target_member_name: args.target_member_name,
      created_at: now,
      status: "pending",
      expires_at: expiresAt,
    });

    return requestId;
  },
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

    // Update request status first to preserve idempotency semantics.
    await ctx.db.patch(request._id, {
      status: "accepted",
    });

    // Delegate to the shared invite claim core.
    return await ctx.runMutation(internal.inviteTokens._internalClaimTargetMemberForAccount, {
      userAccountId: user._id,
      targetMemberId: request.target_member_id,
      creatorEmail: request.requester_email,
      creatorId: request.requester_id,
    });
  },
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
      rejected_at: now,
    });
  },
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
  },
});
