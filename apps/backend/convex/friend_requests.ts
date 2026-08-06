/* eslint-disable @typescript-eslint/ban-ts-comment */
// @ts-nocheck
import { query, mutation } from "./_generated/server";
import { v } from "convex/values";
import { getRandomAvatarColor } from "./utils";
import { resolveCanonicalMemberIdInternal } from "./aliases";
import {
  assertAccountCanAcceptChanges,
  getCurrentUserOrThrow,
  resolveAuthenticatedAccount
} from "./helpers";
import { findAccountsByEmailIdentity } from "./identity";
import { checkRateLimit } from "./rateLimit";

/**
 * Sends a friend request to a user by email.
 */
export const send = mutation({
  args: { email: v.string() },
  handler: async (ctx, args) => {
    const recipientEmail = args.email.trim().toLowerCase();
    const { user: sender } = await getCurrentUserOrThrow(ctx);
    const senderEmail = sender.email.trim().toLowerCase();
    await checkRateLimit(ctx, sender.id, "friend_requests:send", 10);

    const recipients = await findAccountsByEmailIdentity(ctx.db, recipientEmail);
    if (recipients.length !== 1) {
      return { success: true };
    }
    const recipient = recipients[0];
    assertAccountCanAcceptChanges(recipient);

    if (sender._id === recipient._id) throw new Error("Cannot add yourself");

    // Check existing request
    const existing = await ctx.db
      .query("friend_requests")
      .withIndex("by_recipient_email_and_status", (q) =>
        q.eq("recipient_email", recipientEmail).eq("status", "pending")
      )
      .filter((q) => q.eq(q.field("sender_id"), sender._id))
      .first();

    if (existing) throw new Error("Request already pending");

    // Create request
    await ctx.db.insert("friend_requests", {
      sender_id: sender._id,
      recipient_email: recipientEmail,
      status: "pending",
      created_at: Date.now()
    });

    // Update Sender's friend list (Optimistic: "Request Sent")
    const recipientCanonicalId = await resolveCanonicalMemberIdInternal(
      ctx.db,
      recipient.member_id ?? recipient.id
    );

    const existingFriend = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", senderEmail).eq("member_id", recipientCanonicalId)
      )
      .unique();

    if (existingFriend) {
      await ctx.db.patch(existingFriend._id, {
        status: "request_sent",
        updated_at: Date.now()
      });
    } else {
      await ctx.db.insert("account_friends", {
        account_email: sender.email.trim().toLowerCase(),
        member_id: recipientCanonicalId,
        name: recipient.display_name ?? recipient.email ?? "Unknown",
        status: "request_sent",
        has_linked_account: false,
        link_state: "unlinked",
        profile_image_url: recipient.profile_image_url,
        profile_avatar_color: recipient.profile_avatar_color ?? getRandomAvatarColor(),
        updated_at: Date.now()
      });
    }

    return { success: true };
  }
});

/**
 * Accepts a friend request.
 */
export const accept = mutation({
  args: { requestId: v.id("friend_requests") },
  handler: async (ctx, args) => {
    const { user: recipient } = await getCurrentUserOrThrow(ctx);
    const recipientEmail = recipient.email.trim().toLowerCase();

    const request = await ctx.db.get(args.requestId);
    if (!request) throw new Error("Request not found");
    if (request.recipient_email.trim().toLowerCase() !== recipientEmail)
      throw new Error("Not authorized");
    if (request.status !== "pending") throw new Error("Request not pending");

    const sender = await ctx.db.get(request.sender_id);
    if (!sender) throw new Error("Sender account not found");
    assertAccountCanAcceptChanges(sender);

    // 1. Update Request
    await ctx.db.patch(request._id, {
      status: "accepted",
      updated_at: Date.now()
    });

    // 2. Add Sender to Recipient's Friends
    const senderCanonicalId = await resolveCanonicalMemberIdInternal(
      ctx.db,
      sender.member_id ?? sender.id
    );

    const existingFriendForRecipient = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q.eq("account_email", recipientEmail).eq("member_id", senderCanonicalId)
      )
      .unique();

    if (existingFriendForRecipient) {
      await ctx.db.patch(existingFriendForRecipient._id, {
        member_id: senderCanonicalId,
        status: "friend",
        has_linked_account: true,
        linked_account_id: sender.id,
        linked_account_email: sender.email.trim().toLowerCase(),
        linked_member_id: senderCanonicalId,
        link_state: "linked",
        updated_at: Date.now()
      });
    } else {
      await ctx.db.insert("account_friends", {
        account_email: recipientEmail,
        member_id: senderCanonicalId,
        name: sender.display_name ?? sender.email ?? "Unknown",
        status: "friend",
        has_linked_account: true,
        linked_account_id: sender.id,
        linked_account_email: sender.email.trim().toLowerCase(),
        linked_member_id: senderCanonicalId,
        link_state: "linked",
        profile_image_url: sender.profile_image_url,
        profile_avatar_color: sender.profile_avatar_color ?? getRandomAvatarColor(),
        updated_at: Date.now()
      });
    }

    // 3. Add Recipient to Sender's Friends (Mutual)
    const recipientCanonicalId = await resolveCanonicalMemberIdInternal(
      ctx.db,
      recipient.member_id ?? recipient.id
    );

    const existingFriendForSender = await ctx.db
      .query("account_friends")
      .withIndex("by_account_email_and_member_id", (q) =>
        q
          .eq("account_email", sender.email.trim().toLowerCase())
          .eq("member_id", recipientCanonicalId)
      )
      .unique();

    if (existingFriendForSender) {
      await ctx.db.patch(existingFriendForSender._id, {
        member_id: recipientCanonicalId,
        status: "friend",
        has_linked_account: true,
        linked_account_id: recipient.id,
        linked_account_email: recipientEmail,
        linked_member_id: recipientCanonicalId,
        link_state: "linked",
        updated_at: Date.now()
      });
    } else {
      await ctx.db.insert("account_friends", {
        account_email: sender.email.trim().toLowerCase(),
        member_id: recipientCanonicalId,
        name: recipient.display_name ?? recipient.email ?? "Unknown",
        status: "friend",
        has_linked_account: true,
        linked_account_id: recipient.id,
        linked_account_email: recipientEmail,
        linked_member_id: recipientCanonicalId,
        link_state: "linked",
        profile_image_url: recipient.profile_image_url,
        profile_avatar_color: recipient.profile_avatar_color ?? getRandomAvatarColor(),
        updated_at: Date.now()
      });
    }

    return { success: true };
  }
});

/**
 * Rejects a friend request.
 */
export const reject = mutation({
  args: { requestId: v.id("friend_requests") },
  handler: async (ctx, args) => {
    const { user } = await getCurrentUserOrThrow(ctx);

    const request = await ctx.db.get(args.requestId);
    if (!request) throw new Error("Request not found");
    if (request.recipient_email.trim().toLowerCase() !== user.email.trim().toLowerCase())
      throw new Error("Not authorized");

    await ctx.db.patch(request._id, {
      status: "rejected",
      updated_at: Date.now()
    });

    return { success: true };
  }
});

/**
 * Lists incoming pending requests.
 */
export const listIncoming = query({
  args: {},
  handler: async (ctx) => {
    if (!(await ctx.auth.getUserIdentity())) return [];
    const { user } = await resolveAuthenticatedAccount(ctx);
    if (!user) return [];
    const recipientEmail = user.email.trim().toLowerCase();

    const requests = await ctx.db
      .query("friend_requests")
      .withIndex("by_recipient_email_and_status", (q) =>
        q.eq("recipient_email", recipientEmail).eq("status", "pending")
      )
      .collect();

    // Enrich with sender details
    const results = [];
    for (const req of requests) {
      const sender = await ctx.db.get(req.sender_id);
      if (sender) {
        const senderCanonicalId = await resolveCanonicalMemberIdInternal(
          ctx.db,
          sender.member_id ?? sender.id
        );
        results.push({
          request: req,
          sender: {
            id: sender.id,
            member_id: senderCanonicalId,
            name: sender.display_name,
            email: sender.email,
            profile_image_url: sender.profile_image_url,
            profile_avatar_color: sender.profile_avatar_color
          }
        });
      }
    }
    return results;
  }
});
